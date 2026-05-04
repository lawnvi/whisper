import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RemoteInputCoordinator', () {
    late MethodChannel channel;
    late List<MethodCall> calls;
    late RemoteInputPlatform platform;

    setUp(() {
      channel = const MethodChannel('test_remote_input_coordinator');
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

    test('source arms capture after a trusted capable offer is accepted',
        () async {
      final transport = _FakeRemoteInputTransport();
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (uri) async {
          expect(uri.toString(), 'ws://win.local:10002/input');
          return transport;
        },
      );

      await coordinator.startSharingToConnectedPeer(
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        sinkHost: 'win.local',
        sinkPort: 10002,
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
        isMutuallyTrusted: true,
        remoteCanInject: true,
        sendControl: sentControls.add,
      );

      final offer = sentControls.single;
      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.accept,
          sessionId: offer.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'win',
          layoutEdge: RemoteInputEdge.right,
          releaseHotkey: 'ctrl+alt+esc',
        ),
        localPeerId: 'mac',
        remoteHost: 'win.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      expect(coordinator.state.status, RemoteInputRuntimeStatus.armed);
      expect(calls.map((call) => call.method), contains('startCapture'));

      await platform.handleNativeMethodCall(
        MethodCall('onInputEvent', <String, dynamic>{
          'sessionId': offer.sessionId,
          'sequence': 1,
          'timestampMicros': 2,
          'eventType': 'mouseMove',
          'payload': Uint8List.fromList(<int>[1, 2]),
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.state.status, RemoteInputRuntimeStatus.active);
      expect(transport.sentPackets.single.eventType,
          RemoteInputEventType.mouseMove);
    });

    test('source sends a stop control when native capture hotkey is released',
        () async {
      final transport = _FakeRemoteInputTransport();
      final sentControls = <RemoteInputControlMessage>[];
      final coordinator = RemoteInputCoordinator(
        manager: RemoteInputManager(),
        platform: platform,
        transportFactory: (_) async => transport,
      );

      await coordinator.startSharingToConnectedPeer(
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        sinkHost: 'win.local',
        sinkPort: 10002,
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
        isMutuallyTrusted: true,
        remoteCanInject: true,
        sendControl: sentControls.add,
      );

      final offer = sentControls.single;
      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.accept,
          sessionId: offer.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'win',
          layoutEdge: RemoteInputEdge.right,
          releaseHotkey: 'ctrl+alt+esc',
        ),
        localPeerId: 'mac',
        remoteHost: 'win.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      await platform.handleNativeMethodCall(
        MethodCall('onRelease', <String, dynamic>{
          'sessionId': offer.sessionId,
          'reason': 'hotkey',
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(sentControls, hasLength(2));
      expect(sentControls.last.action, RemoteInputControlAction.stop);
      expect(sentControls.last.sessionId, offer.sessionId);
      expect(coordinator.state.status, RemoteInputRuntimeStatus.idle);
    });

    test('source pauses capture when peer releases back across the edge',
        () async {
      final transport = _FakeRemoteInputTransport();
      final sentControls = <RemoteInputControlMessage>[];
      final coordinator = RemoteInputCoordinator(
        manager: RemoteInputManager(),
        platform: platform,
        transportFactory: (_) async => transport,
      );

      await coordinator.startSharingToConnectedPeer(
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        sinkHost: 'win.local',
        sinkPort: 10002,
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
        isMutuallyTrusted: true,
        remoteCanInject: true,
        sendControl: sentControls.add,
      );

      final offer = sentControls.single;
      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.accept,
          sessionId: offer.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'win',
          layoutEdge: RemoteInputEdge.right,
          releaseHotkey: 'ctrl+alt+esc',
        ),
        localPeerId: 'mac',
        remoteHost: 'win.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      await platform.handleNativeMethodCall(
        MethodCall('onInputEvent', <String, dynamic>{
          'sessionId': offer.sessionId,
          'sequence': 1,
          'timestampMicros': 2,
          'eventType': 'mouseMove',
          'payload': Uint8List.fromList(
            '{"activeStart":true}'.codeUnits,
          ),
        }),
      );
      await platform.handleNativeMethodCall(
        MethodCall('onInputEvent', <String, dynamic>{
          'sessionId': offer.sessionId,
          'sequence': 2,
          'timestampMicros': 3,
          'eventType': 'mouseMove',
          'payload': Uint8List.fromList(
            '{"activeStart":false}'.codeUnits,
          ),
        }),
      );
      await Future<void>.delayed(Duration.zero);

      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.release,
          sessionId: offer.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'win',
          releaseReason: 'edge',
          releaseSequence: 1,
          releaseActivationSequence: 1,
        ),
        localPeerId: 'mac',
        remoteHost: 'win.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      final pauseCall =
          calls.lastWhere((call) => call.method == 'pauseCapture');
      expect(pauseCall.arguments['releaseSequence'], 1);
      expect(pauseCall.arguments['releaseActivationSequence'], 1);
      expect(coordinator.state.status, RemoteInputRuntimeStatus.armed);
      expect(coordinator.state.role, RemoteInputRuntimeRole.source);
      expect(transport.closed, isFalse);
    });

    test('source ignores a stale edge release after newer input reactivates',
        () async {
      final transport = _FakeRemoteInputTransport();
      final sentControls = <RemoteInputControlMessage>[];
      final coordinator = RemoteInputCoordinator(
        manager: RemoteInputManager(),
        platform: platform,
        transportFactory: (_) async => transport,
      );

      await coordinator.startSharingToConnectedPeer(
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        sinkHost: 'win.local',
        sinkPort: 10002,
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
        isMutuallyTrusted: true,
        remoteCanInject: true,
        sendControl: sentControls.add,
      );

      final offer = sentControls.single;
      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.accept,
          sessionId: offer.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'win',
          layoutEdge: RemoteInputEdge.right,
          releaseHotkey: 'ctrl+alt+esc',
        ),
        localPeerId: 'mac',
        remoteHost: 'win.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      await platform.handleNativeMethodCall(
        MethodCall('onInputEvent', <String, dynamic>{
          'sessionId': offer.sessionId,
          'sequence': 1,
          'timestampMicros': 2,
          'eventType': 'mouseMove',
          'payload': Uint8List.fromList(
            '{"activeStart":true}'.codeUnits,
          ),
        }),
      );
      await Future<void>.delayed(Duration.zero);

      await platform.handleNativeMethodCall(
        MethodCall('onInputEvent', <String, dynamic>{
          'sessionId': offer.sessionId,
          'sequence': 2,
          'timestampMicros': 3,
          'eventType': 'mouseMove',
          'payload': Uint8List.fromList(
            '{"activeStart":true}'.codeUnits,
          ),
        }),
      );
      await Future<void>.delayed(Duration.zero);

      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.release,
          sessionId: offer.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'win',
          releaseReason: 'edge',
          releaseSequence: 3,
          releaseActivationSequence: 1,
        ),
        localPeerId: 'mac',
        remoteHost: 'win.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      expect(calls.map((call) => call.method), isNot(contains('pauseCapture')));
      expect(coordinator.state.status, RemoteInputRuntimeStatus.active);
      expect(
          transport.sentPackets.map((packet) => packet.sequence), <int>[1, 2]);
    });

    test('does not offer remote input to untrusted peers', () async {
      final sentControls = <RemoteInputControlMessage>[];
      final coordinator = RemoteInputCoordinator(
        manager: RemoteInputManager(),
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
      );

      await coordinator.startSharingToConnectedPeer(
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        sinkHost: 'win.local',
        sinkPort: 10002,
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
        isMutuallyTrusted: false,
        remoteCanInject: true,
        sendControl: sentControls.add,
      );

      expect(sentControls, isEmpty);
      expect(coordinator.state.status, RemoteInputRuntimeStatus.failed);
    });

    test('sink auto-accepts trusted capable offers and injects packets',
        () async {
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
      );
      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-1',
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
      );

      await coordinator.handleControlMessage(
        offer,
        localPeerId: 'win',
        remoteHost: 'mac.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      expect(sentControls.single.action, RemoteInputControlAction.accept);
      expect(calls.map((call) => call.method), contains('startInjection'));

      manager.handlePacketBytes(
        RemoteInputPacketFrame(
          sessionId: 'input-1',
          sequence: 1,
          timestampMicros: 2,
          eventType: RemoteInputEventType.key,
          payload: Uint8List.fromList(<int>[42]),
        ).encode(),
      );
      await Future<void>.delayed(Duration.zero);

      expect(calls.map((call) => call.method), contains('injectEvent'));
    });

    test('sink translates key payloads before native injection', () async {
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
        keyTranslatorFactory: (platformKind) => RemoteInputKeyTranslator(
          targetPlatform: RemoteInputPlatformKind.macos,
        ),
      );
      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-key-translate-1',
        sourcePeerId: 'win',
        sinkPeerId: 'mac',
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
      );

      await coordinator.handleControlMessage(
        offer,
        localPeerId: 'mac',
        remoteHost: 'win.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      manager.handlePacketBytes(
        RemoteInputPacketFrame(
          sessionId: 'input-key-translate-1',
          sequence: 1,
          timestampMicros: 2,
          eventType: RemoteInputEventType.key,
          payload: Uint8List.fromList(utf8.encode(jsonEncode(<String, dynamic>{
            'sourcePlatform': 'windows',
            'keyCode': 0x11,
            'windowsKeyCode': 0x11,
            'macKeyCode': 59,
            'down': true,
          }))),
        ).encode(),
      );
      await Future<void>.delayed(Duration.zero);

      final injectCall =
          calls.lastWhere((call) => call.method == 'injectEvent');
      final args = injectCall.arguments as Map<Object?, Object?>;
      final payload = jsonDecode(
        utf8.decode(args['payload'] as Uint8List),
      ) as Map<String, dynamic>;

      expect(payload['keyCode'], 59);
      expect(payload['macKeyCode'], 59);
      expect(payload['modifierSemantic'], 'control');
    });

    test('sink serializes key injections to preserve modifier combos',
        () async {
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
        keyTranslatorFactory: (platformKind) => RemoteInputKeyTranslator(
          targetPlatform: RemoteInputPlatformKind.macos,
        ),
      );
      final injectCalls = <MethodCall>[];
      final firstInjectStarted = Completer<void>();
      final releaseFirstInject = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'injectEvent') {
          injectCalls.add(call);
          if (injectCalls.length == 1) {
            firstInjectStarted.complete();
            await releaseFirstInject.future;
          }
        }
        return null;
      });
      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-key-order-1',
        sourcePeerId: 'win',
        sinkPeerId: 'mac',
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
      );

      await coordinator.handleControlMessage(
        offer,
        localPeerId: 'mac',
        remoteHost: 'win.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      manager.handlePacketBytes(
        _keyFrameBytes(
          sessionId: 'input-key-order-1',
          sequence: 1,
          payload: <String, dynamic>{
            'sourcePlatform': 'windows',
            'keyCode': 0x11,
            'windowsKeyCode': 0x11,
            'down': true,
          },
        ),
      );
      await firstInjectStarted.future;

      manager.handlePacketBytes(
        _keyFrameBytes(
          sessionId: 'input-key-order-1',
          sequence: 2,
          payload: <String, dynamic>{
            'sourcePlatform': 'windows',
            'keyCode': 0x43,
            'windowsKeyCode': 0x43,
            'down': true,
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(injectCalls, hasLength(1));

      releaseFirstInject.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(injectCalls, hasLength(2));
    });

    test('sink sends an edge release control without stopping injection',
        () async {
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
      );
      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-release-1',
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
      );

      await coordinator.handleControlMessage(
        offer,
        localPeerId: 'win',
        remoteHost: 'mac.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      manager.handlePacketBytes(
        RemoteInputPacketFrame(
          sessionId: 'input-release-1',
          sequence: 7,
          timestampMicros: 7,
          eventType: RemoteInputEventType.mouseMove,
          payload: Uint8List.fromList(
            '{"activeStart":true}'.codeUnits,
          ),
        ).encode(),
      );
      manager.handlePacketBytes(
        RemoteInputPacketFrame(
          sessionId: 'input-release-1',
          sequence: 9,
          timestampMicros: 9,
          eventType: RemoteInputEventType.mouseMove,
          payload: Uint8List.fromList(
            '{"activeStart":false,"deltaX":32,"deltaY":0,"edge":"right"}'
                .codeUnits,
          ),
        ).encode(),
      );
      await Future<void>.delayed(Duration.zero);

      await platform.handleNativeMethodCall(
        const MethodCall('onRelease', <String, dynamic>{
          'sessionId': 'input-release-1',
          'reason': 'edge',
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(sentControls, hasLength(2));
      expect(sentControls.first.action, RemoteInputControlAction.accept);
      expect(sentControls.last.action, RemoteInputControlAction.release);
      expect(sentControls.last.releaseReason, 'edge');
      expect(sentControls.last.releaseSequence, 9);
      expect(sentControls.last.releaseActivationSequence, 7);
      expect(coordinator.state.status, RemoteInputRuntimeStatus.active);
      expect(
          calls.map((call) => call.method), isNot(contains('stopInjection')));
    });

    test('sink ignores an edge release immediately after entry activation',
        () async {
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
      );

      final offer = manager.createOffer(
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
      );

      await coordinator.handleControlMessage(
        offer,
        localPeerId: 'win',
        remoteHost: 'mac.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      manager.handlePacketBytes(
        RemoteInputPacketFrame(
          sessionId: offer.sessionId,
          sequence: 7,
          timestampMicros: 7,
          eventType: RemoteInputEventType.mouseMove,
          payload: Uint8List.fromList(
            '{"activeStart":true}'.codeUnits,
          ),
        ).encode(),
      );
      manager.handlePacketBytes(
        RemoteInputPacketFrame(
          sessionId: offer.sessionId,
          sequence: 8,
          timestampMicros: 8,
          eventType: RemoteInputEventType.mouseMove,
          payload: Uint8List.fromList(
            '{"activeStart":false,"deltaX":2,"deltaY":0,"edge":"right"}'
                .codeUnits,
          ),
        ).encode(),
      );
      manager.handlePacketBytes(
        RemoteInputPacketFrame(
          sessionId: offer.sessionId,
          sequence: 9,
          timestampMicros: 9,
          eventType: RemoteInputEventType.mouseMove,
          payload: Uint8List.fromList(
            '{"activeStart":false,"deltaX":1,"deltaY":0,"edge":"right"}'
                .codeUnits,
          ),
        ).encode(),
      );
      manager.handlePacketBytes(
        RemoteInputPacketFrame(
          sessionId: offer.sessionId,
          sequence: 10,
          timestampMicros: 10,
          eventType: RemoteInputEventType.mouseMove,
          payload: Uint8List.fromList(
            '{"activeStart":false,"deltaX":-1,"deltaY":0,"edge":"right"}'
                .codeUnits,
          ),
        ).encode(),
      );
      await Future<void>.delayed(Duration.zero);

      await platform.handleNativeMethodCall(
        MethodCall('onRelease', <String, dynamic>{
          'sessionId': offer.sessionId,
          'reason': 'edge',
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(sentControls, hasLength(1));
      expect(sentControls.single.action, RemoteInputControlAction.accept);
      expect(coordinator.state.status, RemoteInputRuntimeStatus.active);
      expect(
          calls.map((call) => call.method), isNot(contains('stopInjection')));
    });

    test('sink reports a platform injection failure instead of accepting',
        () async {
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'startInjection') {
          throw PlatformException(
            code: 'remote-input-unavailable',
            message: 'Remote input is not available on this platform',
          );
        }
        return null;
      });

      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-2',
        sourcePeerId: 'mac',
        sinkPeerId: 'linux',
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
      );

      await coordinator.handleControlMessage(
        offer,
        localPeerId: 'linux',
        remoteHost: 'mac.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      expect(sentControls.single.action, RemoteInputControlAction.error);
      expect(sentControls.single.errorMessage,
          'Remote input is not available on this platform');
      expect(coordinator.state.status, RemoteInputRuntimeStatus.failed);
    });
  });
}

Uint8List _keyFrameBytes({
  required String sessionId,
  required int sequence,
  required Map<String, dynamic> payload,
}) {
  return RemoteInputPacketFrame(
    sessionId: sessionId,
    sequence: sequence,
    timestampMicros: sequence,
    eventType: RemoteInputEventType.key,
    payload: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
  ).encode();
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
