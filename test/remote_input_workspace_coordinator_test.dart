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
import 'package:whisper/remote_input/remote_input_workspace_graph.dart';

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

    test(
      'keeps multiple accepted targets and routes input by routeId',
      () async {
        final coordinator = RemoteInputWorkspaceCoordinator(
          platform: platform,
          transportFactory: (uri) async {
            expect(uri.queryParameters['session'], isNotEmpty);
            expect(
              uri.queryParameters['token'],
              startsWith('workspace-token-'),
            );
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
        expect(offerB.remoteClipboardV1, isTrue);
        expect(offerC.remoteClipboardV1, isTrue);
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
        expect(
          coordinator.snapshot.connectedTargetPeerIds,
          unorderedEquals(['peer-b', 'peer-c']),
        );
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
              utf8.encode(
                jsonEncode(<String, dynamic>{
                  'activeStart': true,
                  'routeId': 'workspace-1|peer-c|route-c',
                  'deltaX': 8,
                  'deltaY': 0,
                }),
              ),
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
        expect(
          transports['peer-c.local']!.sentPackets.first.sessionId,
          offerC.sessionId,
        );
        expect(coordinator.snapshot.activePeerId, 'peer-c');
      },
    );

    test('hands input from one controlled peer to another', () async {
      final coordinator = RemoteInputWorkspaceCoordinator(
        platform: platform,
        transportFactory: (uri) async {
          final transport = _FakeRemoteInputTransport();
          transports[uri.host] = transport;
          return transport;
        },
        workspaceSessionIdFactory: () => 'workspace-graph',
      );
      final aToB = _workspaceRoute(
        routeId: 'a-to-b',
        sourcePeerId: 'mac',
        sinkPeerId: 'peer-b',
        sourceEdge: RemoteInputEdge.right,
        sinkEdge: RemoteInputEdge.left,
      );
      final bToA = _workspaceRoute(
        routeId: 'b-to-a',
        sourcePeerId: 'peer-b',
        sinkPeerId: 'mac',
        sourceEdge: RemoteInputEdge.left,
        sinkEdge: RemoteInputEdge.right,
      );
      final bToC = _workspaceRoute(
        routeId: 'b-to-c',
        sourcePeerId: 'peer-b',
        sinkPeerId: 'peer-c',
        sourceEdge: RemoteInputEdge.right,
        sinkEdge: RemoteInputEdge.left,
      );
      final cToB = _workspaceRoute(
        routeId: 'c-to-b',
        sourcePeerId: 'peer-c',
        sinkPeerId: 'peer-b',
        sourceEdge: RemoteInputEdge.left,
        sinkEdge: RemoteInputEdge.right,
      );

      await coordinator.startControllerWorkspace(
        sourcePeerId: 'mac',
        targets: <RemoteInputWorkspaceTargetRequest>[
          _targetRequest(
            peerId: 'peer-b',
            host: 'peer-b.local',
            routeId: aToB.routeId,
            start: 0,
            end: 100,
          ).copyWithMappings(
            capture: <RemoteInputEdgeMapping>[aToB.mapping],
            injection: <RemoteInputEdgeMapping>[aToB.mapping, cToB.mapping],
          ),
          _targetRequest(
            peerId: 'peer-c',
            host: 'peer-c.local',
            routeId: bToC.routeId,
            start: 0,
            end: 100,
          ).copyWithMappings(
            capture: const <RemoteInputEdgeMapping>[],
            injection: <RemoteInputEdgeMapping>[bToC.mapping],
          ),
        ],
        workspaceRoutes: <RemoteInputWorkspaceRoute>[aToB, bToA, bToC, cToB],
        sendControlTo: (peerId, control) {
          sentControls.putIfAbsent(peerId, () => []).add(control);
        },
      );
      for (final peerId in <String>['peer-b', 'peer-c']) {
        final offer = sentControls[peerId]!.single;
        await coordinator.handleControlMessage(
          RemoteInputControlMessage(
            action: RemoteInputControlAction.accept,
            sessionId: offer.sessionId,
            sourcePeerId: 'mac',
            sinkPeerId: peerId,
            transportToken: 'token-$peerId',
          ),
          localPeerId: 'mac',
          remoteHost: '$peerId.local',
          remotePort: 10002,
          mediaSendKey: mediaKey,
          sendControlTo: (peerId, control) {},
        );
      }

      await platform.handleNativeMethodCall(
        MethodCall('onInputEvent', <String, dynamic>{
          'sessionId': 'workspace-graph',
          'sequence': 10,
          'timestampMicros': 10,
          'eventType': 'mouseMove',
          'payload': Uint8List.fromList(
            utf8.encode(
              jsonEncode(<String, dynamic>{
                'activeStart': true,
                'routeId': 'workspace-graph|peer-b|a-to-b',
                'deltaX': 1,
                'deltaY': 0,
              }),
            ),
          ),
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.snapshot.activePeerId, 'peer-b');

      await platform.handleNativeMethodCall(
        MethodCall('onInputEvent', <String, dynamic>{
          'sessionId': 'workspace-graph',
          'sequence': 11,
          'timestampMicros': 11,
          'eventType': 'key',
          'payload': Uint8List.fromList(
            utf8.encode(
              jsonEncode(<String, dynamic>{
                'down': true,
                'modifierSemantic': 'control',
                'keyCode': 59,
              }),
            ),
          ),
        }),
      );
      await Future<void>.delayed(Duration.zero);

      final offerB = sentControls['peer-b']!.single;
      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.release,
          sessionId: offerB.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'peer-b',
          releaseReason: 'edge',
          releaseSequence: 2,
          releaseActivationSequence: 1,
          releaseEdgeUnit: 0.4,
          routeId: 'workspace-graph|peer-b|c-to-b',
        ),
        localPeerId: 'mac',
        remoteHost: 'peer-b.local',
        remotePort: 10002,
        sendControlTo: (peerId, control) {},
      );

      expect(coordinator.snapshot.activePeerId, 'peer-c');
      final packets = transports['peer-c.local']!.sentPackets;
      expect(packets, hasLength(2));
      final activation = packets.first;
      final payload = jsonDecode(utf8.decode(activation.payload)) as Map;
      expect(payload['activeStart'], isTrue);
      expect(payload['routeId'], 'workspace-graph|peer-c|b-to-c');
      expect(payload['edgeUnit'], 0.4);
      expect(
        jsonDecode(utf8.decode(packets.last.payload))['modifierSemantic'],
        'control',
      );
      expect(packets.last.sequence, greaterThan(activation.sequence));
      expect(calls.where((call) => call.method == 'pauseCapture'), isEmpty);
    });

    test(
      'disconnects an unreachable branch and restores it after auth',
      () async {
        final coordinator = RemoteInputWorkspaceCoordinator(
          platform: platform,
          transportFactory: (uri) async {
            final transport = _FakeRemoteInputTransport();
            transports[uri.host] = transport;
            return transport;
          },
          workspaceSessionIdFactory: () => 'workspace-reconnect',
        );
        final routes = <RemoteInputWorkspaceRoute>[
          _workspaceRoute(
            routeId: 'a-to-b',
            sourcePeerId: 'mac',
            sinkPeerId: 'peer-b',
            sourceEdge: RemoteInputEdge.right,
            sinkEdge: RemoteInputEdge.left,
          ),
          _workspaceRoute(
            routeId: 'b-to-a',
            sourcePeerId: 'peer-b',
            sinkPeerId: 'mac',
            sourceEdge: RemoteInputEdge.left,
            sinkEdge: RemoteInputEdge.right,
          ),
          _workspaceRoute(
            routeId: 'b-to-c',
            sourcePeerId: 'peer-b',
            sinkPeerId: 'peer-c',
            sourceEdge: RemoteInputEdge.right,
            sinkEdge: RemoteInputEdge.left,
          ),
          _workspaceRoute(
            routeId: 'c-to-b',
            sourcePeerId: 'peer-c',
            sinkPeerId: 'peer-b',
            sourceEdge: RemoteInputEdge.left,
            sinkEdge: RemoteInputEdge.right,
          ),
        ];
        final targets = <RemoteInputWorkspaceTargetRequest>[
          _targetRequest(
            peerId: 'peer-b',
            host: 'peer-b.local',
            routeId: 'a-to-b',
            start: 0,
            end: 100,
          ).copyWithMappings(
            capture: <RemoteInputEdgeMapping>[routes[0].mapping],
            injection: <RemoteInputEdgeMapping>[
              routes[0].mapping,
              routes[3].mapping,
            ],
          ),
          _targetRequest(
            peerId: 'peer-c',
            host: 'peer-c.local',
            routeId: 'b-to-c',
            start: 0,
            end: 100,
          ).copyWithMappings(
            capture: const <RemoteInputEdgeMapping>[],
            injection: <RemoteInputEdgeMapping>[routes[2].mapping],
          ),
        ];
        await coordinator.startControllerWorkspace(
          sourcePeerId: 'mac',
          targets: targets,
          workspaceRoutes: routes,
          sendControlTo: (peerId, control) {
            sentControls.putIfAbsent(peerId, () => []).add(control);
          },
        );
        for (final peerId in <String>['peer-b', 'peer-c']) {
          final offer = sentControls[peerId]!.single;
          await coordinator.handleControlMessage(
            RemoteInputControlMessage(
              action: RemoteInputControlAction.accept,
              sessionId: offer.sessionId,
              sourcePeerId: 'mac',
              sinkPeerId: peerId,
              transportToken: 'token-$peerId',
            ),
            localPeerId: 'mac',
            remoteHost: '$peerId.local',
            remotePort: 10002,
            mediaSendKey: mediaKey,
            sendControlTo: (peerId, control) {
              sentControls.putIfAbsent(peerId, () => []).add(control);
            },
          );
        }

        await coordinator.handlePeerDisconnected('peer-b');

        expect(coordinator.snapshot.isControllerLive, isTrue);
        expect(coordinator.snapshot.connectedTargetPeerIds, isEmpty);
        expect(
          sentControls['peer-c']!.map((message) => message.action),
          contains(RemoteInputControlAction.stop),
        );

        await coordinator.handlePeerReconnected(
          peerId: 'peer-b',
          host: 'peer-b-new.local',
          port: 10002,
          isMutuallyTrusted: true,
          remoteCanInject: true,
          sendControlTo: (peerId, control) {
            sentControls.putIfAbsent(peerId, () => []).add(control);
          },
        );

        expect(
          sentControls['peer-b']!.where(
            (message) => message.action == RemoteInputControlAction.offer,
          ),
          hasLength(2),
        );
        expect(
          sentControls['peer-c']!.where(
            (message) => message.action == RemoteInputControlAction.offer,
          ),
          hasLength(2),
        );
        expect(
          coordinator.snapshot.status,
          RemoteInputWorkspaceStatus.offering,
        );
      },
    );

    test(
      'release from one target pauses capture without stopping others',
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

        await platform.handleNativeMethodCall(
          MethodCall('onInputEvent', <String, dynamic>{
            'sessionId': 'workspace-1',
            'sequence': 41,
            'timestampMicros': 1,
            'eventType': 'mouseMove',
            'payload': Uint8List.fromList(
              utf8.encode(
                jsonEncode(<String, dynamic>{
                  'activeStart': true,
                  'routeId': 'workspace-1|peer-c|route-c',
                  'deltaX': 1,
                  'deltaY': 0,
                }),
              ),
            ),
          }),
        );
        await Future<void>.delayed(Duration.zero);
        calls.clear();

        await coordinator.handleControlMessage(
          RemoteInputControlMessage(
            action: RemoteInputControlAction.release,
            sessionId: sentControls['peer-c']!.single.sessionId,
            sourcePeerId: 'mac',
            sinkPeerId: 'peer-c',
            releaseReason: 'edge',
            releaseSequence: 1,
            releaseActivationSequence: 1,
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
        expect(pauseCapture.arguments['releaseSequence'], 41);
        expect(pauseCapture.arguments['releaseActivationSequence'], 41);
        expect(pauseCapture.arguments, isNot(contains('routeId')));
        expect(pauseCapture.arguments, isNot(contains('displayId')));
        expect(
          coordinator.snapshot.connectedTargetPeerIds,
          unorderedEquals(['peer-b', 'peer-c']),
        );
        expect(coordinator.snapshot.status, RemoteInputWorkspaceStatus.armed);

        await platform.handleNativeMethodCall(
          MethodCall('onInputEvent', <String, dynamic>{
            'sessionId': 'workspace-1',
            'sequence': 42,
            'timestampMicros': 2,
            'eventType': 'mouseMove',
            'payload': Uint8List.fromList(
              utf8.encode(
                jsonEncode(<String, dynamic>{
                  'activeStart': true,
                  'routeId': 'workspace-1|peer-b|route-b',
                  'deltaX': 1,
                  'deltaY': 0,
                }),
              ),
            ),
          }),
        );
        await Future<void>.delayed(Duration.zero);
        calls.clear();
        final handledStaleRelease = await coordinator.handleControlMessage(
          RemoteInputControlMessage(
            action: RemoteInputControlAction.release,
            sessionId: sentControls['peer-c']!.single.sessionId,
            sourcePeerId: 'mac',
            sinkPeerId: 'peer-c',
            releaseReason: 'edge',
            releaseSequence: 1,
            releaseActivationSequence: 1,
          ),
          localPeerId: 'mac',
          remoteHost: 'peer-c.local',
          remotePort: 10002,
          sendControlTo: (peerId, control) {},
        );

        expect(handledStaleRelease, isFalse);
        expect(coordinator.snapshot.activePeerId, 'peer-b');
        expect(calls.where((call) => call.method == 'pauseCapture'), isEmpty);
      },
    );

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
        sentControls['peer-d']!.last.action,
        RemoteInputControlAction.reject,
      );
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

    test(
      'workspace drops remote error text before publishing failure',
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
      },
    );

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

    test(
      'stops capture when the only target packet transport closes',
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

        expect(calls.where((call) => call.method == 'stopCapture'), isNotEmpty);
        expect(coordinator.snapshot.role, RemoteInputWorkspaceRole.idle);
        expect(coordinator.snapshot.status, RemoteInputWorkspaceStatus.idle);
      },
    );

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
            utf8.encode(
              jsonEncode(<String, dynamic>{
                'activeStart': true,
                'routeId': 'workspace-1|peer-c|route-c',
                'deltaX': 8,
                'deltaY': 0,
              }),
            ),
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

    test(
      'peer disconnect removes the active target and keeps others armed',
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
              utf8.encode(
                jsonEncode(<String, dynamic>{
                  'activeStart': true,
                  'routeId': 'workspace-1|peer-c|route-c',
                  'deltaX': 8,
                  'deltaY': 0,
                }),
              ),
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
      },
    );

    test(
      'peer disconnect returns to idle when it was the last target',
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
        expect(calls.where((call) => call.method == 'stopCapture'), isNotEmpty);
      },
    );
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

RemoteInputWorkspaceRoute _workspaceRoute({
  required String routeId,
  required String sourcePeerId,
  required String sinkPeerId,
  required RemoteInputEdge sourceEdge,
  required RemoteInputEdge sinkEdge,
}) {
  return RemoteInputWorkspaceRoute(
    routeId: routeId,
    sourcePeerId: sourcePeerId,
    sinkPeerId: sinkPeerId,
    mapping: RemoteInputEdgeMapping(
      routeId: routeId,
      sourceDisplayId: '$sourcePeerId-main',
      sourceEdge: sourceEdge,
      sourceSegmentStart: 0,
      sourceSegmentEnd: 100,
      sinkDisplayId: '$sinkPeerId-main',
      sinkEdge: sinkEdge,
      sinkSegmentStart: 0,
      sinkSegmentEnd: 100,
    ),
  );
}

extension on RemoteInputWorkspaceTargetRequest {
  RemoteInputWorkspaceTargetRequest copyWithMappings({
    required List<RemoteInputEdgeMapping> capture,
    required List<RemoteInputEdgeMapping> injection,
  }) {
    return RemoteInputWorkspaceTargetRequest(
      peerId: peerId,
      peerName: peerName,
      host: host,
      port: port,
      layoutEdge: layoutEdge,
      releaseHotkey: releaseHotkey,
      isMutuallyTrusted: isMutuallyTrusted,
      remoteCanInject: remoteCanInject,
      path: path,
      sourceDisplayId: sourceDisplayId,
      sourceEdge: sourceEdge,
      sourceSegmentStart: sourceSegmentStart,
      sourceSegmentEnd: sourceSegmentEnd,
      sinkDisplayId: sinkDisplayId,
      sinkEdge: sinkEdge,
      sinkSegmentStart: sinkSegmentStart,
      sinkSegmentEnd: sinkSegmentEnd,
      edgeMappings: capture,
      injectionMappings: injection,
    );
  }
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
