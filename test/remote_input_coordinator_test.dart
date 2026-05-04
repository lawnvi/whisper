import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
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
