// Opt-in two-process LAN scheduling benchmark peer; excluded from *_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
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
import 'package:whisper/remote_files/fs_client.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/socket/aead_engine.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/state/peer_profile.dart';

void main() {
  const configPath = String.fromEnvironment('WHISPER_BENCH_CONFIG');
  test(
    'opt-in outbound scheduling LAN benchmark peer',
    () async {
      if (configPath.isEmpty) {
        throw StateError('WHISPER_BENCH_CONFIG is required');
      }
      TestWidgetsFlutterBinding.ensureInitialized();
      HttpOverrides.global = null;
      final config =
          jsonDecode(await File(configPath).readAsString())
              as Map<String, dynamic>;
      final root = Directory(config['root'] as String);
      await root.create(recursive: true);
      final received = Directory(p.join(root.path, 'received'));
      await received.create(recursive: true);
      final home = Platform.environment['HOME'] ?? root.path;
      final browseDirName = 'whisper_bench_shared_$pid';
      final sharedDir = Directory(p.join(home, browseDirName));
      await sharedDir.create(recursive: true);
      SharedPreferences.setMockInitialValues({'_savePath': received.path});
      WhisperAead.installNativeAcceleration(await SodiumInit.init());
      StreamingChecksum.installNativeSha256Acceleration();

      final database = LocalDatabase.forTesting(
        NativeDatabase(File(p.join(root.path, 'bench.sqlite'))),
      );
      final localId = config['localId'] as String;
      final peerId = config['peerId'] as String;
      final peerIdentity = await DeviceIdentity.fromSeed(
        base64Url.decode(base64Url.normalize(config['peerSeed'] as String)),
      );
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
        throw StateError('bench identity pin mismatch');
      }

      await FileBrowseHost.shared.permissions.setAlways(peerId, true);

      final events = _BenchEvents(root);
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
        manageSharedCoordinators: true,
      );
      manager.setSender(localId);
      manager.setEvent(events);

      RemoteFilesClient? browseClient;
      try {
        final server = await manager.startServer(config['port'] as int);
        if (!server.isSuccess) {
          throw StateError('listener failed: ${server.error.runtimeType}');
        }
        events.emit('ready', {
          'port': server.port,
          'pid': pid,
          'nativeAead': WhisperAead.nativeAccelerationEnabled,
          'vmService': (await developer.Service.getInfo()).serverWebSocketUri
              ?.toString(),
        });

        final commandFile = File(p.join(root.path, 'command.json'));
        String? lastCommand;
        final deadline = DateTime.now().add(const Duration(minutes: 15));
        while (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          if (!await commandFile.exists()) continue;
          Map<String, dynamic> command;
          try {
            command =
                jsonDecode(await commandFile.readAsString())
                    as Map<String, dynamic>;
          } on FormatException {
            continue;
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
                events.emit('authenticated', {
                  'protocol': manager.remoteProfileFor(peerId)?.protocolVersion,
                });
              case 'create':
                final rel = command['path'] as String;
                final file = rel.startsWith('shared/')
                    ? File(
                        p.join(sharedDir.path, rel.substring('shared/'.length)),
                      )
                    : File(p.join(root.path, rel));
                await file.parent.create(recursive: true);
                final mib = command['mib'] as int;
                final chunk = Uint8List(1024 * 1024);
                final pat = command['pattern'] as int? ?? 7;
                for (var i = 0; i < chunk.length; i++) {
                  chunk[i] = (i * 31 + pat) & 255;
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
                  'browseRel': rel.startsWith('shared/')
                      ? '$browseDirName/${rel.substring('shared/'.length)}'
                      : null,
                  'size': await file.length(),
                });
              case 'send':
                final transferId = command['transferId'] as String;
                final accepted = await manager.sendFileTo(
                  peerId,
                  p.join(root.path, command['path'] as String),
                  messageId: transferId,
                );
                if (!accepted) throw StateError('transfer offer rejected');
              case 'text_probe':
                final count = command['count'] as int? ?? 12;
                final intervalMs = command['intervalMs'] as int? ?? 120;
                final probeId = command['probeId'] as String? ?? id;
                unawaited(() async {
                  for (var i = 0; i < count; i++) {
                    final tag = 'probe:$probeId:$i';
                    final sentEpochUs = DateTime.now().microsecondsSinceEpoch;
                    events.recordProbeSent(tag, sentEpochUs);
                    final ok = await manager.sendMessageTo(peerId, tag);
                    events.emit('probe_sent', {
                      'probeId': probeId,
                      'seq': i,
                      'ok': ok,
                      'sentUs': sentEpochUs,
                    });
                    if (i + 1 < count) {
                      await Future<void>.delayed(
                        Duration(milliseconds: intervalMs),
                      );
                    }
                  }
                  events.emit('probe_batch_done', {'probeId': probeId});
                }());
              case 'browse_open':
                browseClient = RemoteFilesClient(peerId);
                final opened = await browseClient.open();
                events.emit('browse_opened', {
                  'rootId': opened.roots.isEmpty ? '' : opened.roots.first.id,
                });
              case 'browse_read_probe':
                final client = browseClient;
                if (client == null) {
                  throw StateError('browse_open required first');
                }
                final count = command['count'] as int? ?? 8;
                final intervalMs = command['intervalMs'] as int? ?? 150;
                final probeId = command['probeId'] as String? ?? id;
                final rootId = command['rootId'] as String? ?? 'home';
                final relPath = command['path'] as String;
                final length = command['bytes'] as int? ?? 1024 * 1024;
                unawaited(() async {
                  final rttsMs = <double>[];
                  for (var i = 0; i < count; i++) {
                    final sw = Stopwatch()..start();
                    final bytes = await client.read(
                      rootId,
                      relPath,
                      (i % 8) * length,
                      length,
                    );
                    sw.stop();
                    final ms = sw.elapsedMicroseconds / 1000.0;
                    rttsMs.add(ms);
                    events.emit('browse_read_sample', {
                      'probeId': probeId,
                      'seq': i,
                      'bytes': bytes.length,
                      'rttMs': ms,
                    });
                    if (i + 1 < count) {
                      await Future<void>.delayed(
                        Duration(milliseconds: intervalMs),
                      );
                    }
                  }
                  events.emit('browse_read_done', {
                    'probeId': probeId,
                    'rttsMs': rttsMs,
                  });
                }());
              default:
                throw ArgumentError('unknown action $action');
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
        throw TimeoutException('bench peer timed out');
      } finally {
        if (await sharedDir.exists()) {
          await sharedDir.delete(recursive: true);
        }
        await manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        );
        await database.close();
        events.emit('stopped', {});
      }
    },
    timeout: const Timeout(Duration(minutes: 16)),
  );
}

PeerProfile _profile(String uid, String host, int port) => PeerProfile(
  device: DeviceData(
    id: 0,
    uid: uid,
    name: 'Whisper bench',
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
    remoteFilesV1: true,
    remoteInputSourceV1: false,
    remoteInputSinkV1: false,
    remoteInputTopologyV1: false,
  ),
);

final class _SeedStorage implements DeviceIdentitySeedStorage {
  _SeedStorage(this.seed);
  final String seed;
  @override
  Future<String?> readSeed() async => seed;
  @override
  Future<void> writeSeed(String value) async =>
      throw StateError('seed is immutable');
}

class _BenchEvents implements ISocketEvent {
  _BenchEvents(Directory root) : file = File(p.join(root.path, 'events.jsonl'));
  final File file;
  final Stopwatch clock = Stopwatch()..start();
  final Map<String, int> _probeSentUs = <String, int>{};

  void recordProbeSent(String tag, int epochUs) {
    _probeSentUs[tag] = epochUs;
  }

  void emit(String event, Map<String, Object?> data) {
    file.writeAsStringSync(
      '${jsonEncode({'event': event, 'ms': clock.elapsedMicroseconds / 1000.0, 'epochUs': DateTime.now().microsecondsSinceEpoch, ...data})}\n',
      mode: FileMode.append,
    );
  }

  @override
  void onPairing(PairingRequest request, void Function(bool) resolve) =>
      resolve(false);
  @override
  void afterAuth(bool allow, DeviceData? device) =>
      emit('after_auth', {'allowed': allow});
  @override
  void onClose() => emit('disconnected', {});
  @override
  void onConnect() => emit('connected', {});
  @override
  void onError(String message, {String? peerId}) =>
      emit('socket_error', {'message': message, 'peerId': peerId});
  @override
  void onNotice(String message) => emit('notice', {'message': message});

  @override
  void onMessage(MessageData message) {
    if (message.type == MessageEnum.Text) {
      final content = message.content ?? '';
      final nowUs = DateTime.now().microsecondsSinceEpoch;
      if (message.acked && _probeSentUs.containsKey(content)) {
        final sentUs = _probeSentUs.remove(content)!;
        emit('probe_acked', {
          'content': content,
          'rttMs': (nowUs - sentUs) / 1000.0,
        });
      } else if (!message.acked) {
        emit('text_rx', {'content': content, 'rxUs': nowUs});
      }
    }
  }

  final Map<String, FileTransferState> _lastState = {};
  @override
  void onTransferUpdated(TransferSnapshot snapshot) {
    final prev = _lastState[snapshot.transferId];
    if (prev == snapshot.state &&
        snapshot.state != FileTransferState.completed &&
        snapshot.state != FileTransferState.failed) {
      return;
    }
    _lastState[snapshot.transferId] = snapshot.state;
    emit('transfer', {
      'transferId': snapshot.transferId,
      'direction': snapshot.direction.name,
      'state': snapshot.state.name,
      'bytes': snapshot.committedBytes,
      'size': snapshot.size,
      'error': snapshot.lastError,
    });
  }
}
