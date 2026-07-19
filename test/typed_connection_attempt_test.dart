import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/peer_endpoint.dart';

void main() {
  group('ConnectionAttemptRequest', () {
    test('automatic attempts require a peer and a public-key hash', () {
      expect(
        () => ConnectionAttemptRequest(
          requestId: 'auto-1',
          endpoint: PeerEndpoint(host: '192.168.1.10', port: 10002),
          mode: ConnectionAttemptMode.automatic,
        ),
        throwsArgumentError,
      );
      expect(
        () => ConnectionAttemptRequest(
          requestId: 'auto-4',
          endpoint: PeerEndpoint(host: '192.168.1.10', port: 10002),
          expectedPeerId: 'peer-a',
          expectedPublicKeyHash: '${List.filled(42, 'A').join()}B',
          mode: ConnectionAttemptMode.automatic,
        ),
        throwsArgumentError,
      );
      expect(
        () => ConnectionAttemptRequest(
          requestId: 'auto-3',
          endpoint: PeerEndpoint(host: '192.168.1.10', port: 10002),
          expectedPeerId: 'peer-a',
          expectedPublicKeyHash: 'not-a-canonical-hash',
          mode: ConnectionAttemptMode.automatic,
        ),
        throwsArgumentError,
      );
      expect(
        () => ConnectionAttemptRequest(
          requestId: 'auto-2',
          endpoint: PeerEndpoint(host: '192.168.1.10', port: 10002),
          expectedPeerId: 'peer-a',
          mode: ConnectionAttemptMode.automatic,
        ),
        throwsArgumentError,
      );
    });

    test('interactive attempts may target an unknown signed peer', () {
      final request = ConnectionAttemptRequest(
        requestId: 'manual-1',
        endpoint: PeerEndpoint(host: '192.168.1.10', port: 10002),
        mode: ConnectionAttemptMode.interactive,
      );

      expect(request.expectedPeerId, isEmpty);
      expect(request.expectedPublicKeyHash, isEmpty);
    });
  });

  group('ConnectionAttemptResult', () {
    test('authenticated result carries request, peer, and generation', () {
      final result = ConnectionAttemptResult.authenticated(
        requestId: 'manual-1',
        peerId: 'peer-a',
        generation: 4,
      );

      expect(result.status, ConnectionAttemptStatus.authenticated);
      expect(result.requestId, 'manual-1');
      expect(result.peerId, 'peer-a');
      expect(result.generation, 4);
    });

    test('authenticated result rejects empty identity or generation', () {
      expect(
        () => ConnectionAttemptResult.authenticated(
          requestId: 'manual-1',
          peerId: '',
          generation: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => ConnectionAttemptResult.authenticated(
          requestId: 'manual-1',
          peerId: 'peer-a',
          generation: 0,
        ),
        throwsArgumentError,
      );
    });

    test('terminal failures retain a stable reason without peer payload', () {
      for (final result in <ConnectionAttemptResult>[
        ConnectionAttemptResult.cancelled(
          requestId: 'cancelled',
          reason: ConnectionAttemptReason.manualDisconnect,
        ),
        ConnectionAttemptResult.rejected(
          requestId: 'rejected',
          reason: ConnectionAttemptReason.identityMismatch,
        ),
        ConnectionAttemptResult.networkFailure(
          requestId: 'network',
          reason: ConnectionAttemptReason.socketError,
        ),
      ]) {
        expect(result.peerId, isEmpty);
        expect(result.generation, 0);
        expect(result.reason, isNot(ConnectionAttemptReason.none));
      }
    });
  });
}
