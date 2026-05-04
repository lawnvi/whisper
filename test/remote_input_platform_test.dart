import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
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
      );

      expect(calls.single.method, 'startCapture');
      expect(calls.single.arguments['sessionId'], 'input-1');
      expect(calls.single.arguments['edge'], 'right');
      expect(calls.single.arguments['releaseHotkey'], 'ctrl+alt+esc');
    });

    test('pauses capture without stopping the native capture session',
        () async {
      await platform.pauseCapture(sessionId: 'input-1');

      expect(calls.single.method, 'pauseCapture');
      expect(calls.single.arguments['sessionId'], 'input-1');
    });

    test('starts injection and injects events', () async {
      final event = RemoteInputPacketFrame(
        sessionId: 'input-1',
        sequence: 1,
        timestampMicros: 2,
        eventType: RemoteInputEventType.key,
        payload: Uint8List.fromList(<int>[42]),
      );

      await platform.startInjection(sessionId: 'input-1');
      await platform.injectEvent(event);
      await platform.stopInjection(sessionId: 'input-1');

      expect(
        calls.map((call) => call.method),
        <String>['startInjection', 'injectEvent', 'stopInjection'],
      );
      expect(calls[1].arguments['eventType'], 'key');
      expect(calls[1].arguments['payload'], Uint8List.fromList(<int>[42]));
    });

    test('emits native input events and release callbacks', () async {
      final events = <RemoteInputPacketFrame>[];
      final releases = <PlatformRemoteInputRelease>[];
      final eventSubscription = platform.inputEvents.listen(events.add);
      final releaseSubscription = platform.releases.listen(releases.add);

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
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events.single.eventType, RemoteInputEventType.mouseMove);
      expect(events.single.payload, <int>[1, 2]);
      expect(releases.single.reason, 'hotkey');

      await eventSubscription.cancel();
      await releaseSubscription.cancel();
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
