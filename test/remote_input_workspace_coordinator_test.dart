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
  final mediaKey = Uint8List.fromList(List<int>.generate(32, (index) => index));

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
          expect(uri.queryParameters['session'], isNotEmpty);
          expect(uri.queryParameters['token'], startsWith('workspace-token-'));
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
          transportToken: 'workspace-token-b',
        ),
        localPeerId: 'mac',
        remoteHost: 'peer-b.local',
        remotePort: 10002,
        mediaSendKey: mediaKey,
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
          transportToken: 'workspace-token-c',
        ),
        localPeerId: 'mac',
        remoteHost: 'peer-c.local',
        remotePort: 10002,
        mediaSendKey: mediaKey,
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
      expect(sentControls['peer-d']!.last.errorMessage, 'busy');
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

    test('workspace drops remote error text before publishing failure',
        () async {
      final sentControls = <String, List<RemoteInputControlMessage>>{};
      final coordinator = RemoteInputWorkspaceCoordinator(
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
        workspaceSessionIdFactory: () => 'workspace-private',
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
      const remoteText =
          'remote token=never-store-this /Users/alice/private.txt';

      final handled = await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.error,
          sessionId: offer.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'peer-b',
          errorMessage: remoteText,
        ),
        localPeerId: 'mac',
        remoteHost: 'peer-b.local',
        remotePort: 10002,
        sendControlTo: (peerId, control) {},
      );

      expect(handled, isTrue);
      expect(coordinator.snapshot.status, RemoteInputWorkspaceStatus.failed);
      expect(coordinator.snapshot.errorMessage, 'remoteFailure');
      expect(
        coordinator.snapshot.targets['peer-b']?.errorMessage,
        'remoteFailure',
      );
      expect(coordinator.snapshot.errorMessage, isNot(contains(remoteText)));
    });

    test('workspace preserves an allowlisted remote failure reason', () async {
      final sentControls = <String, List<RemoteInputControlMessage>>{};
      final coordinator = RemoteInputWorkspaceCoordinator(
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
        workspaceSessionIdFactory: () => 'workspace-reason',
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
          action: RemoteInputControlAction.error,
          sessionId: offer.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'peer-b',
          errorMessage: 'trustRequired',
        ),
        localPeerId: 'mac',
        remoteHost: 'peer-b.local',
        remotePort: 10002,
        sendControlTo: (peerId, control) {},
      );

      expect(handled, isTrue);
      expect(coordinator.snapshot.errorMessage, 'trustRequired');
      expect(
        coordinator.snapshot.targets['peer-b']?.errorMessage,
        'trustRequired',
      );
    });

    test('stops capture when the only target packet transport closes',
        () async {
      final transport = _ObservableFakeRemoteInputTransport();
      final coordinator = RemoteInputWorkspaceCoordinator(
        platform: platform,
        transportFactory: (_) async => transport,
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
      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.accept,
          sessionId: offer.sessionId,
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
      expect(coordinator.snapshot.status, RemoteInputWorkspaceStatus.armed);

      transport.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        calls.where((call) => call.method == 'stopCapture'),
        isNotEmpty,
      );
      expect(coordinator.snapshot.role, RemoteInputWorkspaceRole.idle);
      expect(coordinator.snapshot.status, RemoteInputWorkspaceStatus.idle);
    });

    test('releases capture when the active target transport closes', () async {
      final transports = <String, _ObservableFakeRemoteInputTransport>{};
      final coordinator = RemoteInputWorkspaceCoordinator(
        platform: platform,
        transportFactory: (uri) async {
          final transport = _ObservableFakeRemoteInputTransport();
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
      calls.clear();
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
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.snapshot.activePeerId, 'peer-c');

      transports['peer-c.local']!.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        calls.map((call) => call.method),
        containsAllInOrder(['stopCapture', 'startCapture']),
      );
      expect(coordinator.snapshot.activePeerId, isEmpty);
      expect(
        coordinator.snapshot.connectedTargetPeerIds,
        unorderedEquals(['peer-b']),
      );
      expect(coordinator.snapshot.status, RemoteInputWorkspaceStatus.armed);
    });

    test('peer disconnect removes the active target and keeps others armed',
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
      calls.clear();
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
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.snapshot.activePeerId, 'peer-c');

      await coordinator.handlePeerDisconnected('peer-c');

      expect(
        calls.map((call) => call.method),
        containsAllInOrder(['stopCapture', 'startCapture']),
      );
      expect(coordinator.snapshot.activePeerId, isEmpty);
      expect(
        coordinator.snapshot.connectedTargetPeerIds,
        unorderedEquals(['peer-b']),
      );
      expect(coordinator.snapshot.status, RemoteInputWorkspaceStatus.armed);
    });

    test('peer disconnect returns to idle when it was the last target',
        () async {
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
      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.accept,
          sessionId: offer.sessionId,
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
      expect(coordinator.snapshot.status, RemoteInputWorkspaceStatus.armed);

      await coordinator.handlePeerDisconnected('peer-b');

      expect(coordinator.snapshot.role, RemoteInputWorkspaceRole.idle);
      expect(coordinator.snapshot.status, RemoteInputWorkspaceStatus.idle);
      expect(coordinator.snapshot.liveTargetPeerIds, isEmpty);
      expect(
        calls.where((call) => call.method == 'stopCapture'),
        isNotEmpty,
      );
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

class _ObservableFakeRemoteInputTransport
    implements
        RemoteInputPacketTransport,
        RemoteInputObservablePacketTransport {
  final sentPackets = <RemoteInputPacketFrame>[];
  final _doneController = StreamController<void>.broadcast();
  bool closed = false;

  @override
  Stream<void> get done => _doneController.stream;

  void complete() {
    _doneController.add(null);
  }

  @override
  void send(RemoteInputPacketFrame packet) {
    if (!closed) {
      sentPackets.add(packet);
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    await _doneController.close();
  }
}
