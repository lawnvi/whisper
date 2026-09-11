import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_lifecycle.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_graph.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test_remote_input_lifecycle');
  late RemoteInputManager manager;
  late RemoteInputCoordinator pair;
  late RemoteInputWorkspaceCoordinator workspace;
  late List<MethodCall> calls;
  late List<RemoteInputControlMessage> controls;
  Future<void> Function(MethodCall)? onNativeCall;

  void send(RemoteInputControlMessage control) => controls.add(control);
  void sendTo(String peerId, RemoteInputControlMessage control) =>
      send(control);
  Future<void> offerToSink([String sessionId = 'incoming']) =>
      pair.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.offer,
          sessionId: sessionId,
          sourcePeerId: 'controller',
          sinkPeerId: 'local',
          layoutEdge: RemoteInputEdge.right,
        ),
        localPeerId: 'local',
        remoteHost: 'controller.local',
        remotePort: 10002,
        isMutuallyTrusted: true,
        localCanInject: true,
        sendControl: send,
      );
  Future<void> startPair() => pair.startSharingToConnectedPeer(
    sourcePeerId: 'local',
    sinkPeerId: 'peer',
    sinkHost: 'peer.local',
    sinkPort: 10002,
    layoutEdge: RemoteInputEdge.right,
    releaseHotkey: 'ctrl+alt+esc',
    isMutuallyTrusted: true,
    remoteCanInject: true,
    sendControl: send,
  );
  Future<void> startWorkspace({bool reconnect = false}) =>
      workspace.startControllerWorkspace(
        sourcePeerId: 'local',
        targets: const [
          RemoteInputWorkspaceTargetRequest(
            peerId: 'peer',
            peerName: 'Peer',
            host: 'peer.local',
            port: 10002,
            layoutEdge: RemoteInputEdge.right,
            releaseHotkey: 'ctrl+alt+esc',
            isMutuallyTrusted: true,
            remoteCanInject: true,
          ),
        ],
        workspaceRoutes: reconnect
            ? const [
                RemoteInputWorkspaceRoute(
                  routeId: 'to-peer',
                  sourcePeerId: 'local',
                  sinkPeerId: 'peer',
                  mapping: RemoteInputEdgeMapping(
                    routeId: 'to-peer',
                    sourceDisplayId: 'local-display',
                    sourceEdge: RemoteInputEdge.right,
                    sourceSegmentStart: 0,
                    sourceSegmentEnd: 800,
                    sinkDisplayId: 'peer-display',
                    sinkEdge: RemoteInputEdge.left,
                    sinkSegmentStart: 0,
                    sinkSegmentEnd: 800,
                  ),
                ),
              ]
            : const [],
        sendControlTo: sendTo,
      );

  setUp(() {
    manager = RemoteInputManager();
    final platform = RemoteInputPlatform(channel: channel);
    calls = [];
    controls = [];
    onNativeCall = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          await onNativeCall?.call(call);
          return null;
        });
    pair = RemoteInputCoordinator(
      manager: manager,
      platform: platform,
      scrollMultiplierProvider: () async => 1,
      transportFactory: (_) async =>
          RemoteInputPacketByteTransport(sendBytes: (_) {}),
    );
    workspace = RemoteInputWorkspaceCoordinator(
      manager: manager,
      platform: platform,
      transportFactory: (_) async =>
          RemoteInputPacketByteTransport(sendBytes: (_) {}),
    );
  });
  tearDown(() async {
    onNativeCall = null;
    await pair.stopLocal();
    await workspace.stopControllerWorkspace();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'simultaneous starts reserve native input for exactly one mode',
    () async {
      final results = await Future.wait([
        startPair().then<Object?>((_) => null, onError: (Object e) => e),
        startWorkspace().then<Object?>((_) => null, onError: (Object e) => e),
      ]);
      expect(results.whereType<RemoteInputBusyException>(), hasLength(1));
      expect(
        controls.where((c) => c.action == RemoteInputControlAction.offer),
        hasLength(1),
      );
    },
  );

  test(
    'workspace ownership rejects incoming offers without socket prechecks',
    () async {
      await startWorkspace();
      await offerToSink();
      expect(controls.last.action, RemoteInputControlAction.reject);
      expect(controls.last.errorMessage, 'busy');
      expect(calls.where((c) => c.method == 'startInjection'), isEmpty);
      expect(workspace.snapshot.isControllerLive, isTrue);
    },
  );

  test(
    'a controlled device cannot also start a controller workspace',
    () async {
      final platform = pair.platform;
      manager = RemoteInputManager.shared;
      pair = RemoteInputCoordinator(
        platform: platform,
        scrollMultiplierProvider: () async => 1,
      );
      workspace = RemoteInputWorkspaceCoordinator(platform: platform);
      await offerToSink();
      await expectLater(
        startWorkspace(),
        throwsA(isA<RemoteInputBusyException>()),
      );
      expect(pair.state.role, RemoteInputRuntimeRole.sink);
      expect(pair.state.status, RemoteInputRuntimeStatus.active);
      expect(manager.onPacket, isNotNull);
    },
  );

  test('role handoff waits for native stop and deduplicates cleanup', () async {
    await offerToSink();
    final started = Completer<void>(), finish = Completer<void>();
    onNativeCall = (call) async {
      if (call.method == 'stopInjection') {
        started.complete();
        await finish.future;
      }
    };
    final stopping = pair.stopLocal();
    await started.future;
    final next = startWorkspace();
    final repeatedStop = pair.stopLocal();
    await Future<void>.delayed(Duration.zero);
    expect(
      controls.where((c) => c.action == RemoteInputControlAction.offer),
      isEmpty,
    );
    expect(calls.where((c) => c.method == 'stopInjection'), hasLength(1));
    finish.complete();
    await Future.wait([stopping, repeatedStop, next]);
    expect(workspace.snapshot.isControllerLive, isTrue);
    expect(pair.state.status, RemoteInputRuntimeStatus.idle);
  });

  test('incoming control cancels a dormant workspace reconnect plan', () async {
    await startWorkspace(reconnect: true);
    await workspace.handlePeerDisconnected('peer');
    expect(workspace.snapshot.role, RemoteInputWorkspaceRole.controller);
    expect(workspace.snapshot.isControllerLive, isFalse);
    await offerToSink();
    expect(pair.state.role, RemoteInputRuntimeRole.sink);
    expect(pair.state.isActive, isTrue);
    expect(workspace.snapshot.role, RemoteInputWorkspaceRole.idle);
    await workspace.handlePeerReconnected(
      peerId: 'peer',
      host: 'peer.local',
      port: 10002,
      isMutuallyTrusted: true,
      remoteCanInject: true,
      sendControlTo: (_, _) => fail('Dormant controller must not restart'),
    );
  });

  test(
    'late native startup rolls back before another mode takes ownership',
    () async {
      final started = Completer<void>(), finish = Completer<void>();
      onNativeCall = (call) async {
        if (call.method == 'startInjection') {
          started.complete();
          await finish.future;
        }
      };
      final incoming = offerToSink();
      await started.future;
      await pair.stopLocal();
      final next = startWorkspace();
      await Future<void>.delayed(Duration.zero);
      expect(controls, isEmpty);
      finish.complete();
      await Future.wait([incoming, next]);
      expect(calls.where((c) => c.method == 'stopInjection'), hasLength(2));
      expect(pair.state.status, RemoteInputRuntimeStatus.idle);
      expect(workspace.snapshot.isControllerLive, isTrue);
      expect(controls.map((c) => c.action), [RemoteInputControlAction.offer]);
    },
  );

  test(
    'a late edge-release callback cannot revive the previous mode',
    () async {
      await startPair();
      final sessionId = controls.single.sessionId;
      Future<void> deliver(RemoteInputControlAction action) =>
          pair.handleControlMessage(
            RemoteInputControlMessage(
              action: action,
              sessionId: sessionId,
              sourcePeerId: 'local',
              sinkPeerId: 'peer',
              layoutEdge: RemoteInputEdge.right,
              releaseReason: 'edge',
            ),
            localPeerId: 'local',
            remoteHost: 'peer.local',
            remotePort: 10002,
            isMutuallyTrusted: true,
            localCanInject: true,
            sendControl: send,
          );
      await deliver(RemoteInputControlAction.accept);
      final started = Completer<void>(), finish = Completer<void>();
      onNativeCall = (call) async {
        if (call.method == 'pauseCapture') {
          started.complete();
          await finish.future;
        }
      };
      final release = deliver(RemoteInputControlAction.release);
      await started.future;
      await pair.stopLocal();
      await startWorkspace();
      finish.complete();
      await release;
      expect(pair.state.status, RemoteInputRuntimeStatus.idle);
      expect(workspace.snapshot.isControllerLive, isTrue);
    },
  );

  test(
    'workspace stop clears its clipboard before allowing another mode',
    () async {
      final cleaned = <String>[];
      final finish = Completer<void>();
      manager.configureSessionCleanup(({
        required peerId,
        required sessionId,
      }) async {
        cleaned.add('$peerId/$sessionId');
        await finish.future;
      });
      await startWorkspace();
      final sessionId = controls.single.sessionId;
      final stopping = workspace.stopControllerWorkspace();
      final next = startPair();
      await Future<void>.delayed(Duration.zero);
      expect(cleaned, ['peer/$sessionId']);
      expect(calls.where((c) => c.method == 'stopCapture'), hasLength(1));
      expect(pair.state.status, RemoteInputRuntimeStatus.idle);
      finish.complete();
      await Future.wait([stopping, next]);
      expect(pair.state.role, RemoteInputRuntimeRole.source);
      expect(cleaned, hasLength(1));
    },
  );

  test(
    'failure sending stop cannot skip native cleanup or retain ownership',
    () async {
      await offerToSink();
      await expectLater(
        pair.stopSharing(sendControl: (_) => throw StateError('disconnected')),
        throwsStateError,
      );
      expect(calls.where((c) => c.method == 'stopInjection'), hasLength(1));
      expect(
        manager.session('incoming')?.state,
        RemoteInputSessionState.stopped,
      );
      await startWorkspace();
      expect(workspace.snapshot.isControllerLive, isTrue);
    },
  );
}
