import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/folder_transfer_store.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:whisper/state/peer_reconnect_controller.dart';

/// A device with everything of its own: identity, database, downloads.
final class _Peer {
  _Peer(this.uid, Directory temp, int seed)
    : downloads = Directory(p.join(temp.path, '$uid-downloads'))..createSync(),
      store = FolderTransferStore(
        directory: () async => Directory(p.join(temp.path, '$uid-store')),
      ) {
    manager = WsSvrManager.forTesting(
      database: database,
      identityStore: DeviceIdentityStore(
        storage: _SeedStorage(
          Uint8List.fromList(List<int>.generate(32, (index) => seed + index)),
        ),
      ),
      localPeerProfileLoader: () async => _profile(uid),
      autoConnectEnabled: () async => false,
      reconnectControllerFactory: ({required attempt, required eligibility}) =>
          PeerReconnectController(attempt: attempt, eligibility: eligibility),
      manageSharedCoordinators: false,
      transferDownloadDirectory: () async => downloads,
      folderTransferStore: store,
    );
    manager.setEvent(events);
  }

  final String uid;
  final Directory downloads;
  final FolderTransferStore store;
  final LocalDatabase database = LocalDatabase.forTesting(
    NativeDatabase.memory(),
  );
  final _Events events = _Events();
  late final WsSvrManager manager;

  Future<FileTransferData> waitForCompleted(String transferId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    FileTransferData? latest;
    while (DateTime.now().isBefore(deadline)) {
      latest = await database.fetchFileTransfer(transferId);
      if (latest?.state == FileTransferState.completed) return latest!;
      if (latest?.state == FileTransferState.failed) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail(
      '$uid: transfer is ${latest?.state} (${latest?.lastError}); '
      'notices ${events.notices}',
    );
  }

  Future<void> dispose() async {
    await manager.closeGracefully(closeServer: true, forceServerClose: true);
    await database.close();
  }
}

final class _SeedStorage implements DeviceIdentitySeedStorage {
  _SeedStorage(this.seed);

  final Uint8List seed;

  @override
  Future<String?> readSeed() async =>
      base64Url.encode(seed).replaceAll('=', '');

  @override
  Future<void> writeSeed(String value) async {}
}

final class _Events implements ISocketEvent {
  final List<String> notices = <String>[];
  final List<MessageData> messages = <MessageData>[];

  @override
  void afterAuth(bool allow, DeviceData? device) {}

  @override
  void onPairing(PairingRequest request, void Function(bool) resolve) =>
      resolve(true);

  @override
  void onClose() {}

  @override
  void onConnect() {}

  @override
  void onError(String message) {}

  @override
  void onMessage(MessageData messageData) => messages.add(messageData);

  @override
  void onNotice(String message) => notices.add(message);

  @override
  void onTransferUpdated(TransferSnapshot snapshot) {}
}

PeerProfile _profile(String uid) => PeerProfile(
  device: DeviceData(
    id: 0,
    uid: uid,
    name: uid,
    host: '192.168.1.10',
    port: 10002,
    password: '',
    platform: 'test',
    isServer: true,
    online: true,
    clipboard: true,
    auth: false,
    lastTime: 1,
    around: true,
  ),
  trustedPeerIds: const <String>[],
  autoApproveNewDevices: false,
  autoConnectEnabled: true,
  protocolVersion: PeerSocketSession.protocolVersion,
  capabilities: const PeerCapabilities(fileTransferV3: true),
);

Map<String, String> _snapshot(Directory root) {
  final result = <String, String>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    final relative = p
        .relative(entity.path, from: root.path)
        .replaceAll(r'\', '/');
    if (entity is Directory) {
      result['$relative/'] = '';
    } else if (entity is File) {
      result[relative] = sha256.convert(entity.readAsBytesSync()).toString();
    }
  }
  return result;
}

void main() {
  test(
    'a folder crosses a real encrypted connection and arrives intact',
    () async {
      final temp = Directory.systemTemp.createTempSync('whisper-folder-link-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final source = Directory(p.join(temp.path, 'Shared Folder'))
        ..createSync();
      final random = math.Random(21);
      Uint8List bytes(int length) => Uint8List.fromList(
        List<int>.generate(length, (_) => random.nextInt(256)),
      );
      final files = <String, List<int>>{
        'notes.txt': utf8.encode('hello'),
        'empty': const <int>[],
        'media/video.bin': bytes(9 * 1024 * 1024),
        '文档/说明.md': utf8.encode('内容'),
        for (var index = 0; index < 1500; index += 1)
          'cache/c${index % 23}/item$index': bytes(30 + index % 500),
      };
      for (final entry in files.entries) {
        final file = File(p.join(source.path, entry.key));
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(entry.value);
      }
      Directory(p.join(source.path, 'hollow')).createSync();

      final receiver = _Peer('receiver-peer', temp, 1);
      final sender = _Peer('sender-peer', temp, 33);
      addTearDown(sender.dispose);
      addTearDown(receiver.dispose);
      final started = await receiver.manager.startServer(0);
      expect(started.isSuccess, isTrue);
      final connected = await sender.manager
          .connectToServer(
            ConnectionAttemptRequest(
              requestId: 'folder-link',
              endpoint: PeerEndpoint.loopbackForTesting(port: started.port),
              expectedPeerId: 'receiver-peer',
              mode: ConnectionAttemptMode.interactive,
            ),
          )
          .timeout(const Duration(seconds: 10));
      expect(connected.status, ConnectionAttemptStatus.authenticated);

      expect(
        await sender.manager.sendFolderTo('receiver-peer', source.path),
        FolderSendOutcome.sent,
      );
      final transferId = sender.events.messages.single.uuid;
      final received = await receiver.waitForCompleted(transferId);
      final sent = await sender.waitForCompleted(transferId);

      expect(_snapshot(Directory(received.finalPath)), _snapshot(source));
      expect(p.basename(received.finalPath), 'Shared Folder');
      expect(received.skippedEntries ?? 0, 0);
      expect(sent.committedBytes, sent.size);
      expect(receiver.events.messages.single.name, 'Shared Folder');
      expect(sender.events.notices, isEmpty);
      expect(receiver.events.notices, isEmpty);
      expect(sender.manager.isConnectedTo('receiver-peer'), isTrue);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
