import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/file_transfer_engine.dart';

FileTransferEngine _engine({
  bool Function(String, Object)? sendBytesToPeer,
  void Function(String)? notify,
}) {
  return FileTransferEngine(
    sendBytesToPeer: sendBytesToPeer ?? (_, __) => true,
    emitTransferUpdated: (_) {},
    notify: notify ?? (_) {},
    remoteProfileFor: (_) => null, // 无 profile ⇒ 无 fileTransferV3 能力
    localUid: () => 'local-uid',
    isConnectedTo: (_) => true,
    connectedPeerIds: () => <String>{},
    defaultPeerId: () => '',
    hasLegacySinkFor: (_) => false,
    buildMessage: (type, content, msg, fileName, size, clipboard,
            {md5 = '', path = '', uid, fileTimestamp = 0, receiverOverride}) =>
        throw UnimplementedError('buildMessage 不应被本测试触达'),
    dispatchOutgoingMessage: (_) {},
    ackMessage: (_) {},
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

    final ok = await engine.sendFileTo('peer-x', '/tmp/whisper-test-nonexistent.bin');

    expect(ok, isFalse);
    expect(sent, isFalse, reason: '能力不满足时不得发出任何字节');
    expect(notices, isNotEmpty, reason: '拒发必须通过 notify 告知');
  });
}
