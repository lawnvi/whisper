import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RemoteInputPlatform', () {
    late MethodChannel channel;
    late List<MethodCall> calls;
    late RemoteInputPlatform platform;

    setUp(() {
      channel = const MethodChannel('test_remote_input');
      calls = <MethodCall>[];
      platform = RemoteInputPlatform(channel: channel);
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

    test('starts capture with session edge and release hotkey', () async {
      await platform.startCapture(
        sessionId: 'input-1',
        edge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
        displayId: 'source-main',
        segmentStart: 260,
        segmentEnd: 900,
        edgeMappings: const [
          RemoteInputEdgeMapping(
            routeId: 'route-left',
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.right,
            sourceSegmentStart: 260,
            sourceSegmentEnd: 580,
            sinkDisplayId: 'sink-left',
            sinkEdge: RemoteInputEdge.left,
            sinkSegmentStart: 0,
            sinkSegmentEnd: 320,
          ),
          RemoteInputEdgeMapping(
            routeId: 'route-right',
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.right,
            sourceSegmentStart: 580,
            sourceSegmentEnd: 900,
            sinkDisplayId: 'sink-right',
            sinkEdge: RemoteInputEdge.left,
            sinkSegmentStart: 0,
            sinkSegmentEnd: 320,
          ),
        ],
      );

      expect(calls.single.method, 'startCapture');
      expect(calls.single.arguments['sessionId'], 'input-1');
      expect(calls.single.arguments['edge'], 'right');
      expect(calls.single.arguments['releaseHotkey'], 'ctrl+alt+esc');
      expect(calls.single.arguments['displayId'], 'source-main');
      expect(calls.single.arguments['segmentStart'], 260);
      expect(calls.single.arguments['segmentEnd'], 900);
      expect(calls.single.arguments['segments'], [
        {
          'displayId': 'source-main',
          'edge': 'right',
          'start': 260,
          'end': 580,
          'routeId': 'route-left',
        },
        {
          'displayId': 'source-main',
          'edge': 'right',
          'start': 580,
          'end': 900,
          'routeId': 'route-right',
        },
      ]);
    });

    test('pauses capture without stopping the native capture session',
        () async {
      await platform.pauseCapture(
        sessionId: 'input-1',
        releaseSequence: 7,
        releaseActivationSequence: 3,
        releaseEdgeUnit: 0.625,
      );

      expect(calls.single.method, 'pauseCapture');
      expect(calls.single.arguments['sessionId'], 'input-1');
      expect(calls.single.arguments['releaseSequence'], 7);
      expect(calls.single.arguments['releaseActivationSequence'], 3);
      expect(calls.single.arguments['releaseEdgeUnit'], 0.625);
    });

    test('pauses capture with the release source route override', () async {
      await platform.pauseCapture(
        sessionId: 'input-1',
        releaseEdgeUnit: 0.625,
        displayId: 'source-left',
        edge: RemoteInputEdge.left,
        segmentStart: 200,
        segmentEnd: 800,
        routeId: 'route-left',
      );

      expect(calls.single.method, 'pauseCapture');
      expect(calls.single.arguments['sessionId'], 'input-1');
      expect(calls.single.arguments['releaseEdgeUnit'], 0.625);
      expect(calls.single.arguments['displayId'], 'source-left');
      expect(calls.single.arguments['edge'], 'left');
      expect(calls.single.arguments['segmentStart'], 200);
      expect(calls.single.arguments['segmentEnd'], 800);
      expect(calls.single.arguments['routeId'], 'route-left');
    });

    test('keeps zero release edge unit for segment-start returns', () async {
      await platform.pauseCapture(
        sessionId: 'input-1',
        releaseEdgeUnit: 0,
      );

      expect(calls.single.method, 'pauseCapture');
      expect(calls.single.arguments['releaseEdgeUnit'], 0);
    });

    test('starts injection and injects events', () async {
      final event = RemoteInputPacketFrame(
        sessionId: 'input-1',
        sequence: 1,
        timestampMicros: 2,
        eventType: RemoteInputEventType.key,
        payload: Uint8List.fromList(<int>[42]),
      );

      await platform.startInjection(
        sessionId: 'input-1',
        displayId: 'sink-main',
        edge: RemoteInputEdge.left,
        segmentStart: 0,
        segmentEnd: 640,
        edgeMappings: const [
          RemoteInputEdgeMapping(
            routeId: 'route-left',
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.right,
            sourceSegmentStart: 0,
            sourceSegmentEnd: 640,
            sinkDisplayId: 'sink-main',
            sinkEdge: RemoteInputEdge.left,
            sinkSegmentStart: 0,
            sinkSegmentEnd: 640,
          ),
        ],
      );
      await platform.injectEvent(event);
      await platform.stopInjection(sessionId: 'input-1');

      expect(
        calls.map((call) => call.method),
        <String>['startInjection', 'injectEvent', 'stopInjection'],
      );
      expect(calls[0].arguments['displayId'], 'sink-main');
      expect(calls[0].arguments['edge'], 'left');
      expect(calls[0].arguments['segmentStart'], 0);
      expect(calls[0].arguments['segmentEnd'], 640);
      expect((calls[0].arguments['mappings'] as List).single['routeId'],
          'route-left');
      expect(calls[1].arguments['eventType'], 'key');
      expect(calls[1].arguments['payload'], Uint8List.fromList(<int>[42]));
    });

    test('loads display topology from native method channel', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'getDisplayTopology') {
          return <String, dynamic>{
            'platform': 'macos',
            'updatedAt': 1234,
            'displays': <Map<String, dynamic>>[
              <String, dynamic>{
                'displayId': 'source-main',
                'name': 'Built-in',
                'x': 0,
                'y': 0,
                'width': 1440,
                'height': 900,
                'scale': 2.0,
                'isPrimary': true,
              },
            ],
          };
        }
        return null;
      });

      final topology = await platform.displayTopology();

      expect(calls.single.method, 'getDisplayTopology');
      expect(topology.platform, 'macos');
      expect(topology.primaryDisplay.displayId, 'source-main');
    });

    test('emits native input events and release callbacks', () async {
      final events = <RemoteInputPacketFrame>[];
      final releases = <PlatformRemoteInputRelease>[];
      final diagnostics = <PlatformRemoteInputDiagnostic>[];
      final eventSubscription = platform.inputEvents.listen(events.add);
      final releaseSubscription = platform.releases.listen(releases.add);
      final diagnosticSubscription =
          platform.diagnostics.listen(diagnostics.add);

      await platform.handleNativeMethodCall(
        MethodCall('onInputEvent', <String, dynamic>{
          'sessionId': 'input-1',
          'sequence': 1,
          'timestampMicros': 2,
          'eventType': 'mouseMove',
          'payload': Uint8List.fromList(<int>[1, 2]),
        }),
      );
      await platform.handleNativeMethodCall(
        const MethodCall('onRelease', <String, dynamic>{
          'sessionId': 'input-1',
          'reason': 'hotkey',
          'sequence': 7,
          'activationSequence': 3,
          'edgeUnit': 0.625,
          'sourceEdgeUnit': true,
          'sourceDisplayId': 'source-left',
          'sourceEdge': 'left',
          'sourceSegmentStart': 200,
          'sourceSegmentEnd': 800,
          'routeId': 'route-left',
        }),
      );
      await platform.handleNativeMethodCall(
        const MethodCall('onDiagnostic', <String, dynamic>{
          'sessionId': 'input-1',
          'message': 'keyboard hook active',
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events.single.eventType, RemoteInputEventType.mouseMove);
      expect(events.single.payload, <int>[1, 2]);
      expect(releases.single.reason, 'hotkey');
      expect(releases.single.sequence, 7);
      expect(releases.single.activationSequence, 3);
      expect(releases.single.edgeUnit, 0.625);
      expect((releases.single as dynamic).sourceEdgeUnit, isTrue);
      expect(releases.single.sourceDisplayId, 'source-left');
      expect(releases.single.sourceEdge, RemoteInputEdge.left);
      expect(releases.single.sourceSegmentStart, 200);
      expect(releases.single.sourceSegmentEnd, 800);
      expect(releases.single.routeId, 'route-left');
      expect(diagnostics.single.message, 'keyboard hook active');

      await eventSubscription.cancel();
      await releaseSubscription.cancel();
      await diagnosticSubscription.cancel();
    });
  });

  group('RemoteInputPacketByteTransport', () {
    test('encodes packets before sending bytes', () {
      final sentBytes = <Uint8List>[];
      final transport = RemoteInputPacketByteTransport(
        sendBytes: sentBytes.add,
      );
      final packet = RemoteInputPacketFrame(
        sessionId: 'input-1',
        sequence: 1,
        timestampMicros: 2,
        eventType: RemoteInputEventType.release,
        payload: Uint8List(0),
      );

      transport.send(packet);

      expect(
          RemoteInputPacketFrame.decode(sentBytes.single).sessionId, 'input-1');
    });
  });
}
