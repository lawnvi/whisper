import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_clipboard_transfer.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final mediaKey = Uint8List.fromList(List<int>.generate(32, (index) => index));

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
          expect(uri.path, '/input');
          expect(uri.queryParameters['session'], isNotEmpty);
          expect(uri.queryParameters['token'], 'input-token');
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
          transportToken: 'input-token',
        ),
        localPeerId: 'mac',
        remoteHost: 'win.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        mediaSendKey: mediaKey,
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

    test('source stops capture when packet transport closes unexpectedly',
        () async {
      final transport = _ObservableFakeRemoteInputTransport();
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
      expect(coordinator.state.status, RemoteInputRuntimeStatus.armed);

      transport.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        calls.where((call) => call.method == 'stopCapture'),
        isNotEmpty,
      );
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
          releaseEdgeUnit: 0.5,
          sourceDisplayId: 'source-left',
          sourceEdge: RemoteInputEdge.left,
          sourceSegmentStart: 200,
          sourceSegmentEnd: 800,
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
      expect(pauseCall.arguments['releaseEdgeUnit'], 0.5);
      expect(pauseCall.arguments['displayId'], 'source-left');
      expect(pauseCall.arguments['edge'], 'left');
      expect(pauseCall.arguments['segmentStart'], 200);
      expect(pauseCall.arguments['segmentEnd'], 800);
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

    test('remote input errors are reduced to a stable local reason', () async {
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
        isMutuallyTrusted: true,
        remoteCanInject: true,
        sendControl: sentControls.add,
      );
      final offer = sentControls.single;
      const remoteText =
          'remote token=never-store-this /Users/alice/private.txt';

      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.error,
          sessionId: offer.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'win',
          errorMessage: remoteText,
        ),
        localPeerId: 'mac',
        remoteHost: 'win.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      expect(coordinator.state.status, RemoteInputRuntimeStatus.failed);
      expect(coordinator.state.errorMessage, 'remoteFailure');
      expect(coordinator.state.errorMessage, isNot(contains(remoteText)));
    });

    test('remote input errors preserve an allowlisted wire reason', () async {
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
        isMutuallyTrusted: true,
        remoteCanInject: true,
        sendControl: sentControls.add,
      );
      final offer = sentControls.single;

      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.error,
          sessionId: offer.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'win',
          errorMessage: 'permission',
        ),
        localPeerId: 'mac',
        remoteHost: 'win.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      expect(coordinator.state.errorMessage, 'permission');
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

    test('sink waits for remote clipboard files before injecting paste',
        () async {
      final manager = RemoteInputManager();
      final pasteReady = Completer<RemoteClipboardPasteResult>();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        platformKindProvider: () => RemoteInputPlatformKind.windows,
        remoteClipboardPastePreparer: ({required peerId, required sessionId}) {
          expect(peerId, 'mac');
          expect(sessionId, 'clipboard-paste');
          return pasteReady.future;
        },
      );
      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'clipboard-paste',
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
        remoteClipboardV1: true,
      );
      await coordinator.handleControlMessage(
        offer,
        localPeerId: 'win',
        remoteHost: 'mac.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: (_) {},
      );

      await _deliverPacket(
        manager,
        _keyFrameBytes(
          sessionId: 'clipboard-paste',
          sequence: 1,
          payload: <String, dynamic>{
            'sourcePlatform': 'windows',
            'windowsKeyCode': 0x11,
            'keyCode': 0x11,
            'modifierSemantic': 'control',
            'down': true,
          },
        ),
      );
      final pasteDelivery = _deliverPacket(
        manager,
        _keyFrameBytes(
          sessionId: 'clipboard-paste',
          sequence: 2,
          payload: <String, dynamic>{
            'sourcePlatform': 'windows',
            'windowsKeyCode': 0x56,
            'keyCode': 0x56,
            'keySemantic': 'keyV',
            'down': true,
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'injectEvent'), hasLength(1));

      pasteReady.complete(RemoteClipboardPasteResult.prepared);
      await pasteDelivery;
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'injectEvent'), hasLength(2));
    });

    test('sink coalesces queued mouse move packets before injection', () async {
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final firstInjectCompleter = Completer<void>();
      var blockNextInject = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'injectEvent' && blockNextInject) {
          blockNextInject = false;
          await firstInjectCompleter.future;
        }
        return null;
      });
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
      );
      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-coalesce-1',
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

      manager.handlePacketBytes(_mouseMoveFrameBytes(
        sessionId: 'input-coalesce-1',
        sequence: 1,
        payload: <String, dynamic>{
          'activeStart': false,
          'deltaX': 1,
          'deltaY': 2,
          'edge': 'right',
        },
      ));
      await Future<void>.delayed(Duration.zero);

      for (var sequence = 2; sequence <= 6; sequence++) {
        manager.handlePacketBytes(_mouseMoveFrameBytes(
          sessionId: 'input-coalesce-1',
          sequence: sequence,
          payload: <String, dynamic>{
            'activeStart': false,
            'deltaX': 1,
            'deltaY': 2,
            'edge': 'right',
          },
        ));
      }
      await Future<void>.delayed(Duration.zero);
      firstInjectCompleter.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final injectCalls =
          calls.where((call) => call.method == 'injectEvent').toList();
      expect(injectCalls, hasLength(2));
      final coalescedArgs = injectCalls.last.arguments as Map<Object?, Object?>;
      expect(coalescedArgs['eventType'], 'mouseMove');
      final coalescedPayload = jsonDecode(
        utf8.decode(coalescedArgs['payload'] as Uint8List),
      ) as Map<String, dynamic>;
      expect(coalescedPayload['deltaX'], 5);
      expect(coalescedPayload['deltaY'], 10);
    });

    test('sink safely coalesces adjacent normalized wheel packets', () async {
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final firstInjectStarted = Completer<void>();
      final releaseFirstInject = Completer<void>();
      addTearDown(() {
        if (!releaseFirstInject.isCompleted) {
          releaseFirstInject.complete();
        }
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'injectEvent' && !firstInjectStarted.isCompleted) {
          firstInjectStarted.complete();
          await releaseFirstInject.future;
        }
        return null;
      });
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
        platformKindProvider: () => RemoteInputPlatformKind.macos,
        scrollMultiplierProvider: () async => 1,
      );
      addTearDown(coordinator.stopLocal);
      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-wheel-coalesce-1',
        sourcePeerId: 'win',
        sinkPeerId: 'mac',
        layoutEdge: RemoteInputEdge.right,
        sourcePlatform: 'windows',
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
      final firstDelivery = _deliverPacket(
        manager,
        _eventFrameBytes(
          sessionId: offer.sessionId,
          sequence: 1,
          eventType: RemoteInputEventType.release,
          payload: const <String, dynamic>{},
        ),
      );
      await firstInjectStarted.future;
      final firstWheel = _deliverPacket(
        manager,
        _eventFrameBytes(
          sessionId: offer.sessionId,
          sequence: 2,
          eventType: RemoteInputEventType.mouseWheel,
          payload: const <String, dynamic>{
            'sourcePlatform': 'windows',
            'deltaX': 0,
            'deltaY': 120,
          },
        ),
      );
      final secondWheel = _deliverPacket(
        manager,
        _eventFrameBytes(
          sessionId: offer.sessionId,
          sequence: 3,
          eventType: RemoteInputEventType.mouseWheel,
          payload: const <String, dynamic>{
            'sourcePlatform': 'windows',
            'deltaX': 0,
            'deltaY': 120,
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.debugPendingInjectionItems, 2);
      releaseFirstInject.complete();
      await Future.wait(<Future<void>>[
        firstDelivery,
        firstWheel,
        secondWheel,
      ]);

      final injectCalls =
          calls.where((call) => call.method == 'injectEvent').toList();
      expect(injectCalls, hasLength(2));
      final wheelArguments =
          injectCalls.last.arguments as Map<Object?, Object?>;
      expect(wheelArguments['eventType'], 'mouseWheel');
      expect(wheelArguments['sequence'], 3);
      final payload = jsonDecode(
        utf8.decode(wheelArguments['payload'] as Uint8List),
      ) as Map<String, dynamic>;
      expect(payload['scrollDeltaY'], 2);
      expect(payload['deltaY'], 2);
      expect(payload['targetScrollUnit'], 'wheel');
    });

    test('sink normalizes legacy wheel packets before injection', () async {
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
        platformKindProvider: () => RemoteInputPlatformKind.macos,
        scrollMultiplierProvider: () async => 2,
      );
      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-wheel-normalize-1',
        sourcePeerId: 'win',
        sinkPeerId: 'mac',
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
        sourcePlatform: 'windows',
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
          sessionId: 'input-wheel-normalize-1',
          sequence: 1,
          timestampMicros: 2,
          eventType: RemoteInputEventType.mouseWheel,
          payload: Uint8List.fromList(
            utf8.encode(jsonEncode(<String, dynamic>{
              'deltaX': 0,
              'deltaY': 120,
            })),
          ),
        ).encode(),
      );
      await Future<void>.delayed(Duration.zero);

      final injectCall =
          calls.lastWhere((call) => call.method == 'injectEvent');
      final args = injectCall.arguments as Map<Object?, Object?>;
      final payload = jsonDecode(
        utf8.decode(args['payload'] as Uint8List),
      ) as Map<String, dynamic>;

      expect(payload['scrollUnit'], 'wheel');
      expect(payload['scrollDeltaY'], 1);
      expect(payload['deltaY'], 2);
      expect(payload['targetScrollUnit'], 'wheel');
    });

    test('rejects a competing offer while a local session is live', () async {
      final transport = _FakeRemoteInputTransport();
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => transport,
      );

      await coordinator.startSharingToConnectedPeer(
        sourcePeerId: 'linux',
        sinkPeerId: 'win',
        sinkHost: 'win.local',
        sinkPort: 10002,
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
        isMutuallyTrusted: true,
        remoteCanInject: true,
        sendControl: sentControls.add,
      );

      final originalOffer = sentControls.single;
      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.accept,
          sessionId: originalOffer.sessionId,
          sourcePeerId: 'linux',
          sinkPeerId: 'win',
          layoutEdge: RemoteInputEdge.right,
          releaseHotkey: 'ctrl+alt+esc',
        ),
        localPeerId: 'linux',
        remoteHost: 'win.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      await coordinator.handleControlMessage(
        const RemoteInputControlMessage(
          action: RemoteInputControlAction.offer,
          sessionId: 'reverse-offer-1',
          sourcePeerId: 'win',
          sinkPeerId: 'linux',
          layoutEdge: RemoteInputEdge.left,
          releaseHotkey: 'ctrl+alt+esc',
        ),
        localPeerId: 'linux',
        remoteHost: 'win.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      expect(sentControls, hasLength(2));
      expect(sentControls.last.action, RemoteInputControlAction.reject);
      expect(sentControls.last.sessionId, 'reverse-offer-1');
      expect(coordinator.state.sessionId, originalOffer.sessionId);
      expect(coordinator.state.role, RemoteInputRuntimeRole.source);
      expect(coordinator.state.status, RemoteInputRuntimeStatus.armed);
      expect(
          calls.map((call) => call.method), isNot(contains('startInjection')));
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

    test('sink preserves every queued key button and release in order',
        () async {
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
        platformKindProvider: () => RemoteInputPlatformKind.windows,
      );
      final firstInjectStarted = Completer<void>();
      final releaseFirstInject = Completer<void>();
      addTearDown(() async {
        if (!releaseFirstInject.isCompleted) {
          releaseFirstInject.complete();
        }
        await coordinator.stopLocal();
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'injectEvent' && !firstInjectStarted.isCompleted) {
          firstInjectStarted.complete();
          await releaseFirstInject.future;
        }
        return null;
      });
      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-semantic-order-1',
        sourcePeerId: 'win-source',
        sinkPeerId: 'win-sink',
        layoutEdge: RemoteInputEdge.right,
        sourcePlatform: 'windows',
      );
      await coordinator.handleControlMessage(
        offer,
        localPeerId: 'win-sink',
        remoteHost: 'win-source.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );

      const packetCount = 200;
      final expectedTypes = <RemoteInputEventType>[];
      final deliveries = <Future<void>>[];
      for (var sequence = 1; sequence <= packetCount; sequence++) {
        final eventType = switch (sequence % 3) {
          1 => RemoteInputEventType.key,
          2 => RemoteInputEventType.mouseButton,
          _ => RemoteInputEventType.release,
        };
        expectedTypes.add(eventType);
        deliveries.add(_deliverPacket(
          manager,
          _eventFrameBytes(
            sessionId: offer.sessionId,
            sequence: sequence,
            eventType: eventType,
            payload: switch (eventType) {
              RemoteInputEventType.key => <String, dynamic>{
                  'sourcePlatform': 'windows',
                  'windowsKeyCode': 0x41,
                  'keyCode': 0x41,
                  'down': sequence.isOdd,
                },
              RemoteInputEventType.mouseButton => <String, dynamic>{
                  'button': 1,
                  'down': sequence.isOdd,
                },
              _ => const <String, dynamic>{},
            },
          ),
        ));
        if (sequence == 1) {
          await firstInjectStarted.future;
        }
      }
      expect(coordinator.debugPendingInjectionItems, packetCount);

      releaseFirstInject.complete();
      await Future.wait(deliveries).timeout(const Duration(seconds: 2));

      final injected =
          calls.where((call) => call.method == 'injectEvent').toList();
      expect(injected, hasLength(packetCount));
      expect(
        injected.map((call) => call.arguments['sequence']),
        List<int>.generate(packetCount, (index) => index + 1),
      );
      expect(
        injected.map((call) => call.arguments['eventType']),
        expectedTypes.map((eventType) => eventType.name),
      );
    });

    test('sink fails closed when slow native injection exhausts hard bounds',
        () async {
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
      );
      final firstInjectStarted = Completer<void>();
      final releaseFirstInject = Completer<void>();
      var stopInjectionCount = 0;
      addTearDown(() async {
        if (!releaseFirstInject.isCompleted) {
          releaseFirstInject.complete();
        }
        await coordinator.stopLocal();
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'injectEvent' && !firstInjectStarted.isCompleted) {
          firstInjectStarted.complete();
          await releaseFirstInject.future;
        }
        if (call.method == 'stopInjection') {
          stopInjectionCount++;
        }
        return null;
      });
      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-overflow-1',
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
      manager.handlePacketBytes(_eventFrameBytes(
        sessionId: offer.sessionId,
        sequence: 1,
        eventType: RemoteInputEventType.release,
        payload: const <String, dynamic>{},
      ));
      await firstInjectStarted.future;

      const semanticTypes = <RemoteInputEventType>[
        RemoteInputEventType.key,
        RemoteInputEventType.mouseButton,
        RemoteInputEventType.release,
        RemoteInputEventType.modifiers,
        RemoteInputEventType.mouseMove,
        RemoteInputEventType.mouseWheel,
      ];
      var maxPendingItems = coordinator.debugPendingInjectionItems;
      var maxPendingBytes = coordinator.debugPendingInjectionBytes;
      for (var sequence = 2; sequence <= 3000; sequence++) {
        final eventType = semanticTypes[(sequence - 2) % semanticTypes.length];
        manager.handlePacketBytes(_eventFrameBytes(
          sessionId: offer.sessionId,
          sequence: sequence,
          eventType: eventType,
          payload: switch (eventType) {
            RemoteInputEventType.key => <String, dynamic>{
                'sourcePlatform': 'windows',
                'windowsKeyCode': 0x41,
                'keyCode': 0x41,
                'down': sequence.isEven,
              },
            RemoteInputEventType.mouseButton => <String, dynamic>{
                'button': 1,
                'down': sequence.isEven,
              },
            RemoteInputEventType.mouseMove => const <String, dynamic>{
                'activeStart': false,
                'deltaX': 1,
                'deltaY': 1,
                'edge': 'right',
              },
            RemoteInputEventType.mouseWheel => const <String, dynamic>{
                'sourcePlatform': 'windows',
                'deltaX': 0,
                'deltaY': 120,
              },
            RemoteInputEventType.modifiers ||
            RemoteInputEventType.release =>
              const <String, dynamic>{},
          },
        ));
        if (coordinator.debugPendingInjectionItems > maxPendingItems) {
          maxPendingItems = coordinator.debugPendingInjectionItems;
        }
        if (coordinator.debugPendingInjectionBytes > maxPendingBytes) {
          maxPendingBytes = coordinator.debugPendingInjectionBytes;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        manager.session(offer.sessionId)?.state,
        RemoteInputSessionState.stopped,
      );
      expect(stopInjectionCount, 1);
      expect(
        maxPendingItems,
        lessThanOrEqualTo(RemoteInputCoordinator.maxPendingInjectionItems),
      );
      expect(
        maxPendingBytes,
        lessThanOrEqualTo(RemoteInputCoordinator.maxPendingInjectionBytes),
      );
      expect(coordinator.debugPendingInjectionItems, 0);
      expect(coordinator.debugPendingInjectionBytes, 0);
      expect(
        sentControls.where(
            (control) => control.action == RemoteInputControlAction.error),
        hasLength(1),
      );
      expect(manager.onPacket, isNull);

      releaseFirstInject.complete();
      await Future<void>.delayed(Duration.zero);
      calls.clear();
      const replacementOffer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-overflow-2',
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
      );
      await coordinator.handleControlMessage(
        replacementOffer,
        localPeerId: 'win',
        remoteHost: 'mac.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: sentControls.add,
      );
      final replacementHandled = manager.handlePacketBytes(_eventFrameBytes(
        sessionId: replacementOffer.sessionId,
        sequence: 1,
        eventType: RemoteInputEventType.release,
        payload: const <String, dynamic>{},
      ));
      if (replacementHandled is Future<void>) {
        await replacementHandled;
      }

      expect(
        calls.where((call) {
          if (call.method != 'injectEvent') {
            return false;
          }
          final arguments = call.arguments as Map<Object?, Object?>;
          return arguments['sessionId'] == replacementOffer.sessionId;
        }),
        hasLength(1),
      );
      expect(
        manager.session(replacementOffer.sessionId)?.state,
        RemoteInputSessionState.connected,
      );
    });

    test('sink enforces its byte bound before the item bound', () async {
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
      );
      final firstInjectStarted = Completer<void>();
      final releaseFirstInject = Completer<void>();
      var stopInjectionCount = 0;
      addTearDown(() async {
        if (!releaseFirstInject.isCompleted) {
          releaseFirstInject.complete();
        }
        await coordinator.stopLocal();
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'injectEvent' && !firstInjectStarted.isCompleted) {
          firstInjectStarted.complete();
          await releaseFirstInject.future;
        }
        if (call.method == 'stopInjection') {
          stopInjectionCount++;
        }
        return null;
      });
      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-byte-overflow-1',
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        layoutEdge: RemoteInputEdge.right,
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
      manager.handlePacketBytes(_eventFrameBytes(
        sessionId: offer.sessionId,
        sequence: 1,
        eventType: RemoteInputEventType.release,
        payload: const <String, dynamic>{},
      ));
      await firstInjectStarted.future;

      var maxPendingItems = coordinator.debugPendingInjectionItems;
      var maxPendingBytes = coordinator.debugPendingInjectionBytes;
      for (var sequence = 2; sequence <= 40; sequence++) {
        manager.handlePacketBytes(
          RemoteInputPacketFrame(
            sessionId: offer.sessionId,
            sequence: sequence,
            timestampMicros: sequence,
            eventType: RemoteInputEventType.release,
            payload: Uint8List(60 * 1024),
          ).encode(),
        );
        if (coordinator.debugPendingInjectionItems > maxPendingItems) {
          maxPendingItems = coordinator.debugPendingInjectionItems;
        }
        if (coordinator.debugPendingInjectionBytes > maxPendingBytes) {
          maxPendingBytes = coordinator.debugPendingInjectionBytes;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        maxPendingItems,
        lessThan(RemoteInputCoordinator.maxPendingInjectionItems),
      );
      expect(
        maxPendingBytes,
        lessThanOrEqualTo(RemoteInputCoordinator.maxPendingInjectionBytes),
      );
      expect(
        manager.session(offer.sessionId)?.state,
        RemoteInputSessionState.stopped,
      );
      expect(stopInjectionCount, 1);
      expect(
        sentControls.where(
            (control) => control.action == RemoteInputControlAction.error),
        hasLength(1),
      );
    });

    test('sink times out a permanently blocked native injection', () async {
      final sentControls = <RemoteInputControlMessage>[];
      final manager = RemoteInputManager();
      final coordinator = RemoteInputCoordinator(
        manager: manager,
        platform: platform,
        transportFactory: (_) async => _FakeRemoteInputTransport(),
        nativeInjectionTimeout: const Duration(milliseconds: 20),
      );
      final blockedInjection = Completer<void>();
      var stopInjectionCount = 0;
      addTearDown(() async {
        if (!blockedInjection.isCompleted) {
          blockedInjection.complete();
        }
        await coordinator.stopLocal();
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'injectEvent') {
          await blockedInjection.future;
        }
        if (call.method == 'stopInjection') {
          stopInjectionCount++;
        }
        return null;
      });
      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-timeout-1',
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        layoutEdge: RemoteInputEdge.right,
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

      await _deliverPacket(
        manager,
        _eventFrameBytes(
          sessionId: offer.sessionId,
          sequence: 1,
          eventType: RemoteInputEventType.release,
          payload: const <String, dynamic>{},
        ),
      ).timeout(const Duration(milliseconds: 200));
      await Future<void>.delayed(Duration.zero);

      expect(
        manager.session(offer.sessionId)?.state,
        RemoteInputSessionState.stopped,
      );
      expect(stopInjectionCount, 1);
      expect(
        sentControls.where(
            (control) => control.action == RemoteInputControlAction.error),
        hasLength(1),
      );
      expect(coordinator.debugPendingInjectionItems, 0);
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

    test('sink routes active entry to the matching remote display segment',
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
        layoutEdge: RemoteInputEdge.top,
        releaseHotkey: 'ctrl+alt+esc',
        sourceDisplayId: 'source-main',
        sourceEdge: RemoteInputEdge.top,
        sourceSegmentStart: 0,
        sourceSegmentEnd: 2000,
        sinkDisplayId: 'sink-left',
        sinkEdge: RemoteInputEdge.bottom,
        sinkSegmentStart: 0,
        sinkSegmentEnd: 1000,
        edgeMappings: const [
          RemoteInputEdgeMapping(
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.top,
            sourceSegmentStart: 0,
            sourceSegmentEnd: 1000,
            sinkDisplayId: 'sink-left',
            sinkEdge: RemoteInputEdge.bottom,
            sinkSegmentStart: 0,
            sinkSegmentEnd: 1000,
          ),
          RemoteInputEdgeMapping(
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.top,
            sourceSegmentStart: 1000,
            sourceSegmentEnd: 2000,
            sinkDisplayId: 'sink-right',
            sinkEdge: RemoteInputEdge.bottom,
            sinkSegmentStart: 1000,
            sinkSegmentEnd: 2000,
          ),
        ],
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

      manager.handlePacketBytes(_mouseMoveFrameBytes(
        sessionId: offer.sessionId,
        sequence: 7,
        payload: const {
          'activeStart': true,
          'edge': 'top',
          'edgeUnit': 0.75,
          'deltaX': 0,
          'deltaY': 0,
        },
      ));
      manager.handlePacketBytes(_mouseMoveFrameBytes(
        sessionId: offer.sessionId,
        sequence: 8,
        payload: const {
          'activeStart': false,
          'edge': 'top',
          'deltaX': 0,
          'deltaY': -20,
        },
      ));
      await Future<void>.delayed(Duration.zero);

      final payloads =
          calls.where((call) => call.method == 'injectEvent').map((call) {
        return jsonDecode(
          utf8.decode(call.arguments['payload'] as Uint8List),
        ) as Map<String, dynamic>;
      }).toList();
      final payload = payloads.firstWhere(
        (payload) => payload['activeStart'] == true,
      );
      expect(payload['sinkDisplayId'], 'sink-right');
      expect(payload['sinkEdge'], 'bottom');
      expect(payload['sinkSegmentStart'], 1000);
      expect(payload['sinkSegmentEnd'], 2000);
      expect(payload['edgeUnit'], closeTo(0.5, 0.001));

      await platform.handleNativeMethodCall(
        MethodCall('onRelease', <String, dynamic>{
          'sessionId': offer.sessionId,
          'reason': 'edge',
          'edgeUnit': 0.625,
          'sourceEdgeUnit': true,
          'sourceDisplayId': 'source-main',
          'sourceEdge': 'left',
          'sourceSegmentStart': 200,
          'sourceSegmentEnd': 800,
          'routeId': 'route-left',
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(sentControls, hasLength(2));
      expect(sentControls.last.action, RemoteInputControlAction.release);
      expect(sentControls.last.releaseEdgeUnit, closeTo(0.625, 0.001));
      expect(sentControls.last.sourceDisplayId, 'source-main');
      expect(sentControls.last.sourceEdge, RemoteInputEdge.left);
      expect(sentControls.last.sourceSegmentStart, 200);
      expect(sentControls.last.sourceSegmentEnd, 800);
      expect(sentControls.last.routeId, 'route-left');
    });

    test('sink routes active entry by route id at shared segment endpoints',
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
        layoutEdge: RemoteInputEdge.top,
        releaseHotkey: 'ctrl+alt+esc',
        sourceDisplayId: 'source-main',
        sourceEdge: RemoteInputEdge.top,
        sourceSegmentStart: 0,
        sourceSegmentEnd: 2000,
        sinkDisplayId: 'sink-left',
        sinkEdge: RemoteInputEdge.bottom,
        sinkSegmentStart: 0,
        sinkSegmentEnd: 1000,
        edgeMappings: const [
          RemoteInputEdgeMapping(
            routeId: 'route-left',
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.top,
            sourceSegmentStart: 0,
            sourceSegmentEnd: 1000,
            sinkDisplayId: 'sink-left',
            sinkEdge: RemoteInputEdge.bottom,
            sinkSegmentStart: 0,
            sinkSegmentEnd: 1000,
          ),
          RemoteInputEdgeMapping(
            routeId: 'route-right',
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.top,
            sourceSegmentStart: 1000,
            sourceSegmentEnd: 2000,
            sinkDisplayId: 'sink-right',
            sinkEdge: RemoteInputEdge.bottom,
            sinkSegmentStart: 1000,
            sinkSegmentEnd: 2000,
          ),
        ],
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

      manager.handlePacketBytes(_mouseMoveFrameBytes(
        sessionId: offer.sessionId,
        sequence: 7,
        payload: const {
          'activeStart': true,
          'edge': 'top',
          'x': 1000,
          'edgeUnit': 0,
          'routeId': 'route-right',
          'deltaX': 0,
          'deltaY': 0,
        },
      ));
      await Future<void>.delayed(Duration.zero);

      final payload =
          calls.where((call) => call.method == 'injectEvent').map((call) {
        return jsonDecode(
          utf8.decode(call.arguments['payload'] as Uint8List),
        ) as Map<String, dynamic>;
      }).firstWhere((payload) => payload['activeStart'] == true);

      expect(payload['routeId'], 'route-right');
      expect(payload['sinkDisplayId'], 'sink-right');
      expect(payload['sinkEdge'], 'bottom');
      expect(payload['sinkSegmentStart'], 1000);
      expect(payload['sinkSegmentEnd'], 2000);
      expect(payload['edgeUnit'], 0);
    });

    test('sink falls back to source coordinate when route id is unknown',
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
        layoutEdge: RemoteInputEdge.top,
        releaseHotkey: 'ctrl+alt+esc',
        sourceDisplayId: 'source-main',
        sourceEdge: RemoteInputEdge.top,
        sourceSegmentStart: 0,
        sourceSegmentEnd: 2000,
        sinkDisplayId: 'sink-left',
        sinkEdge: RemoteInputEdge.bottom,
        sinkSegmentStart: 0,
        sinkSegmentEnd: 1000,
        edgeMappings: const [
          RemoteInputEdgeMapping(
            routeId: 'route-left',
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.top,
            sourceSegmentStart: 0,
            sourceSegmentEnd: 1000,
            sinkDisplayId: 'sink-left',
            sinkEdge: RemoteInputEdge.bottom,
            sinkSegmentStart: 0,
            sinkSegmentEnd: 1000,
          ),
          RemoteInputEdgeMapping(
            routeId: 'route-right',
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.top,
            sourceSegmentStart: 1000,
            sourceSegmentEnd: 2000,
            sinkDisplayId: 'sink-right',
            sinkEdge: RemoteInputEdge.bottom,
            sinkSegmentStart: 1000,
            sinkSegmentEnd: 2000,
          ),
        ],
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

      manager.handlePacketBytes(_mouseMoveFrameBytes(
        sessionId: offer.sessionId,
        sequence: 7,
        payload: const {
          'activeStart': true,
          'edge': 'top',
          'x': 1500,
          'edgeUnit': 0.25,
          'routeId': 'stale-route',
          'deltaX': 0,
          'deltaY': 0,
        },
      ));
      await Future<void>.delayed(Duration.zero);

      final payload =
          calls.where((call) => call.method == 'injectEvent').map((call) {
        return jsonDecode(
          utf8.decode(call.arguments['payload'] as Uint8List),
        ) as Map<String, dynamic>;
      }).firstWhere((payload) => payload['activeStart'] == true);

      expect(payload['routeId'], 'route-right');
      expect(payload['sinkDisplayId'], 'sink-right');
      expect(payload['sinkEdge'], 'bottom');
      expect(payload['edgeUnit'], closeTo(0.5, 0.001));
    });

    test('sink preserves route-local edge unit for routed active entry',
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
        layoutEdge: RemoteInputEdge.top,
        releaseHotkey: 'ctrl+alt+esc',
        sourceDisplayId: 'source-main',
        sourceEdge: RemoteInputEdge.top,
        sourceSegmentStart: 0,
        sourceSegmentEnd: 2000,
        sinkDisplayId: 'sink-right',
        sinkEdge: RemoteInputEdge.bottom,
        sinkSegmentStart: 1000,
        sinkSegmentEnd: 2000,
        edgeMappings: const [
          RemoteInputEdgeMapping(
            routeId: 'route-right',
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.top,
            sourceSegmentStart: 1000,
            sourceSegmentEnd: 2000,
            sinkDisplayId: 'sink-right',
            sinkEdge: RemoteInputEdge.bottom,
            sinkSegmentStart: 1000,
            sinkSegmentEnd: 2000,
          ),
        ],
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

      manager.handlePacketBytes(_mouseMoveFrameBytes(
        sessionId: offer.sessionId,
        sequence: 7,
        payload: const {
          'activeStart': true,
          'edge': 'top',
          'x': 1900,
          'edgeUnit': 0.25,
          'routeId': 'route-right',
          'deltaX': 0,
          'deltaY': 0,
        },
      ));
      await Future<void>.delayed(Duration.zero);

      final payload =
          calls.where((call) => call.method == 'injectEvent').map((call) {
        return jsonDecode(
          utf8.decode(call.arguments['payload'] as Uint8List),
        ) as Map<String, dynamic>;
      }).firstWhere((payload) => payload['activeStart'] == true);

      expect(payload['routeId'], 'route-right');
      expect(payload['edgeUnit'], 0.25);
    });

    test('sink routes active entry using the packet source edge', () async {
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
        layoutEdge: RemoteInputEdge.top,
        releaseHotkey: 'ctrl+alt+esc',
        sourceDisplayId: 'source-main',
        sourceEdge: RemoteInputEdge.top,
        sourceSegmentStart: 800,
        sourceSegmentEnd: 1600,
        sinkDisplayId: 'sink-top',
        sinkEdge: RemoteInputEdge.bottom,
        sinkSegmentStart: 1000,
        sinkSegmentEnd: 1600,
        edgeMappings: const [
          RemoteInputEdgeMapping(
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.top,
            sourceSegmentStart: 1000,
            sourceSegmentEnd: 1600,
            sinkDisplayId: 'sink-top',
            sinkEdge: RemoteInputEdge.bottom,
            sinkSegmentStart: 1000,
            sinkSegmentEnd: 1600,
          ),
          RemoteInputEdgeMapping(
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.left,
            sourceSegmentStart: 800,
            sourceSegmentEnd: 1200,
            sinkDisplayId: 'sink-left',
            sinkEdge: RemoteInputEdge.right,
            sinkSegmentStart: 400,
            sinkSegmentEnd: 800,
          ),
        ],
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

      manager.handlePacketBytes(_mouseMoveFrameBytes(
        sessionId: offer.sessionId,
        sequence: 7,
        payload: const {
          'activeStart': true,
          'edge': 'left',
          'edgeUnit': 0.5,
          'x': 1000,
          'y': 1000,
          'deltaX': -12,
          'deltaY': 0,
        },
      ));
      await Future<void>.delayed(Duration.zero);

      final payload =
          calls.where((call) => call.method == 'injectEvent').map((call) {
        return jsonDecode(
          utf8.decode(call.arguments['payload'] as Uint8List),
        ) as Map<String, dynamic>;
      }).firstWhere((payload) => payload['activeStart'] == true);

      expect(payload['sinkDisplayId'], 'sink-left');
      expect(payload['sinkEdge'], 'right');
      expect(payload['sinkSegmentStart'], 400);
      expect(payload['sinkSegmentEnd'], 800);
      expect(payload['edgeUnit'], closeTo(0.5, 0.001));
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
      expect(sentControls.single.errorMessage, 'unsupported');
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

Uint8List _eventFrameBytes({
  required String sessionId,
  required int sequence,
  required RemoteInputEventType eventType,
  required Map<String, dynamic> payload,
}) {
  return RemoteInputPacketFrame(
    sessionId: sessionId,
    sequence: sequence,
    timestampMicros: sequence,
    eventType: eventType,
    payload: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
  ).encode();
}

Future<void> _deliverPacket(
  RemoteInputManager manager,
  Uint8List bytes,
) async {
  await manager.handlePacketBytes(bytes);
}

Uint8List _mouseMoveFrameBytes({
  required String sessionId,
  required int sequence,
  required Map<String, dynamic> payload,
}) {
  return RemoteInputPacketFrame(
    sessionId: sessionId,
    sequence: sequence,
    timestampMicros: sequence,
    eventType: RemoteInputEventType.mouseMove,
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
