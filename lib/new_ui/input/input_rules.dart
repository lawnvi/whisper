import 'dart:math' as math;

import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_graph.dart';

/// Why a screen says 没有连上. Each has its own words in the footer.
enum InputFailure {
  /// This device does not trust it.
  localNotTrusting,

  /// It does not trust this device.
  peerNotTrusting,
  unsupported,

  /// Its only way to this device runs through a screen that is not connected.
  blocked,
  peerPermission,
  busy,
  other,
}

InputFailure inputFailureFromWire(String reason) => switch (reason) {
  'trustRequired' => InputFailure.peerNotTrusting,
  'unsupported' => InputFailure.unsupported,
  'permission' => InputFailure.peerPermission,
  'busy' => InputFailure.busy,
  _ => InputFailure.other,
};

/// A screen on the arrangement, with what starting it would need.
class InputMember {
  const InputMember({
    required this.peerId,
    required this.name,
    required this.host,
    required this.port,
    required this.releaseHotkey,
    required this.node,
    required this.connected,
    required this.remoteCanInject,
    required this.localTrusts,
    required this.remoteTrusts,
  });

  final String peerId, name, host;
  final int port;
  final String releaseHotkey;
  final RemoteInputWorkspaceNode node;
  final bool connected, remoteCanInject, localTrusts, remoteTrusts;
}

class InputTargetPlan {
  const InputTargetPlan({
    required this.targets,
    required this.routes,
    required this.excluded,
  });

  final List<RemoteInputWorkspaceTargetRequest> targets;
  final List<RemoteInputWorkspaceRoute> routes;
  final Map<String, InputFailure> excluded;
}

/// `startControllerWorkspace` and `updateControllerWorkspaceRoutes` fail
/// altogether if any one target is not trusted or cannot be controlled, so those
/// are taken out first and the rest start. A screen reachable only through one
/// of them comes out too: routes are made only between screens in the session.
InputTargetPlan planInputTargets({
  required String sourcePeerId,
  required RemoteInputWorkspaceNode root,
  required Iterable<InputMember> members,
}) {
  final excluded = <String, InputFailure>{};
  final eligible = <String, InputMember>{};
  for (final member in members) {
    if (!member.connected) continue;
    if (!member.remoteCanInject) {
      excluded[member.peerId] = InputFailure.unsupported;
    } else if (!member.localTrusts) {
      excluded[member.peerId] = InputFailure.localNotTrusting;
    } else if (!member.remoteTrusts) {
      excluded[member.peerId] = InputFailure.peerNotTrusting;
    } else {
      eligible[member.peerId] = member;
    }
  }
  final graph = RemoteInputWorkspaceGraph.build([
    root,
    for (final member in eligible.values) member.node,
  ]);
  final reachable = graph.reachableFrom(
    root.peerId,
    allowedPeerIds: {root.peerId, ...eligible.keys},
  );
  final active = RemoteInputWorkspaceGraph.build(
    graph.nodes.values.where((node) => reachable.contains(node.peerId)),
  );
  final targets = <RemoteInputWorkspaceTargetRequest>[];
  for (final member in eligible.values) {
    final incoming = active.routes
        .where((route) => route.sinkPeerId == member.peerId)
        .toList(growable: false);
    if (!reachable.contains(member.peerId) || incoming.isEmpty) {
      excluded[member.peerId] = InputFailure.blocked;
      continue;
    }
    final primary = incoming.first.mapping;
    final direct = [
      for (final route in active.routes)
        if (route.sourcePeerId == sourcePeerId &&
            route.sinkPeerId == member.peerId)
          route.mapping,
    ];
    targets.add(
      RemoteInputWorkspaceTargetRequest(
        peerId: member.peerId,
        peerName: member.name,
        host: member.host,
        port: member.port,
        layoutEdge: primary.sourceEdge,
        releaseHotkey: member.releaseHotkey,
        isMutuallyTrusted: true,
        remoteCanInject: true,
        sourceDisplayId: primary.sourceDisplayId,
        sourceEdge: primary.sourceEdge,
        // Reached through another screen, it has no edge of this device. A
        // segment here would be checked against this device's own edges by
        // display id alone, and two machines often share one: the whole start
        // would be refused for overlapping edges that do not overlap. The offer
        // comes from the routes either way.
        sourceSegmentStart: direct.isEmpty ? 0 : primary.sourceSegmentStart,
        sourceSegmentEnd: direct.isEmpty ? 0 : primary.sourceSegmentEnd,
        sinkDisplayId: primary.sinkDisplayId,
        sinkEdge: primary.sinkEdge,
        sinkSegmentStart: primary.sinkSegmentStart,
        sinkSegmentEnd: primary.sinkSegmentEnd,
        edgeMappings: direct,
        injectionMappings: [for (final route in incoming) route.mapping],
      ),
    );
  }
  return InputTargetPlan(
    targets: targets,
    routes: active.routes,
    excluded: excluded,
  );
}

/// The one line a screen says about itself. `none` says nothing.
enum InputScreenStatus { none, waiting, notConnected, controlling }

InputScreenStatus inputScreenStatus({
  required bool excluded,
  required bool isActive,
  required RemoteInputWorkspaceTargetSnapshot? target,
  required bool live,
}) {
  if (excluded) return InputScreenStatus.notConnected;
  if (target == null) return InputScreenStatus.none;
  return switch (target.status) {
    RemoteInputWorkspaceTargetStatus.offering => InputScreenStatus.waiting,
    RemoteInputWorkspaceTargetStatus.connected =>
      isActive ? InputScreenStatus.controlling : InputScreenStatus.none,
    RemoteInputWorkspaceTargetStatus.failed => InputScreenStatus.notConnected,
    RemoteInputWorkspaceTargetStatus.stopped =>
      live || target.errorMessage.isNotEmpty
          ? InputScreenStatus.notConnected
          : InputScreenStatus.none,
  };
}

enum InputSide { right, left, above, below, elsewhere }

/// Where a screen is from this device's, in the footer's words.
InputSide inputSideOf(RemoteInputScreenRect self, RemoteInputScreenRect other) {
  final overlapY =
      math.min(self.bottom, other.bottom) - math.max(self.top, other.top);
  final overlapX =
      math.min(self.right, other.right) - math.max(self.left, other.left);
  if (overlapY > 0 && self.right == other.left) return InputSide.right;
  if (overlapY > 0 && other.right == self.left) return InputSide.left;
  if (overlapX > 0 && self.bottom == other.top) return InputSide.below;
  if (overlapX > 0 && other.bottom == self.top) return InputSide.above;
  return InputSide.elsewhere;
}

/// How the arrangement sits in the canvas (`kbFit`): as large as fits with 28
/// all around, never above .13 per logical pixel, centred.
class InputFit {
  const InputFit(this.scale, this.dx, this.dy);

  static const double margin = 28, maxScale = .13;

  final double scale, dx, dy;

  factory InputFit.of({
    required double left,
    required double top,
    required double right,
    required double bottom,
    required double width,
    required double height,
  }) {
    final w = math.max(1.0, right - left);
    final h = math.max(1.0, bottom - top);
    final scale = math.min(
      maxScale,
      math.min(
        math.max(1.0, width - margin * 2) / w,
        math.max(1.0, height - margin * 2) / h,
      ),
    );
    return InputFit(
      scale,
      (width - w * scale) / 2 - left * scale,
      (height - h * scale) / 2 - top * scale,
    );
  }
}

/// How much edge a landing screen shares with its neighbour at least (`m` in
/// `kbSnap`), so the pointer has room to cross. Above what the magnetizer needs.
const int _landingOverlap = 160;

/// The nearest place a screen can land (`kbSnap`): touching a screen the pointer
/// can get to, on top of nothing.
RemoteInputWorkspaceNode? inputSnap({
  required RemoteInputWorkspaceNode moving,
  required RemoteInputWorkspaceNode root,
  required Iterable<RemoteInputWorkspaceNode> others,
}) {
  final rest = [
    for (final node in others)
      if (node.peerId != moving.peerId) node,
  ];
  final reachable = RemoteInputWorkspaceGraph.build([
    root,
    ...rest,
  ]).reachableFrom(root.peerId);
  final anchors = [
    root,
    for (final node in rest)
      if (reachable.contains(node.peerId)) node,
  ];
  final anchorIds = {for (final node in anchors) node.peerId};
  return RemoteInputWorkspaceSnapper.snap(
    moving: moving,
    anchors: anchors,
    canvasScale: 1,
    threshold: double.infinity,
    minimumSharedEdge: _landingOverlap,
    obstacles: [
      for (final node in rest)
        if (!anchorIds.contains(node.peerId)) node,
    ],
  )?.node;
}

/// Screens never hang in the air (`kbReattach`): whatever the pointer can no
/// longer reach, or that sits on another screen, snaps back. Returns the nodes at
/// their new places.
Map<String, RemoteInputWorkspaceNode> inputReattach({
  required RemoteInputWorkspaceNode root,
  required Map<String, RemoteInputWorkspaceNode> nodes,
}) {
  final placed = Map<String, RemoteInputWorkspaceNode>.of(nodes);
  for (var guard = 0; guard <= nodes.length; guard++) {
    final graph = RemoteInputWorkspaceGraph.build([root, ...placed.values]);
    final reachable = graph.reachableFrom(root.peerId);
    final lost =
        placed.keys
            .where(
              (peerId) =>
                  !reachable.contains(peerId) ||
                  graph.conflictingPeerIds.contains(peerId),
            )
            .toList()
          ..sort();
    if (lost.isEmpty) break;
    final peerId = lost.first;
    final moving = placed[peerId]!;
    placed[peerId] =
        inputSnap(moving: moving, root: root, others: placed.values) ??
        RemoteInputWorkspaceMagnetizer.connectAll(
          root: root,
          nodes: placed.values,
          preferredPeerId: peerId,
        )[peerId]!;
  }
  return placed;
}
