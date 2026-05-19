import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RemoteInputWorkspaceCoordinator', () {
    late MethodChannel channel;
    late List<MethodCall> calls;
    late RemoteInputPlatform platform;
    late Map<String, _FakeRemoteInputTransport> transports;
    late Map<String, List<RemoteInputControlMessage>> sentControls;

    setUp(() {
      channel = const MethodChannel('test_remote_input_workspace');
      calls = <MethodCall>[];
      platform = RemoteInputPlatform(channel: channel);
      transports = <String, _FakeRemoteInputTransport>{};
      sentControls = <String, List<RemoteInputControlMessage>>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('keeps multiple accepted targets and routes input by routeId',
        () async {
      final coordinator = RemoteInputWorkspaceCoordinator(
        platform: platform,
        transportFactory: (uri) async {
          final transport = _FakeRemoteInputTransport();
          transports[uri.host] = transport;
          return transport;
        },
        workspaceSessionIdFactory: () => 'workspace-1',
      );

      await coordinator.startControllerWorkspace(
        sourcePeerId: 'mac',
        targets: [
          _targetRequest(
            peerId: 'peer-b',
            host: 'peer-b.local',
            routeId: 'route-b',
            start: 0,
            end: 400,
          ),
          _targetRequest(
            peerId: 'peer-c',
            host: 'peer-c.local',
            routeId: 'route-c',
            start: 400,
            end: 800,
          ),
        ],
        sendControlTo: (peerId, control) {
          sentControls.putIfAbsent(peerId, () => []).add(control);
        },
      );

      final offerB = sentControls['peer-b']!.single;
      final offerC = sentControls['peer-c']!.single;
      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.accept,
          sessionId: offerB.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'peer-b',
          layoutEdge: RemoteInputEdge.right,
          releaseHotkey: 'ctrl+alt+esc',
          path: '/input',
        ),
        localPeerId: 'mac',
        remoteHost: 'peer-b.local',
        remotePort: 10002,
        sendControlTo: (peerId, control) {
          sentControls.putIfAbsent(peerId, () => []).add(control);
        },
      );
      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.accept,
          sessionId: offerC.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'peer-c',
          layoutEdge: RemoteInputEdge.right,
          releaseHotkey: 'ctrl+alt+esc',
          path: '/input',
        ),
        localPeerId: 'mac',
        remoteHost: 'peer-c.local',
        remotePort: 10002,
        sendControlTo: (peerId, control) {
          sentControls.putIfAbsent(peerId, () => []).add(control);
        },
      );

      expect(coordinator.snapshot.role, RemoteInputWorkspaceRole.controller);
      expect(coordinator.snapshot.connectedTargetPeerIds,
          unorderedEquals(['peer-b', 'peer-c']));
      final startCapture = calls.lastWhere(
        (call) => call.method == 'startCapture',
      );
      expect(startCapture.arguments['sessionId'], 'workspace-1');
      expect(startCapture.arguments['segments'], hasLength(2));

      await platform.handleNativeMethodCall(
        MethodCall('onInputEvent', <String, dynamic>{
          'sessionId': 'workspace-1',
          'sequence': 1,
          'timestampMicros': 1,
          'eventType': 'mouseMove',
          'payload': Uint8List.fromList(
            utf8.encode(jsonEncode(<String, dynamic>{
              'activeStart': true,
              'routeId': 'workspace-1|peer-c|route-c',
              'deltaX': 8,
              'deltaY': 0,
            })),
          ),
        }),
      );
      await platform.handleNativeMethodCall(
        MethodCall('onInputEvent', <String, dynamic>{
          'sessionId': 'workspace-1',
          'sequence': 2,
          'timestampMicros': 2,
          'eventType': 'key',
          'payload': Uint8List.fromList(
            utf8.encode(jsonEncode(<String, dynamic>{'key': 'A'})),
          ),
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(transports['peer-b.local']!.sentPackets, isEmpty);
      expect(transports['peer-c.local']!.sentPackets, hasLength(2));
      expect(transports['peer-c.local']!.sentPackets.first.sessionId,
          offerC.sessionId);
      expect(coordinator.snapshot.activePeerId, 'peer-c');
    });

    test('release from one target pauses capture without stopping others',
        () async {
      final coordinator = RemoteInputWorkspaceCoordinator(
        platform: platform,
        transportFactory: (uri) async {
          final transport = _FakeRemoteInputTransport();
          transports[uri.host] = transport;
          return transport;
        },
        workspaceSessionIdFactory: () => 'workspace-1',
      );
      await coordinator.startControllerWorkspace(
        sourcePeerId: 'mac',
        targets: [
          _targetRequest(
            peerId: 'peer-b',
            host: 'peer-b.local',
            routeId: 'route-b',
            start: 0,
            end: 400,
          ),
          _targetRequest(
            peerId: 'peer-c',
            host: 'peer-c.local',
            routeId: 'route-c',
            start: 400,
            end: 800,
          ),
        ],
        sendControlTo: (peerId, control) {
          sentControls.putIfAbsent(peerId, () => []).add(control);
        },
      );
      for (final peerId in ['peer-b', 'peer-c']) {
        final offer = sentControls[peerId]!.single;
        await coordinator.handleControlMessage(
          RemoteInputControlMessage(
            action: RemoteInputControlAction.accept,
            sessionId: offer.sessionId,
            sourcePeerId: 'mac',
            sinkPeerId: peerId,
            layoutEdge: RemoteInputEdge.right,
            releaseHotkey: 'ctrl+alt+esc',
            path: '/input',
          ),
          localPeerId: 'mac',
          remoteHost: '$peerId.local',
          remotePort: 10002,
          sendControlTo: (peerId, control) {
            sentControls.putIfAbsent(peerId, () => []).add(control);
          },
        );
      }

      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.release,
          sessionId: sentControls['peer-c']!.single.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'peer-c',
          releaseReason: 'edge',
          releaseSequence: 5,
          releaseActivationSequence: 3,
          releaseEdgeUnit: 0.25,
          routeId: 'workspace-1|peer-c|route-c',
        ),
        localPeerId: 'mac',
        remoteHost: 'peer-c.local',
        remotePort: 10002,
        sendControlTo: (peerId, control) {
          sentControls.putIfAbsent(peerId, () => []).add(control);
        },
      );

      final pauseCapture = calls.lastWhere(
        (call) => call.method == 'pauseCapture',
      );
      expect(pauseCapture.arguments['sessionId'], 'workspace-1');
      expect(pauseCapture.arguments['routeId'], 'workspace-1|peer-c|route-c');
      expect(coordinator.snapshot.connectedTargetPeerIds,
          unorderedEquals(['peer-b', 'peer-c']));
      expect(coordinator.snapshot.status, RemoteInputWorkspaceStatus.armed);
    });

    test('controller role rejects incoming sink offers', () async {
      final coordinator = RemoteInputWorkspaceCoordinator(
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
        workspaceSessionIdFactory: () => 'workspace-1',
      );
      await coordinator.startControllerWorkspace(
        sourcePeerId: 'mac',
        targets: [
          _targetRequest(
            peerId: 'peer-b',
            host: 'peer-b.local',
            routeId: 'route-b',
            start: 0,
            end: 400,
          ),
        ],
        sendControlTo: (peerId, control) {
          sentControls.putIfAbsent(peerId, () => []).add(control);
        },
      );

      final handled = await coordinator.handleIncomingOfferIfBusy(
        const RemoteInputControlMessage(
          action: RemoteInputControlAction.offer,
          sessionId: 'incoming-1',
          sourcePeerId: 'peer-d',
          sinkPeerId: 'mac',
          layoutEdge: RemoteInputEdge.left,
          releaseHotkey: 'ctrl+alt+esc',
        ),
        localPeerId: 'mac',
        sendControlTo: (peerId, control) {
          sentControls.putIfAbsent(peerId, () => []).add(control);
        },
      );

      expect(handled, isTrue);
      expect(
          sentControls['peer-d']!.last.action, RemoteInputControlAction.reject);
      expect(sentControls['peer-d']!.last.errorMessage,
          contains('controller workspace'));
    });

    test('returns to idle when the only target rejects the offer', () async {
      final coordinator = RemoteInputWorkspaceCoordinator(
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
        workspaceSessionIdFactory: () => 'workspace-1',
      );
      await coordinator.startControllerWorkspace(
        sourcePeerId: 'mac',
        targets: [
          _targetRequest(
            peerId: 'peer-b',
            host: 'peer-b.local',
            routeId: 'route-b',
            start: 0,
            end: 400,
          ),
        ],
        sendControlTo: (peerId, control) {
          sentControls.putIfAbsent(peerId, () => []).add(control);
        },
      );

      final offer = sentControls['peer-b']!.single;
      final handled = await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.reject,
          sessionId: offer.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'peer-b',
          errorMessage: 'busy',
        ),
        localPeerId: 'mac',
        remoteHost: 'peer-b.local',
        remotePort: 10002,
        sendControlTo: (peerId, control) {
          sentControls.putIfAbsent(peerId, () => []).add(control);
        },
      );

      expect(handled, isTrue);
      expect(coordinator.snapshot.role, RemoteInputWorkspaceRole.idle);
      expect(coordinator.snapshot.status, RemoteInputWorkspaceStatus.idle);
      expect(coordinator.snapshot.liveTargetPeerIds, isEmpty);
    });
  });
}

RemoteInputWorkspaceTargetRequest _targetRequest({
  required String peerId,
  required String host,
  required String routeId,
  required int start,
  required int end,
}) {
  return RemoteInputWorkspaceTargetRequest(
    peerId: peerId,
    peerName: peerId,
    host: host,
    port: 10002,
    layoutEdge: RemoteInputEdge.right,
    releaseHotkey: 'ctrl+alt+esc',
    isMutuallyTrusted: true,
    remoteCanInject: true,
    edgeMappings: [
      RemoteInputEdgeMapping(
        routeId: routeId,
        sourceDisplayId: 'main',
        sourceEdge: RemoteInputEdge.right,
        sourceSegmentStart: start,
        sourceSegmentEnd: end,
        sinkDisplayId: '$peerId-main',
        sinkEdge: RemoteInputEdge.left,
        sinkSegmentStart: 0,
        sinkSegmentEnd: end - start,
      ),
    ],
  );
}

class _FakeRemoteInputTransport implements RemoteInputPacketTransport {
  final sentPackets = <RemoteInputPacketFrame>[];
  bool closed = false;

  @override
  void send(RemoteInputPacketFrame packet) {
    if (!closed) {
      sentPackets.add(packet);
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
