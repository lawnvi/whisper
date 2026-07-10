import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/socket/peer_transfer_runtime.dart';

void main() {
  group('MultiPeerTransferRuntime', () {
    test('allows outgoing transfers to different peers to run concurrently',
        () {
      final runtime = MultiPeerTransferRuntime();

      final first = runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-1',
        direction: FileTransferDirection.outgoing,
      );
      final second = runtime.enqueue(
        peerId: 'peer-c',
        transferId: 'transfer-c-1',
        direction: FileTransferDirection.outgoing,
      );

      expect(first, TransferRuntimeDecision.started);
      expect(second, TransferRuntimeDecision.started);
      expect(runtime.activeOutgoingFor('peer-b'), 'transfer-b-1');
      expect(runtime.activeOutgoingFor('peer-c'), 'transfer-c-1');
    });

    test('queues a second outgoing transfer for the same peer', () {
      final runtime = MultiPeerTransferRuntime();

      runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-1',
        direction: FileTransferDirection.outgoing,
      );
      final second = runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-2',
        direction: FileTransferDirection.outgoing,
      );

      expect(second, TransferRuntimeDecision.queued);
      expect(runtime.activeOutgoingFor('peer-b'), 'transfer-b-1');
      expect(runtime.queuedOutgoingFor('peer-b'), ['transfer-b-2']);
    });

    test('deduplicates repeated enqueue attempts for the same transfer', () {
      final runtime = MultiPeerTransferRuntime();

      runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-1',
        direction: FileTransferDirection.incoming,
      );
      final repeatedActive = runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-1',
        direction: FileTransferDirection.incoming,
      );
      runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-2',
        direction: FileTransferDirection.incoming,
      );
      final repeatedQueued = runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-2',
        direction: FileTransferDirection.incoming,
      );

      expect(repeatedActive, TransferRuntimeDecision.started);
      expect(repeatedQueued, TransferRuntimeDecision.queued);
      expect(runtime.queuedIncomingFor('peer-b'), ['transfer-b-2']);
    });

    test('clearAll removes all peer transfer state', () {
      final runtime = MultiPeerTransferRuntime();
      runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-1',
        direction: FileTransferDirection.outgoing,
      );
      runtime.enqueue(
        peerId: 'peer-c',
        transferId: 'transfer-c-1',
        direction: FileTransferDirection.incoming,
      );

      runtime.clearAll();

      expect(runtime.activeOutgoingFor('peer-b'), isNull);
      expect(runtime.activeIncomingFor('peer-c'), isNull);
    });

    test('release and claim advance an active transfer explicitly', () {
      final runtime = MultiPeerTransferRuntime();
      runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-1',
        direction: FileTransferDirection.incoming,
      );
      runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-2',
        direction: FileTransferDirection.incoming,
      );

      final released = runtime.release(
        peerId: 'peer-b',
        transferId: 'transfer-b-1',
        direction: FileTransferDirection.incoming,
      );

      expect(released, TransferRuntimeReleaseKind.activeReleased);
      expect(runtime.activeIncomingFor('peer-b'), isNull);
      expect(runtime.queuedIncomingFor('peer-b'), ['transfer-b-2']);

      final next = runtime.claimNext(
        peerId: 'peer-b',
        direction: FileTransferDirection.incoming,
      );
      expect(next, 'transfer-b-2');
      expect(runtime.activeIncomingFor('peer-b'), 'transfer-b-2');
      expect(runtime.queuedIncomingFor('peer-b'), isEmpty);
    });

    test('releasing a queued transfer never disturbs the active transfer', () {
      final runtime = MultiPeerTransferRuntime();
      runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-1',
        direction: FileTransferDirection.outgoing,
      );
      runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-2',
        direction: FileTransferDirection.outgoing,
      );

      final released = runtime.release(
        peerId: 'peer-b',
        transferId: 'transfer-b-2',
        direction: FileTransferDirection.outgoing,
      );

      expect(released, TransferRuntimeReleaseKind.queuedRemoved);
      expect(runtime.activeOutgoingFor('peer-b'), 'transfer-b-1');
      expect(runtime.queuedOutgoingFor('peer-b'), isEmpty);
    });

    test('claimNext is legal only while the direction is idle', () {
      final runtime = MultiPeerTransferRuntime();
      runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-1',
        direction: FileTransferDirection.outgoing,
      );
      runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-2',
        direction: FileTransferDirection.outgoing,
      );

      expect(
        runtime.claimNext(
          peerId: 'peer-b',
          direction: FileTransferDirection.outgoing,
        ),
        isNull,
      );
      expect(runtime.queuedOutgoingFor('peer-b'), ['transfer-b-2']);
    });

    test('release reports absent without changing another transfer', () {
      final runtime = MultiPeerTransferRuntime();
      runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-1',
        direction: FileTransferDirection.incoming,
      );

      expect(
        runtime.release(
          peerId: 'peer-b',
          transferId: 'missing',
          direction: FileTransferDirection.incoming,
        ),
        TransferRuntimeReleaseKind.absent,
      );
      expect(runtime.activeIncomingFor('peer-b'), 'transfer-b-1');
    });

    test('disconnecting one peer clears only that peer transfer state', () {
      final runtime = MultiPeerTransferRuntime();
      runtime.enqueue(
        peerId: 'peer-b',
        transferId: 'transfer-b-1',
        direction: FileTransferDirection.outgoing,
      );
      runtime.enqueue(
        peerId: 'peer-c',
        transferId: 'transfer-c-1',
        direction: FileTransferDirection.outgoing,
      );

      runtime.clearPeer('peer-b');

      expect(runtime.activeOutgoingFor('peer-b'), isNull);
      expect(runtime.activeOutgoingFor('peer-c'), 'transfer-c-1');
    });
  });
}
