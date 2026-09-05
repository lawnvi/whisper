// Opt-in two-machine test driver; intentionally excluded from *_test.dart discovery.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/aead_engine.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/state/peer_profile.dart';

void main() {
  const configPath = String.fromEnvironment('WHISPER_LAN_TEST_CONFIG');
  test(
    'opt-in production LAN transfer peer',
    () async {
      if (configPath.isEmpty) {
        throw StateError('WHISPER_LAN_TEST_CONFIG is required');
      }
      TestWidgetsFlutterBinding.ensureInitialized();
      HttpOverrides.global =
          null; // Real sockets, not Flutter's HTTP test stub.
      final config =
          jsonDecode(await File(configPath).readAsString())
              as Map<String, dynamic>;
      final root = Directory(config['root'] as String);
      await root.create(recursive: true);
      final received = Directory(p.join(root.path, 'received'));
      await received.create();
      SharedPreferences.setMockInitialValues({'_savePath': received.path});
      WhisperAead.installNativeAcceleration(await SodiumInit.init());
      StreamingChecksum.installNativeSha256Acceleration();
      final database = LocalDatabase.forTesting(
        NativeDatabase(File(p.join(root.path, 'test.sqlite'))),
      );
      final localId = config['localId'] as String;
      final peerId = config['peerId'] as String;
      final peerIdentity = await DeviceIdentity.fromSeed(
        base64Url.decode(base64Url.normalize(config['peerSeed'] as String)),
      );
      // Pin only the other test identity; authentication still verifies its
      // signature and derives the production encrypted session keys.
      await database.upsertDevice(
        _profile(
          peerId,
          config['peerHost'] as String,
          config['peerPort'] as int,
        ).device,
      );
      final pin = await database.pinDeviceIdentity(
        peerId,
        peerIdentity.publicKeyBase64Url,
      );
      if (!pin.isSuccess ||
          !await database.authDeviceIfPinned(
            peerId,
            peerIdentity.publicKeyBase64Url,
          )) {
        await database.close();
        throw StateError('test identity pin mismatch');
      }
      final events = _Events(root);
      final manager = WsSvrManager.forTesting(
        database: database,
        identityStore: DeviceIdentityStore(
          storage: _SeedStorage(config['seed'] as String),
        ),
        localPeerProfileLoader: () async => _profile(
          localId,
          config['localHost'] as String,
          config['port'] as int,
        ),
        autoConnectEnabled: () async => false,
        manageSharedCoordinators: false,
      );
      manager.setSender(localId);
      manager.setEvent(events);
      try {
        await manager.reconcileInterruptedTransfersOnStartup();
        final server = await manager.startServer(config['port'] as int);
        if (!server.isSuccess) {
          throw StateError('test listener failed: ${server.error.runtimeType}');
        }
        events.emit('ready', {
          'port': server.port,
          'platform': Platform.operatingSystem,
          'pid': pid,
          'nativeAead': WhisperAead.nativeAccelerationEnabled,
        });
        final commandFile = File(p.join(root.path, 'command.json'));
        // A restarted peer waits for a fresh command instead of replaying a
        // previous send/create/stop operation against its persisted database.
        String? lastCommand = await commandFile.exists()
            ? (jsonDecode(await commandFile.readAsString()) as Map)['id']
                  as String?
            : null;
        final deadline = DateTime.now().add(const Duration(minutes: 45));
        while (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (!await commandFile.exists()) continue;
          Map<String, dynamic> command;
          try {
            command =
                jsonDecode(await commandFile.readAsString())
                    as Map<String, dynamic>;
          } on FormatException {
            continue; // The controller may still be replacing the command file.
          }
          final id = command['id'] as String;
          if (id == lastCommand) continue;
          lastCommand = id;
          final action = command['action'] as String;
          events.emit('command_started', {'id': id, 'action': action});
          try {
            if (action == 'stop') {
              events.emit('command_done', {'id': id, 'action': action});
              return;
            }
            switch (action) {
              case 'connect':
                final result = await manager
                    .connectToServer(
                      ConnectionAttemptRequest(
                        requestId: id,
                        endpoint: PeerEndpoint(
                          host: config['peerHost'] as String,
                          port: config['peerPort'] as int,
                        ),
                        expectedPeerId: peerId,
                        mode: ConnectionAttemptMode.interactive,
                      ),
                    )
                    .timeout(const Duration(seconds: 30));
                if (!result.isAuthenticated) {
                  throw StateError(
                    'connect ${result.status.name}: ${result.reason.name}',
                  );
                }
                manager.selectPeer(peerId);
                events.emit('authenticated', {
                  'protocol': manager.remoteProfileFor(peerId)?.protocolVersion,
                });
              case 'create':
                final file = _fileUnder(root, command['path'] as String);
                await file.parent.create(recursive: true);
                final mib = command['mib'] as int;
                if (mib < 0 || mib > 4096) {
                  throw ArgumentError('mib must be between 0 and 4096');
                }
                final chunk = Uint8List(1024 * 1024);
                for (var i = 0; i < chunk.length; i++) {
                  chunk[i] = (i * 31 + (command['pattern'] as int? ?? 7)) & 255;
                }
                final writer = await file.open(mode: FileMode.write);
                try {
                  for (var i = 0; i < mib; i++) {
                    await writer.writeFrom(chunk);
                  }
                  await writer.flush();
                } finally {
                  await writer.close();
                }
                events.emit('created', {
                  'path': file.path,
                  'size': await file.length(),
                });
              case 'send':
                final accepted = await manager.sendFileTo(
                  peerId,
                  _fileUnder(root, command['path'] as String).path,
                  messageId: command['transferId'] as String?,
                );
                if (!accepted) throw StateError('transfer offer rejected');
              case 'text':
                if (!await manager.sendMessageTo(peerId, 'lan-smoke:$id')) {
                  throw StateError('text rejected');
                }
              case 'disconnect':
                await manager.disconnectPeer(peerId);
              case 'retry':
                await manager.retryTransfer(command['transferId'] as String);
              default:
                throw ArgumentError('unknown test action');
            }
            events.emit('command_done', {'id': id, 'action': action});
          } catch (error) {
            events.emit('command_error', {
              'id': id,
              'action': action,
              'error': '$error',
            });
          }
        }
        throw TimeoutException('LAN test driver exceeded its time limit');
      } finally {
        await manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        );
        await database.close();
        events.emit('stopped', {});
      }
    },
    timeout: const Timeout(Duration(minutes: 46)),
  );
}

File _fileUnder(Directory root, String relative) {
  final path = p.normalize(p.join(root.absolute.path, relative));
  if (p.isAbsolute(relative) || !p.isWithin(root.absolute.path, path)) {
    throw ArgumentError('test file must stay inside the test directory');
  }
  return File(path);
}

PeerProfile _profile(String uid, String host, int port) => PeerProfile(
  device: DeviceData(
    id: 0,
    uid: uid,
    name: 'Whisper LAN test',
    host: host,
    port: port,
    password: '',
    platform: Platform.operatingSystem,
    isServer: true,
    online: true,
    clipboard: false,
    auth: false,
    lastTime: 1,
    around: true,
  ),
  trustedPeerIds: const [],
  autoApproveNewDevices: false,
  autoConnectEnabled: false,
  protocolVersion: PeerSocketSession.protocolVersion,
  capabilities: const PeerCapabilities(
    fileTransferV3: true,
    systemAudioSourceV1: false,
    speakerSinkV1: false,
    remoteInputSourceV1: false,
    remoteInputSinkV1: false,
    remoteInputTopologyV1: false,
    audioGroupSourceV1: false,
    audioGroupSinkV1: false,
    audioGroupRejoinV1: false,
    audioSyncClockV1: false,
    audioChannelRoleV1: false,
  ),
);

final class _SeedStorage implements DeviceIdentitySeedStorage {
  _SeedStorage(this.seed);
  final String seed;
  @override
  Future<String?> readSeed() async => seed;
  @override
  Future<void> writeSeed(String value) async =>
      throw StateError('test seed is immutable');
}

class _Events implements ISocketEvent {
  _Events(Directory root) : file = File(p.join(root.path, 'events.jsonl'));
  final File file;
  final Stopwatch clock = Stopwatch()..start();
  final Map<String, ({FileTransferState state, int elapsed})> _last = {};
  void emit(String event, Map<String, Object?> data) {
    file.writeAsStringSync(
      '${jsonEncode({'event': event, 'ms': clock.elapsedMicroseconds / 1000, 'utc': DateTime.now().toUtc().toIso8601String(), ...data})}\n',
      mode: FileMode.append,
    );
  }

  @override
  void onPairing(PairingRequest request, void Function(bool) resolve) {
    emit('unexpected_pairing', {'allowed': false});
    resolve(false);
  }

  @override
  void afterAuth(bool allow, DeviceData? device) =>
      emit('after_auth', {'allowed': allow});
  @override
  void onClose() => emit('disconnected', {});
  @override
  void onConnect() => emit('connected', {});
  @override
  void onError(String message) => emit('socket_error', {'message': message});
  @override
  void onNotice(String message) => emit('notice', {'message': message});
  @override
  void onMessage(MessageData message) {
    if (message.type == MessageEnum.Text) {
      emit('text', {'content': message.content, 'acked': message.acked});
    }
  }

  @override
  void onTransferUpdated(TransferSnapshot snapshot) {
    final previous = _last[snapshot.transferId];
    final now = clock.elapsedMilliseconds;
    if (previous != null &&
        previous.state == snapshot.state &&
        now - previous.elapsed < 1000) {
      return;
    }
    _last[snapshot.transferId] = (state: snapshot.state, elapsed: now);
    emit('transfer', {
      'transferId': snapshot.transferId,
      'direction': snapshot.direction.name,
      'state': snapshot.state.name,
      'bytes': snapshot.committedBytes,
      'size': snapshot.size,
      'path': snapshot.finalPath,
      'error': snapshot.lastError,
    });
  }
}
