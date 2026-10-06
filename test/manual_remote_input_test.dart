import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_lifecycle.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/state/peer_profile.dart';

class _Transport implements RemoteInputPacketTransport {
  final packets = <RemoteInputPacketFrame>[];
  void Function(RemoteInputPacketFrame)? onSend;
  @override
  void send(RemoteInputPacketFrame packet) {
    packets.add(packet);
    onSend?.call(packet);
  }

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'manual mode roundtrips without layout and unknown mode is rejected',
    () {
      final manager = RemoteInputManager();
      final offer = manager.createOffer(
        sourcePeerId: 'phone',
        sinkPeerId: 'mac',
        mode: RemoteInputMode.manual,
        releaseHotkey: '',
      );
      expect(
        RemoteInputControlMessage.fromJson(offer.toJson()).mode,
        RemoteInputMode.manual,
      );
      final accept = manager.acceptOffer(offer).withTransportToken('token');
      expect(
        RemoteInputControlMessage.fromJson(accept.toJson()).mode,
        RemoteInputMode.manual,
      );
      expect(accept.layoutEdge, isNull);
      expect(
        () => RemoteInputControlMessage.fromJson({
          ...offer.toJson(),
          'mode': 'future',
        }),
        throwsFormatException,
      );
    },
  );
  test('manual capabilities are absent for both older protocol versions', () {
    const caps = PeerCapabilities(
      remoteInputManualSourceV1: true,
      remoteInputManualSinkV1: true,
      remoteInputWorkspaceGraphV1: true,
    );
    for (final version in [9, 10]) {
      final json = caps.toWireJson(version);
      expect(json, isNot(contains('remoteInputManualSourceV1')));
      expect(
        PeerCapabilities.fromWireJson(
          json,
          protocolVersion: version,
        ).remoteInputManualSinkV1,
        isFalse,
      );
      expect(
        () => PeerCapabilities.fromWireJson({
          ...json,
          'remoteInputManualSinkV1': true,
        }, protocolVersion: version),
        throwsFormatException,
      );
    }
    expect(
      PeerCapabilities.fromWireJson(
        caps.toWireJson(11),
      ).remoteInputManualSinkV1,
      isTrue,
    );
  });

  late RemoteInputManager manager;
  late RemoteInputCoordinator coordinator;
  late List<MethodCall> calls;
  late List<RemoteInputControlMessage> controls;
  late _Transport transport;
  const channel = MethodChannel('test.manual_input');
  setUp(() {
    calls = [];
    controls = [];
    transport = _Transport();
    manager = RemoteInputManager();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    coordinator = RemoteInputCoordinator(
      manager: manager,
      platform: RemoteInputPlatform(channel: channel),
      transportFactory: (_) async => transport,
      scrollMultiplierProvider: () async => 1,
      platformKindProvider: () => RemoteInputPlatformKind.macos,
    );
  });
  tearDown(() async {
    await coordinator.stopLocal();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  Future<void> control(
    RemoteInputControlMessage message, {
    bool trusted = true,
  }) => coordinator.handleControlMessage(
    message,
    localPeerId: 'mac',
    remoteHost: 'phone',
    remotePort: 10002,
    isMutuallyTrusted: trusted,
    localCanInject: true,
    sendControl: controls.add,
  );
  const offer = RemoteInputControlMessage(
    action: RemoteInputControlAction.offer,
    mode: RemoteInputMode.manual,
    sessionId: 'session',
    sourcePeerId: 'phone',
    sinkPeerId: 'mac',
  );
  Future<void> startSource() async {
    await coordinator.startSharingToConnectedPeer(
      sourcePeerId: 'phone',
      sinkPeerId: 'mac',
      sinkHost: 'mac',
      sinkPort: 10002,
      mode: RemoteInputMode.manual,
      releaseHotkey: '',
      isMutuallyTrusted: true,
      remoteCanInject: true,
      sendControl: controls.add,
    );
    final sent = controls.single;
    await coordinator.handleControlMessage(
      RemoteInputControlMessage(
        action: RemoteInputControlAction.accept,
        mode: RemoteInputMode.manual,
        sessionId: sent.sessionId,
        sourcePeerId: 'phone',
        sinkPeerId: 'mac',
      ),
      localPeerId: 'phone',
      remoteHost: 'mac',
      remotePort: 10002,
      isMutuallyTrusted: true,
      localCanInject: false,
      sendControl: controls.add,
    );
  }

  Future<void> packet(
    int sequence,
    RemoteInputEventType type,
    Map<String, dynamic> payload,
  ) async {
    await manager.handlePacketBytes(
      RemoteInputPacketFrame(
        sessionId: 'session',
        sequence: sequence,
        timestampMicros: sequence,
        eventType: type,
        payload: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      ).encode(),
    );
  }

  testWidgets(
    'manual sender bypasses capture, sends heartbeats and stops cleanly',
    (tester) async {
      await startSource();
      expect(coordinator.state.isActive, isTrue);
      expect(calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 510));
      expect(
        transport.packets
            .where((p) => p.eventType == RemoteInputEventType.heartbeat)
            .length,
        2,
      );
      await coordinator.stopLocal();
      expect(calls, isEmpty);
      await tester.pump(const Duration(seconds: 3));
    },
  );
  testWidgets('sink watchdog releases after startup or loss of valid input', (
    tester,
  ) async {
    await control(offer);
    final arguments = calls.single.arguments as Map;
    expect(arguments['mode'], 'manual');
    expect(arguments, isNot(contains('edge')));
    await tester.pump(const Duration(seconds: 4));
    expect(calls.where((c) => c.method == 'stopInjection'), isEmpty);
    await packet(1, RemoteInputEventType.heartbeat, {});
    await tester.pump(const Duration(milliseconds: 1900));
    expect(calls.where((c) => c.method == 'stopInjection'), isEmpty);
    await tester.pump(const Duration(milliseconds: 101));
    await tester.pump();
    expect(calls.where((c) => c.method == 'stopInjection'), hasLength(1));
    expect(coordinator.state.status, RemoteInputRuntimeStatus.idle);
  });
  testWidgets('silent startup expires without a first heartbeat', (
    tester,
  ) async {
    await control(offer);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(coordinator.state.status, RemoteInputRuntimeStatus.idle);
  });
  test('untrusted manual offers never start injection', () async {
    await control(offer, trusted: false);
    expect(calls, isEmpty);
    expect(controls.single.action, RemoteInputControlAction.reject);
  });
  test(
    'mouse, text, and following key preserve injection order and text replies',
    () async {
      await control(offer);
      await packet(1, RemoteInputEventType.mouseButton, {
        'button': 0,
        'down': true,
      });
      await packet(2, RemoteInputEventType.mouseMove, {
        'deltaX': 2,
        'deltaY': 3,
      });
      await packet(3, RemoteInputEventType.mouseButton, {
        'button': 0,
        'down': false,
      });
      await packet(4, RemoteInputEventType.textCommit, {'text': '中文🙂\nhello'});
      await packet(5, RemoteInputEventType.key, {
        'macKeyCode': 36,
        'down': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        calls
            .where((c) => c.method == 'injectEvent')
            .map((c) => (c.arguments as Map)['eventType']),
        ['mouseButton', 'mouseMove', 'mouseButton', 'textCommit', 'key'],
      );
      final reply = controls.last;
      expect(reply.action, RemoteInputControlAction.textResult);
      expect(reply.textSequence, 4);
      expect(reply.textSucceeded, isTrue);
      await packet(4, RemoteInputEventType.textCommit, {'text': 'duplicate'});
      expect(calls.where((c) => c.method == 'injectEvent'), hasLength(5));
    },
  );
  test('invalid manual movement and oversized text fail validation', () async {
    await control(offer);
    await expectLater(
      packet(1, RemoteInputEventType.mouseMove, {'deltaX': 'bad', 'deltaY': 0}),
      throwsFormatException,
    );
    await expectLater(
      packet(2, RemoteInputEventType.textCommit, {'text': 'x' * 4097}),
      throwsFormatException,
    );
  });
  test(
    'text blocks other input, correlates the reply and has no automatic retry',
    () async {
      await startSource();
      final sent = coordinator.sendManualText('中文');
      final frame = transport.packets.last;
      expect(
        coordinator.sendManualInput(RemoteInputEventType.key, {
          'macKeyCode': 0,
          'down': true,
        }),
        0,
      );
      await coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.textResult,
          mode: RemoteInputMode.manual,
          sessionId: frame.sessionId,
          sourcePeerId: 'phone',
          sinkPeerId: 'mac',
          textSequence: frame.sequence,
          textSucceeded: true,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac',
        remotePort: 1,
        isMutuallyTrusted: true,
        localCanInject: false,
        sendControl: controls.add,
      );
      expect(await sent, isTrue);
      expect(coordinator.isSendingText, isFalse);
      final interrupted = coordinator.sendManualText('not retried');
      await coordinator.stopLocal();
      expect(await interrupted, isFalse);
      expect(
        transport.packets.where(
          (p) => p.eventType == RemoteInputEventType.textCommit,
        ),
        hasLength(2),
      );
    },
  );
  test('manual sessions respect the shared desktop input owner', () async {
    final desktop = manager.lifecycle.createOwner(cleanup: (_) async {});
    await desktop.start();
    await control(offer);
    expect(controls.single.action, RemoteInputControlAction.reject);
    expect(controls.single.mode, RemoteInputMode.manual);
    expect(controls.single.errorMessage, 'busy');
    expect(calls, isEmpty);
    await expectLater(startSource(), throwsA(isA<RemoteInputBusyException>()));
    await desktop.stop();
    controls.clear();
    await control(offer);
    expect(coordinator.state.isActive, isTrue);
    expect(manager.session('session')!.remoteClipboardV1, isFalse);
    await expectLater(
      desktop.start(),
      throwsA(isA<RemoteInputBusyException>()),
    );
  });
  testWidgets(
    'text timeout retains uncertainty, ignores wrong and late replies',
    (tester) async {
      await startSource();
      final pending = coordinator.sendManualText('one attempt');
      final frame = transport.packets.last;
      Future<void> reply(int sequence) => coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.textResult,
          mode: RemoteInputMode.manual,
          sessionId: frame.sessionId,
          sourcePeerId: 'phone',
          sinkPeerId: 'mac',
          textSequence: sequence,
          textSucceeded: true,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac',
        remotePort: 1,
        isMutuallyTrusted: true,
        localCanInject: false,
        sendControl: controls.add,
      );
      await reply(frame.sequence + 1);
      expect(coordinator.isSendingText, isTrue);
      await tester.pump(const Duration(seconds: 5));
      expect(await pending, isFalse);
      await reply(frame.sequence);
      expect(coordinator.isSendingText, isFalse);
      expect(
        transport.packets.where(
          (p) => p.eventType == RemoteInputEventType.textCommit,
        ),
        hasLength(1),
      );
      expect(
        transport.packets
            .where((p) => p.eventType == RemoteInputEventType.heartbeat)
            .length,
        greaterThan(1),
      );
      await coordinator.stopLocal();
    },
  );
  test(
    'native text failure stops input without a successful acknowledgement',
    () async {
      await control(offer);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'injectEvent') {
              throw PlatformException(code: 'text-injection-failed');
            }
            return null;
          });
      await packet(1, RemoteInputEventType.textCommit, {'text': '中文🙂'});
      await pumpEventQueue();
      expect(
        controls.where(
          (c) =>
              c.action == RemoteInputControlAction.textResult &&
              c.textSucceeded,
        ),
        isEmpty,
      );
      final failure = controls.singleWhere(
        (c) => c.action == RemoteInputControlAction.textResult,
      );
      expect(failure.textSequence, 1);
      expect(failure.textSucceeded, isFalse);
      expect(controls.last.action, RemoteInputControlAction.error);
      expect(calls.where((c) => c.method == 'stopInjection'), hasLength(1));
      expect(coordinator.state.isActive, isFalse);
    },
  );
  testWidgets('failure of the first heartbeat cannot leave a running session', (
    tester,
  ) async {
    transport.onSend = (_) => throw StateError('closed transport');
    await startSource();
    await tester.pump();
    expect(coordinator.state.status, RemoteInputRuntimeStatus.idle);
    expect(calls, isEmpty);
    await tester.pump(const Duration(seconds: 3));
    expect(transport.packets, hasLength(1));
  });
}
