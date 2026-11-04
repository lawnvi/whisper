import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/new_ui/input/input_controller.dart';
import 'package:whisper/new_ui/input/input_rules.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_graph.dart';

import 'support/share_page_fixtures.dart';

RemoteInputWorkspaceNode _node(
  String peerId,
  int x,
  int y, {
  int width = 100,
  int height = 100,
  bool controller = false,
}) => RemoteInputWorkspaceNode(
  peerId: peerId,
  topology: topologyOf([
    [0, 0, width, height],
  ]),
  offsetX: x,
  offsetY: y,
  isController: controller,
);

InputMember _member(
  String peerId,
  int x, {
  bool connected = true,
  bool canInject = true,
  bool localTrusts = true,
  bool remoteTrusts = true,
}) => InputMember(
  peerId: peerId,
  name: peerId,
  host: '$peerId.local',
  port: 10002,
  releaseHotkey: 'ctrl+alt+esc',
  node: _node(peerId, x, 0),
  connected: connected,
  remoteCanInject: canInject,
  localTrusts: localTrusts,
  remoteTrusts: remoteTrusts,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('filtering targets before starting', () {
    final root = _node('self', 0, 0, controller: true);

    test('one this device does not trust stays out, the rest start', () {
      final plan = planInputTargets(
        sourcePeerId: 'self',
        root: root,
        members: [_member('a', 100), _member('b', -100, localTrusts: false)],
      );
      expect(plan.targets.map((t) => t.peerId), ['a']);
      expect(plan.excluded, {'b': InputFailure.localNotTrusting});
    });

    test('one that does not trust this device stays out, the rest start', () {
      final plan = planInputTargets(
        sourcePeerId: 'self',
        root: root,
        members: [_member('a', 100), _member('b', -100, remoteTrusts: false)],
      );
      expect(plan.targets.map((t) => t.peerId), ['a']);
      expect(plan.excluded, {'b': InputFailure.peerNotTrusting});
    });

    test('a screen only reachable through an excluded one stays out too', () {
      final plan = planInputTargets(
        sourcePeerId: 'self',
        root: root,
        members: [
          _member('near', 100, remoteTrusts: false),
          _member('far', 200),
        ],
      );
      expect(plan.targets, isEmpty);
      expect(plan.routes, isEmpty);
      expect(plan.excluded, {
        'near': InputFailure.peerNotTrusting,
        'far': InputFailure.blocked,
      });
    });

    test('a chain of machines with the same display id can start', () async {
      // Every Mac's built-in display tends to have the same id.
      final plan = planInputTargets(
        sourcePeerId: 'self',
        root: root,
        members: [_member('near', 100), _member('far', 200)],
      );
      expect(plan.targets.map((t) => t.peerId), ['near', 'far']);
      final far = plan.targets.last;
      expect(far.edgeMappings, isEmpty);
      expect(far.injectionMappings, isNotEmpty);
      expect(
        RemoteInputWorkspaceLayoutValidator.validateTargets(
          plan.targets,
        ).hasConflict,
        isFalse,
      );
    });

    test('what is left never makes the coordinator refuse', () async {
      final plan = planInputTargets(
        sourcePeerId: 'self',
        root: root,
        members: [_member('a', 100), _member('b', -100, localTrusts: false)],
      );
      final world = InputWorld();
      addTearDown(world.dispose);
      await world.workspace.startControllerWorkspace(
        sourcePeerId: 'self',
        targets: plan.targets,
        workspaceRoutes: plan.routes,
        sendControlTo: (_, _) {},
      );
      expect(world.workspace.isControllerLive, isTrue);
      await world.workspace.stopControllerWorkspace();
    });
  });

  group('geometry', () {
    const self = RemoteInputScreenRect(x: 0, y: 0, width: 100, height: 100);

    RemoteInputScreenRect at(int x, int y) =>
        RemoteInputScreenRect(x: x, y: y, width: 100, height: 100);

    test('touching only at a corner, or further off, is next to another', () {
      expect(inputSideOf(self, at(100, 100)), InputSide.elsewhere);
      expect(inputSideOf(self, at(300, 0)), InputSide.elsewhere);
    });
  });

  group('screens never hang in the air', () {
    final root = _node('self', 0, 0, controller: true);

    test('a snap lands touching a screen the pointer can reach', () {
      final landed = inputSnap(
        moving: _node('a', 500, 10),
        root: root,
        others: const [],
      )!;
      final graph = RemoteInputWorkspaceGraph.build([root, landed]);
      expect(graph.reachableFrom('self'), contains('a'));
    });

    test('taking out the middle one brings the far one back', () {
      final placed = inputReattach(
        root: root,
        nodes: {'far': _node('far', 200, 0)},
      );
      final graph = RemoteInputWorkspaceGraph.build([root, ...placed.values]);
      expect(graph.reachableFrom('self'), contains('far'));
    });

    test('screens that ended up on top of each other separate', () {
      final placed = inputReattach(
        root: root,
        nodes: {'a': _node('a', 100, 0), 'b': _node('b', 120, 0)},
      );
      final graph = RemoteInputWorkspaceGraph.build([root, ...placed.values]);
      expect(graph.conflictingPeerIds, isEmpty);
      expect(graph.reachableFrom('self'), containsAll(['a', 'b']));
    });
  });

  group('the page state', () {
    Future<InputWorld> loaded(InputWorld world) async {
      addTearDown(world.dispose);
      world.controller.attach(
        devices: [for (final s in world.sessions) s.device],
        self: selfMac,
      );
      await pumpEventQueue(times: 80);
      return world;
    }

    test('starting skips who cannot join and starts the rest', () async {
      final world = await loaded(
        InputWorld(notTrustingUs: {thinkPadDevice.uid}),
      );
      await world.controller.setOn(true);

      expect(world.workspace.isControllerLive, isTrue);
      expect(world.workspace.snapshot.targets.keys, [imacDevice.uid]);
      final screens = {for (final s in world.controller.screens) s.peerId: s};
      expect(
        screens[thinkPadDevice.uid]!.status,
        InputScreenStatus.notConnected,
      );
      expect(screens[imacDevice.uid]!.status, InputScreenStatus.waiting);
      expect(screens, isNot(contains(ubuntuDevice.uid)));
    });

    test('retrying brings it in once it trusts this device', () async {
      final world = await loaded(
        InputWorld(notTrustingUs: {thinkPadDevice.uid}),
      );
      await world.controller.setOn(true);
      world.sent.clear();
      world.notTrustingUs.clear();

      await world.controller.retry(thinkPadDevice.uid);

      expect(
        world.workspace.snapshot.targets.keys,
        unorderedEquals([imacDevice.uid, thinkPadDevice.uid]),
      );
      expect(
        world.sent
            .where((s) => s.$2.action == RemoteInputControlAction.offer)
            .map((s) => s.$1),
        [thinkPadDevice.uid],
      );
      final footer = world.controller.footer as InputFooterScreen;
      expect(footer.failure, isNull);
    });

    test('when nobody can join it does not start, and says why', () async {
      final world = await loaded(
        InputWorld(
          connected: {thinkPadDevice.uid},
          notTrusted: {thinkPadDevice.uid},
        ),
      );
      await world.controller.setOn(true);
      expect(world.workspace.isControllerLive, isFalse);
      expect(world.controller.on, isFalse);
      final footer = world.controller.footer as InputFooterScreen;
      expect(footer.failure, InputFailure.localNotTrusting);
    });

    test('a failure after connecting belongs to that target alone', () async {
      final world = await loaded(InputWorld());
      await world.controller.setOn(true);
      await world.accept(imacDevice.uid);
      await world.reject(thinkPadDevice.uid);
      expect(world.workspace.isControllerLive, isTrue);
      final screens = {for (final s in world.controller.screens) s.peerId: s};
      expect(
        screens[thinkPadDevice.uid]!.status,
        InputScreenStatus.notConnected,
      );
      expect(screens[imacDevice.uid]!.status, InputScreenStatus.none);
    });

    test('retrying a target that failed sends it a new offer', () async {
      final world = await loaded(InputWorld());
      await world.controller.setOn(true);
      await world.accept(imacDevice.uid);
      await world.reject(thinkPadDevice.uid);
      world.sent.clear();

      await world.controller.retry(thinkPadDevice.uid);

      expect(
        world.sent
            .where((s) => s.$2.action == RemoteInputControlAction.offer)
            .map((s) => s.$1),
        [thinkPadDevice.uid],
      );
    });

    test('off stops, clears, and keeps the arrangement', () async {
      final world = await loaded(
        InputWorld(notTrustingUs: {thinkPadDevice.uid}),
      );
      await world.controller.setOn(true);
      final before = world.controller.screens.map((s) => s.peerId).toList();
      await world.controller.setOn(false);
      expect(world.workspace.isControllerLive, isFalse);
      expect(world.controller.screens.map((s) => s.peerId), before);
      for (final screen in world.controller.screens) {
        expect(screen.status, isNot(InputScreenStatus.notConnected));
      }
    });

    test('without permission the switch has no effect and says why', () async {
      final world = await loaded(InputWorld(denied: true));
      world.controller.select(imacDevice.uid);
      await world.controller.setOn(true);
      expect(world.workspace.isControllerLive, isFalse);
      expect(world.controller.footer, isA<InputFooterPermission>());
    });

    test('an old version is a disabled candidate saying so', () async {
      final world = await loaded(InputWorld(unsupported: {thinkPadDevice.uid}));
      final candidate = world.controller.candidates.single;
      expect(candidate.device.uid, thinkPadDevice.uid);
      expect(candidate.state, InputCandidateState.unsupported);
      expect(candidate.enabled, isFalse);
    });

    test('moving while sharing updates the routes in place', () async {
      final world = await loaded(InputWorld());
      await world.controller.setOn(true);
      final session = world.workspace.snapshot.workspaceSessionId;
      final snap = world.controller.snapFor(imacDevice.uid, -2000, 0)!;
      await world.controller.place(imacDevice.uid, snap.x, snap.y);
      expect(world.workspace.snapshot.workspaceSessionId, session);
      expect(world.workspace.isControllerLive, isTrue);
    });

    test(
      'being controlled is read from the runtime, and can be stopped',
      () async {
        final world = await loaded(InputWorld());
        expect(world.controller.controlledBy, isNull);
        await world.runtime.handleControlMessage(
          RemoteInputControlMessage(
            action: RemoteInputControlAction.offer,
            sessionId: 'controlled',
            sourcePeerId: imacDevice.uid,
            sinkPeerId: selfMac.uid,
            layoutEdge: RemoteInputEdge.right,
          ),
          localPeerId: selfMac.uid,
          remoteHost: 'imac.local',
          remotePort: 10002,
          isMutuallyTrusted: true,
          localCanInject: true,
          sendControl: (_) {},
        );
        expect(world.runtime.state.role, RemoteInputRuntimeRole.sink);
        expect(world.controller.controlledBy, imacDevice.uid);
        await world.controller.stopBeingControlled();
        expect(world.controller.controlledBy, isNull);
        expect(
          world.sent.map((s) => s.$2.action),
          contains(RemoteInputControlAction.stop),
        );
      },
    );
  });
}
