import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/peer_connection.dart';

void main() {
  test('sendTo only delivers messages to the targeted peer', () {
    final sentToB = <Object>[];
    final sentToC = <Object>[];
    final registry = PeerConnectionRegistry()
      ..register(
        PeerConnection(
          peerId: 'peer-b',
          connectionId: 1,
          send: sentToB.add,
          close: () async {},
        ),
      )
      ..register(
        PeerConnection(
          peerId: 'peer-c',
          connectionId: 2,
          send: sentToC.add,
          close: () async {},
        ),
      );

    final delivered = registry.sendTo('peer-b', 'hello-b');

    expect(delivered, isTrue);
    expect(sentToB, ['hello-b']);
    expect(sentToC, isEmpty);
  });

  test('sendTo returns false for an unknown peer', () {
    final registry = PeerConnectionRegistry();

    expect(registry.sendTo('missing', 'message'), isFalse);
  });

  test('sendToAwaited returns the transport enqueue result', () async {
    final registry = PeerConnectionRegistry();
    await registry.register(
      PeerConnection(
        peerId: 'peer-b',
        connectionId: 1,
        send: (_) {},
        sendAsync: (_) async => false,
        close: () async {},
      ),
    );

    expect(await registry.sendToAwaited('peer-b', 'message'), isFalse);
    expect(await registry.sendToAwaited('missing', 'message'), isFalse);
  });

  test('failed explicit peer enqueue never falls back to another peer',
      () async {
    final sentToY = <Object>[];
    var attemptedX = 0;
    final registry = PeerConnectionRegistry();
    await registry.register(
      PeerConnection(
        peerId: 'peer-x',
        connectionId: 1,
        send: (_) {},
        sendAsync: (_) async {
          attemptedX += 1;
          return false;
        },
        close: () async {},
      ),
    );
    await registry.register(
      PeerConnection(
        peerId: 'peer-y',
        connectionId: 2,
        send: sentToY.add,
        close: () async {},
      ),
    );

    final sent = await registry.sendTargetedOrDefault(
      peerId: 'peer-x',
      message: 'for-x',
      sendDefault: () async {
        registry.sendTo('peer-y', 'for-x');
        return true;
      },
    );

    expect(sent, isFalse);
    expect(attemptedX, 1);
    expect(sentToY, isEmpty);
  });
}
