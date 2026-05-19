import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';

void main() {
  group('RemoteInputWorkspaceLayoutValidator', () {
    test('rejects overlapping target segments on the same source edge', () {
      final result = RemoteInputWorkspaceLayoutValidator.validateTargets([
        RemoteInputWorkspaceTargetRequest(
          peerId: 'peer-b',
          peerName: 'Peer B',
          host: '192.168.1.20',
          port: 10002,
          layoutEdge: RemoteInputEdge.right,
          releaseHotkey: 'ctrl+alt+esc',
          isMutuallyTrusted: true,
          remoteCanInject: true,
          edgeMappings: const [
            RemoteInputEdgeMapping(
              routeId: 'b-right',
              sourceDisplayId: 'main',
              sourceEdge: RemoteInputEdge.right,
              sourceSegmentStart: 100,
              sourceSegmentEnd: 500,
              sinkDisplayId: 'b-main',
              sinkEdge: RemoteInputEdge.left,
              sinkSegmentStart: 0,
              sinkSegmentEnd: 400,
            ),
          ],
        ),
        RemoteInputWorkspaceTargetRequest(
          peerId: 'peer-c',
          peerName: 'Peer C',
          host: '192.168.1.21',
          port: 10002,
          layoutEdge: RemoteInputEdge.right,
          releaseHotkey: 'ctrl+alt+esc',
          isMutuallyTrusted: true,
          remoteCanInject: true,
          edgeMappings: const [
            RemoteInputEdgeMapping(
              routeId: 'c-right',
              sourceDisplayId: 'main',
              sourceEdge: RemoteInputEdge.right,
              sourceSegmentStart: 450,
              sourceSegmentEnd: 900,
              sinkDisplayId: 'c-main',
              sinkEdge: RemoteInputEdge.left,
              sinkSegmentStart: 0,
              sinkSegmentEnd: 450,
            ),
          ],
        ),
      ]);

      expect(result.hasConflict, isTrue);
      expect(result.conflictingPeerIds, unorderedEquals(['peer-b', 'peer-c']));
    });

    test('accepts adjacent non-overlapping target segments', () {
      final result = RemoteInputWorkspaceLayoutValidator.validateTargets([
        RemoteInputWorkspaceTargetRequest(
          peerId: 'peer-b',
          peerName: 'Peer B',
          host: '192.168.1.20',
          port: 10002,
          layoutEdge: RemoteInputEdge.right,
          releaseHotkey: 'ctrl+alt+esc',
          isMutuallyTrusted: true,
          remoteCanInject: true,
          edgeMappings: const [
            RemoteInputEdgeMapping(
              routeId: 'b-right',
              sourceDisplayId: 'main',
              sourceEdge: RemoteInputEdge.right,
              sourceSegmentStart: 100,
              sourceSegmentEnd: 500,
              sinkDisplayId: 'b-main',
              sinkEdge: RemoteInputEdge.left,
              sinkSegmentStart: 0,
              sinkSegmentEnd: 400,
            ),
          ],
        ),
        RemoteInputWorkspaceTargetRequest(
          peerId: 'peer-c',
          peerName: 'Peer C',
          host: '192.168.1.21',
          port: 10002,
          layoutEdge: RemoteInputEdge.right,
          releaseHotkey: 'ctrl+alt+esc',
          isMutuallyTrusted: true,
          remoteCanInject: true,
          edgeMappings: const [
            RemoteInputEdgeMapping(
              routeId: 'c-right',
              sourceDisplayId: 'main',
              sourceEdge: RemoteInputEdge.right,
              sourceSegmentStart: 500,
              sourceSegmentEnd: 900,
              sinkDisplayId: 'c-main',
              sinkEdge: RemoteInputEdge.left,
              sinkSegmentStart: 0,
              sinkSegmentEnd: 400,
            ),
          ],
        ),
      ]);

      expect(result.hasConflict, isFalse);
      expect(result.conflictingPeerIds, isEmpty);
    });
  });
}
