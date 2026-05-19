import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/peer_connection.dart';

void main() {
  group('PeerConnectionRegistry', () {
    test('keeps multiple authenticated peers connected at the same time', () {
      final registry = PeerConnectionRegistry();

      registry.register(
        PeerConnection(
          peerId: 'peer-b',
          send: (_) {},
          close: () async {},
        ),
      );
      registry.register(
        PeerConnection(
          peerId: 'peer-c',
          send: (_) {},
          close: () async {},
        ),
      );

      expect(registry.connectedPeerIds, {'peer-b', 'peer-c'});
      expect(registry.isConnectedTo('peer-b'), isTrue);
      expect(registry.isConnectedTo('peer-c'), isTrue);
    });

    test('disconnecting one peer does not affect other connected peers',
        () async {
      final registry = PeerConnectionRegistry();
      var closedB = false;
      var closedC = false;

      registry.register(
        PeerConnection(
          peerId: 'peer-b',
          send: (_) {},
          close: () async {
            closedB = true;
          },
        ),
      );
      registry.register(
        PeerConnection(
          peerId: 'peer-c',
          send: (_) {},
          close: () async {
            closedC = true;
          },
        ),
      );

      await registry.disconnect('peer-b');

      expect(closedB, isTrue);
      expect(closedC, isFalse);
      expect(registry.connectedPeerIds, {'peer-c'});
    });

    test('replacing a duplicate peer closes the old connection', () async {
      final registry = PeerConnectionRegistry();
      var oldClosed = false;
      var newClosed = false;

      registry.register(
        PeerConnection(
          peerId: 'peer-b',
          send: (_) {},
          close: () async {
            oldClosed = true;
          },
        ),
      );
      await registry.register(
        PeerConnection(
          peerId: 'peer-b',
          send: (_) {},
          close: () async {
            newClosed = true;
          },
        ),
      );

      expect(oldClosed, isTrue);
      expect(newClosed, isFalse);
      expect(registry.connectedPeerIds, {'peer-b'});

      await registry.disconnect('peer-b');
      expect(newClosed, isTrue);
    });
  });
}
