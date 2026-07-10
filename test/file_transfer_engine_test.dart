import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/wire_message_replay.dart';

FileTransferEngine _engine({
  bool Function(String, Object)? sendBytesToPeer,
  void Function(String)? notify,
  LocalDatabase? database,
  Set<String> connectedPeerIds = const <String>{},
}) {
  return FileTransferEngine(
    sendBytesToPeer: sendBytesToPeer ?? (_, __) => true,
    emitTransferUpdated: (_) {},
    notify: notify ?? (_) {},
    remoteProfileFor: (_) => null, // 无 profile ⇒ 无 fileTransferV3 能力
    isConnectedTo: (_) => true,
    connectedPeerIds: () => connectedPeerIds,
    defaultPeerId: () => '',
    hasLegacySinkFor: (_) => false,
    localPeerIdFor: (_) => 'local',
    buildMessage: (type, content, msg, fileName, size, clipboard,
            {md5 = '', path = '', uid, fileTimestamp = 0, receiverOverride}) =>
        throw UnimplementedError('buildMessage 不应被本测试触达'),
    dispatchOutgoingMessage: (_) {},
    ackMessage: (_) {},
    wireMessageReplayGuard: WireMessageReplayGuard(),
    database: database == null ? LocalDatabase.new : () => database,
  );
}

void main() {
  test('engine is constructible with injected fakes only', () {
    expect(_engine(), isNotNull);
  });

  test('sendFileTo rejects peer without fileTransferV3 and notifies', () async {
    final notices = <String>[];
    var sent = false;
    final engine = _engine(
      sendBytesToPeer: (_, __) {
        sent = true;
        return true;
      },
      notify: notices.add,
    );

    final ok =
        await engine.sendFileTo('peer-x', '/tmp/whisper-test-nonexistent.bin');

    expect(ok, isFalse);
    expect(sent, isFalse, reason: '能力不满足时不得发出任何字节');
    expect(notices, isNotEmpty, reason: '拒发必须通过 notify 告知');
  });

  test('closeAll awaits recoverable transfer persistence', () async {
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.upsertFileTransfer(
      FileTransferData(
        transferId: 'active-transfer',
        messageUuid: 'message-1',
        peerUid: 'peer-a',
        direction: FileTransferDirection.outgoing,
        state: FileTransferState.transferring,
        finalPath: '/tmp/archive.zip',
        tempPath: '/tmp/archive.zip.part',
        size: 1024,
        checksumAlgorithm: 'sha256',
        checksumValue: 'abc',
        chunkSize: 512,
        committedBytes: 256,
        lastError: '',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    final engine = _engine(
      database: database,
    );

    await engine.closeAll();

    expect(
      (await database.fetchFileTransfer('active-transfer'))?.state,
      FileTransferState.waitingReconnect,
    );
  });
}
