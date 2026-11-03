import 'dart:io';

import 'package:flutter/services.dart';
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

    test('everyone trusted and able starts', () {
      final plan = planInputTargets(
        sourcePeerId: 'self',
        root: root,
        members: [_member('a', 100)],
      );
      expect(plan.targets.map((t) => t.peerId), ['a']);
      expect(plan.excluded, isEmpty);
      expect(plan.targets.single.isMutuallyTrusted, isTrue);
      expect(plan.targets.single.remoteCanInject, isTrue);
      expect(plan.routes, isNotEmpty);
    });

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

    test('one that cannot be controlled stays out, the rest start', () {
      final plan = planInputTargets(
        sourcePeerId: 'self',
        root: root,
        members: [_member('a', 100), _member('b', -100, canInject: false)],
      );
      expect(plan.targets.map((t) => t.peerId), ['a']);
      expect(plan.excluded, {'b': InputFailure.unsupported});
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

    test('offline screens are neither started nor called failed', () {
      final plan = planInputTargets(
        sourcePeerId: 'self',
        root: root,
        members: [_member('a', 100), _member('gone', -100, connected: false)],
      );
      expect(plan.targets.map((t) => t.peerId), ['a']);
      expect(plan.excluded, isEmpty);
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

  group('what a screen says', () {
    RemoteInputWorkspaceTargetSnapshot target(
      RemoteInputWorkspaceTargetStatus status, {
      String error = '',
    }) => RemoteInputWorkspaceTargetSnapshot(
      peerId: 'a',
      peerName: 'a',
      sessionId: 's',
      status: status,
      errorMessage: error,
    );

    test('every state', () {
      InputScreenStatus of({
        bool excluded = false,
        bool active = false,
        bool live = true,
        RemoteInputWorkspaceTargetSnapshot? t,
      }) => inputScreenStatus(
        excluded: excluded,
        isActive: active,
        target: t,
        live: live,
      );
      expect(of(excluded: true), InputScreenStatus.notConnected);
      expect(of(live: false), InputScreenStatus.none);
      expect(
        of(t: target(RemoteInputWorkspaceTargetStatus.offering)),
        InputScreenStatus.waiting,
      );
      expect(
        of(t: target(RemoteInputWorkspaceTargetStatus.connected)),
        InputScreenStatus.none,
      );
      expect(
        of(active: true, t: target(RemoteInputWorkspaceTargetStatus.connected)),
        InputScreenStatus.controlling,
      );
      expect(
        of(t: target(RemoteInputWorkspaceTargetStatus.failed)),
        InputScreenStatus.notConnected,
      );
      expect(
        of(t: target(RemoteInputWorkspaceTargetStatus.stopped)),
        InputScreenStatus.notConnected,
      );
      expect(
        of(live: false, t: target(RemoteInputWorkspaceTargetStatus.stopped)),
        InputScreenStatus.none,
      );
      expect(
        of(
          live: false,
          t: target(
            RemoteInputWorkspaceTargetStatus.stopped,
            error: 'trustRequired',
          ),
        ),
        InputScreenStatus.notConnected,
      );
    });

    test('wire reasons', () {
      expect(
        inputFailureFromWire('trustRequired'),
        InputFailure.peerNotTrusting,
      );
      expect(inputFailureFromWire('unsupported'), InputFailure.unsupported);
      expect(inputFailureFromWire('permission'), InputFailure.peerPermission);
      expect(inputFailureFromWire('busy'), InputFailure.busy);
      expect(inputFailureFromWire('transport'), InputFailure.other);
      expect(inputFailureFromWire(''), InputFailure.other);
    });
  });

  group('geometry', () {
    const self = RemoteInputScreenRect(x: 0, y: 0, width: 100, height: 100);

    RemoteInputScreenRect at(int x, int y) =>
        RemoteInputScreenRect(x: x, y: y, width: 100, height: 100);

    test('which side it is on', () {
      expect(inputSideOf(self, at(100, 0)), InputSide.right);
      expect(inputSideOf(self, at(-100, 50)), InputSide.left);
      expect(inputSideOf(self, at(0, -100)), InputSide.above);
      expect(inputSideOf(self, at(50, 100)), InputSide.below);
    });

    test('touching only at a corner, or further off, is next to another', () {
      expect(inputSideOf(self, at(100, 100)), InputSide.elsewhere);
      expect(inputSideOf(self, at(300, 0)), InputSide.elsewhere);
    });

    test('fit leaves 28 all around and centres', () {
      final fit = InputFit.of(
        left: 0,
        top: 0,
        right: 1000,
        bottom: 100,
        width: 156,
        height: 200,
      );
      expect(fit.scale, closeTo(.1, 1e-9));
      expect(fit.dx, closeTo(28, 1e-9));
      expect(fit.dy, closeTo(95, 1e-9));
    });

    test('fit stops at .13 per logical pixel', () {
      final fit = InputFit.of(
        left: 0,
        top: 0,
        right: 100,
        bottom: 100,
        width: 800,
        height: 600,
      );
      expect(fit.scale, InputFit.maxScale);
      expect(fit.dx, closeTo((800 - 13) / 2, 1e-9));
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

    test('what is fine stays exactly where it is', () {
      final a = _node('a', 100, 37);
      final placed = inputReattach(root: root, nodes: {'a': a});
      expect(placed['a']!.offsetX, 100);
      expect(placed['a']!.offsetY, 37);
    });
  });

  group('the snapper', () {
    test('obstacles rule out a spot it would otherwise pick', () {
      final root = _node('self', 0, 0, controller: true);
      final moving = _node('a', 110, 0);
      final free = RemoteInputWorkspaceSnapper.snap(
        moving: moving,
        anchors: [root],
        canvasScale: 1,
        threshold: double.infinity,
      )!;
      expect(free.node.offsetX, 100);
      final blocked = RemoteInputWorkspaceSnapper.snap(
        moving: moving,
        anchors: [root],
        canvasScale: 1,
        threshold: double.infinity,
        obstacles: [_node('gone', 100, 0)],
      )!;
      expect(blocked.node.offsetX, isNot(100));
    });
  });

  group('retrying a target', () {
    test('a failed target gets a new offer only when asked', () async {
      final world = InputWorld();
      addTearDown(world.dispose);
      RemoteInputWorkspaceTargetRequest request(String peer) =>
          RemoteInputWorkspaceTargetRequest(
            peerId: peer,
            peerName: peer,
            host: '$peer.local',
            port: 10002,
            layoutEdge: RemoteInputEdge.right,
            releaseHotkey: 'ctrl+alt+esc',
            isMutuallyTrusted: true,
            remoteCanInject: true,
          );
      final sent = <RemoteInputControlMessage>[];
      void send(String peer, RemoteInputControlMessage control) =>
          sent.add(control);
      await world.workspace.startControllerWorkspace(
        sourcePeerId: 'mac',
        targets: [request('a'), request('b')],
        sendControlTo: send,
      );
      final firstOffer = sent.firstWhere((c) => c.sinkPeerId == 'b');
      await world.workspace.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.error,
          sessionId: firstOffer.sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'b',
          errorMessage: 'trustRequired',
        ),
        localPeerId: 'mac',
        remoteHost: '',
        remotePort: 0,
        sendControlTo: send,
      );
      expect(
        world.workspace.snapshot.targets['b']!.status,
        RemoteInputWorkspaceTargetStatus.failed,
      );
      sent.clear();

      await world.workspace.updateControllerWorkspaceRoutes(
        targets: [request('a'), request('b')],
        workspaceRoutes: const [],
        sendControlTo: send,
      );
      expect(
        sent.where((c) => c.action == RemoteInputControlAction.offer),
        isEmpty,
      );

      await world.workspace.updateControllerWorkspaceRoutes(
        targets: [request('a'), request('b')],
        workspaceRoutes: const [],
        sendControlTo: send,
        retryPeerIds: {'b'},
      );
      final offers = sent
          .where((c) => c.action == RemoteInputControlAction.offer)
          .toList();
      expect(offers.map((c) => c.sinkPeerId), ['b']);
      expect(offers.single.sessionId, isNot(firstOffer.sessionId));
      await world.workspace.stopControllerWorkspace();
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

    test('only connected devices are on the page', () async {
      final world = await loaded(InputWorld());
      final shown = {
        ...world.controller.screens.map((s) => s.peerId),
        ...world.controller.candidates.map((c) => c.device.uid),
      };
      expect(shown, containsAll([imacDevice.uid, thinkPadDevice.uid]));
      expect(shown, isNot(contains(ubuntuDevice.uid)));
    });

    test('a device that is away gets its saved place back on return', () async {
      final world = await loaded(InputWorld());
      world.connected.add(ubuntuDevice.uid);
      world.topologies[ubuntuDevice.uid] = topologyOf([
        [0, 0, 1920, 1080],
      ]);
      world.controller.updateDevices(
        devices: [for (final s in world.sessions) s.device],
        self: selfMac,
      );
      await pumpEventQueue(times: 80);
      final back = world.controller.screens.singleWhere(
        (s) => s.peerId == ubuntuDevice.uid,
      );
      expect(back.bounds.x, -1920);
      expect(back.bounds.y, -49);
    });

    test('what is away does not get in the way of an arrangement', () async {
      // Ubuntu is saved left of this Mac, and away: that spot looks free, so it is.
      final world = await loaded(InputWorld());
      final snap = world.controller.snapFor(imacDevice.uid, -2560, 0)!;
      expect(snap.x, lessThan(0));
      await world.controller.place(imacDevice.uid, snap.x, snap.y);
      expect(world.layouts[ubuntuDevice.uid]!.x, -1920);
    });

    test('a returning device on top of another one is moved off it', () async {
      final world = await loaded(InputWorld());
      final snap = world.controller.snapFor(imacDevice.uid, -2560, 0)!;
      await world.controller.place(imacDevice.uid, snap.x, snap.y);
      world.connected.add(ubuntuDevice.uid);
      world.topologies[ubuntuDevice.uid] = topologyOf([
        [0, 0, 1920, 1080],
      ]);
      world.controller.updateDevices(
        devices: [for (final s in world.sessions) s.device],
        self: selfMac,
      );
      await pumpEventQueue(times: 80);
      final rects = world.controller.screens.map((s) => s.bounds).toList();
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          final a = rects[i], b = rects[j];
          final apart =
              a.x + a.width <= b.x ||
              b.x + b.width <= a.x ||
              a.y + a.height <= b.y ||
              b.y + b.height <= a.y;
          expect(apart, isTrue, reason: 'screens $i and $j overlap');
        }
      }
    });

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

    test('the one left out is selected, with its reason and a retry', () async {
      final world = await loaded(
        InputWorld(notTrustingUs: {thinkPadDevice.uid}),
      );
      await world.controller.setOn(true);
      final footer = world.controller.footer as InputFooterScreen;
      expect(footer.screen.peerId, thinkPadDevice.uid);
      expect(footer.failure, InputFailure.peerNotTrusting);
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

    test('retrying while it still does not trust keeps saying so', () async {
      final world = await loaded(
        InputWorld(notTrustingUs: {thinkPadDevice.uid}),
      );
      await world.controller.setOn(true);
      await world.controller.retry(thinkPadDevice.uid);
      final footer = world.controller.footer as InputFooterScreen;
      expect(footer.failure, InputFailure.peerNotTrusting);
      expect(world.workspace.isControllerLive, isTrue);
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

    test('no target: this device only, switch off', () async {
      final world = await loaded(InputWorld(connected: {}, layouts: {}));
      expect(world.controller.screens.map((s) => s.isSelf), [true]);
      expect(world.controller.switchEnabled, isFalse);
      expect(world.controller.footer, isA<InputFooterNoTargets>());
    });

    test('a new device waits among the candidates', () async {
      final world = await loaded(InputWorld(layouts: {}));
      expect(world.controller.screens.length, 1);
      expect(world.controller.candidates.map((c) => c.device.uid), [
        imacDevice.uid,
        thinkPadDevice.uid,
      ]);
      expect(world.controller.candidates.every((c) => c.enabled), isTrue);
    });

    test('an old version is a disabled candidate saying so', () async {
      final world = await loaded(InputWorld(unsupported: {thinkPadDevice.uid}));
      final candidate = world.controller.candidates.single;
      expect(candidate.device.uid, thinkPadDevice.uid);
      expect(candidate.state, InputCandidateState.unsupported);
      expect(candidate.enabled, isFalse);
    });

    test('an offline device it knows is not offered', () async {
      final world = await loaded(
        InputWorld(
          layouts: {
            ubuntuDevice.uid: layoutOf(
              ubuntuDevice.uid,
              -1920,
              0,
              1920,
              1080,
              enabled: false,
            ),
          },
        ),
      );
      expect(
        world.controller.candidates.map((c) => c.device.uid),
        isNot(contains(ubuntuDevice.uid)),
      );
    });

    test('a phone never appears', () async {
      final world = await loaded(InputWorld());
      final ids = {
        ...world.controller.screens.map((s) => s.peerId),
        ...world.controller.candidates.map((c) => c.device.uid),
      };
      expect(ids, isNot(contains(xiaomiDevice.uid)));
    });

    test('adding puts it on the canvas, selected, and saves it', () async {
      final world = await loaded(InputWorld(layouts: {}));
      await world.controller.add(imacDevice.uid);
      expect(world.controller.selected, imacDevice.uid);
      expect(
        world.controller.screens.map((s) => s.peerId),
        contains(imacDevice.uid),
      );
      expect(world.layouts[imacDevice.uid]!.enabled, isTrue);
      final screen = world.controller.screens.last;
      final graph = RemoteInputWorkspaceGraph.build([
        _node(selfMac.uid, 0, 0, width: 1512, height: 982, controller: true),
        RemoteInputWorkspaceNode(
          peerId: imacDevice.uid,
          topology: world.topologies[imacDevice.uid]!,
          offsetX: screen.bounds.x,
          offsetY: screen.bounds.y,
        ),
      ]);
      expect(graph.reachableFrom(selfMac.uid), contains(imacDevice.uid));
    });

    test('removing takes it off and the one behind it comes back', () async {
      final world = await loaded(InputWorld());
      await world.controller.remove(imacDevice.uid);
      expect(world.layouts[imacDevice.uid]!.enabled, isFalse);
      final tp = world.controller.screens.firstWhere(
        (s) => s.peerId == thinkPadDevice.uid,
      );
      expect(tp.bounds.x, isNot(4072));
      expect(world.layouts[thinkPadDevice.uid]!.x, tp.bounds.x);
      final candidates = world.controller.candidates.map((c) => c.device.uid);
      expect(candidates, contains(imacDevice.uid));
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

    test('arrow keys move, then land by the same rules', () async {
      final world = await loaded(InputWorld());
      final before = world.controller.screens
          .firstWhere((s) => s.peerId == imacDevice.uid)
          .bounds;
      await world.controller.nudge(imacDevice.uid, 0, 100);
      final after = world.controller.screens
          .firstWhere((s) => s.peerId == imacDevice.uid)
          .bounds;
      expect(after.y, before.y + 100);
      expect(after.x, before.x);
    });

    test(
      'clicking toggles the selection, this device cannot have it',
      () async {
        final world = await loaded(InputWorld());
        world.controller.select(imacDevice.uid);
        expect(world.controller.selected, imacDevice.uid);
        world.controller.select(imacDevice.uid);
        expect(world.controller.selected, isNull);
        world.controller.select(selfMac.uid);
        expect(world.controller.selected, isNull);
      },
    );

    test('the footer asks nothing, then gives the way back', () async {
      final world = await loaded(InputWorld());
      expect(world.controller.footer, isA<InputFooterHint>());
      await world.controller.setOn(true);
      final exit = world.controller.footer as InputFooterExit;
      expect(exit.shortcut, '⌃⌥Esc');
    });

    test('the pointer goes where sharing has it', () async {
      final world = await loaded(InputWorld());
      expect(world.controller.pointerPeerId, selfMac.uid);
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

  group('tokens', () {
    test('the new pages use no raw values', () {
      final patterns = {
        'color': RegExp(r'\bColor\(\s*0x[0-9a-fA-F]+\s*\)'),
        'fontSize': RegExp(r'\bfontSize:\s*[\d.]+'),
        'duration': RegExp(r'\bDuration\(\s*milliseconds:'),
        'radius': RegExp(r'\bBorderRadius\.circular\(\s*[\d.]+\s*\)'),
      };
      for (final dir in [
        'lib/new_ui/sound',
        'lib/new_ui/input',
        'lib/new_ui/share',
      ]) {
        for (final file in Directory(dir).listSync().whereType<File>()) {
          final code = file.readAsStringSync().replaceAll(
            RegExp(r'(^|\s)//.*$', multiLine: true),
            '',
          );
          patterns.forEach((name, pattern) {
            expect(
              pattern.hasMatch(code),
              isFalse,
              reason: '$name in ${file.path}',
            );
          });
        }
      }
    });
  });
}
