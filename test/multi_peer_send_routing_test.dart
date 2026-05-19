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
          send: sentToB.add,
          close: () async {},
        ),
      )
      ..register(
        PeerConnection(
          peerId: 'peer-c',
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
}
