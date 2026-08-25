import 'dart:math' as math;

import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

class RemoteInputWorkspaceNode {
  const RemoteInputWorkspaceNode({
    required this.peerId,
    required this.topology,
    required this.offsetX,
    required this.offsetY,
    this.isController = false,
  });

  final String peerId;
  final RemoteInputTopology topology;
  final int offsetX;
  final int offsetY;
  final bool isController;

  List<RemoteInputDisplay> get placedDisplays => topology.displays
      .map((display) => display.translated(dx: offsetX, dy: offsetY))
      .toList(growable: false);

  RemoteInputScreenRect get bounds {
    final displays = placedDisplays;
    if (displays.isEmpty) {
      return RemoteInputScreenRect(x: offsetX, y: offsetY, width: 1, height: 1);
    }
    var left = displays.first.left;
    var top = displays.first.top;
    var right = displays.first.right;
    var bottom = displays.first.bottom;
    for (final display in displays.skip(1)) {
      left = math.min(left, display.left);
      top = math.min(top, display.top);
      right = math.max(right, display.right);
      bottom = math.max(bottom, display.bottom);
    }
    return RemoteInputScreenRect(
      x: left,
      y: top,
      width: math.max(1, right - left),
      height: math.max(1, bottom - top),
    );
  }

  RemoteInputWorkspaceNode translated({required int dx, required int dy}) {
    return RemoteInputWorkspaceNode(
      peerId: peerId,
      topology: topology,
      offsetX: offsetX + dx,
      offsetY: offsetY + dy,
      isController: isController,
    );
  }
}

class RemoteInputWorkspaceRoute {
  const RemoteInputWorkspaceRoute({
    required this.routeId,
    required this.sourcePeerId,
    required this.sinkPeerId,
    required this.mapping,
  });

  final String routeId;
  final String sourcePeerId;
  final String sinkPeerId;
  final RemoteInputEdgeMapping mapping;
}

class RemoteInputWorkspaceGraph {
  const RemoteInputWorkspaceGraph({
    required this.nodes,
    required this.routes,
    this.conflictingPeerIds = const <String>{},
  });

  final Map<String, RemoteInputWorkspaceNode> nodes;
  final List<RemoteInputWorkspaceRoute> routes;
  final Set<String> conflictingPeerIds;

  factory RemoteInputWorkspaceGraph.build(
    Iterable<RemoteInputWorkspaceNode> sourceNodes,
  ) {
    final sortedNodes =
        sourceNodes
            .where((node) => node.peerId.isNotEmpty && node.topology.isNotEmpty)
            .toList(growable: false)
          ..sort((left, right) => left.peerId.compareTo(right.peerId));
    final nodes = <String, RemoteInputWorkspaceNode>{
      for (final node in sortedNodes) node.peerId: node,
    };
    final conflicts = <String>{};
    final routes = <RemoteInputWorkspaceRoute>[];

    for (var leftIndex = 0; leftIndex < sortedNodes.length; leftIndex++) {
      final left = sortedNodes[leftIndex];
      for (
        var rightIndex = leftIndex + 1;
        rightIndex < sortedNodes.length;
        rightIndex++
      ) {
        final right = sortedNodes[rightIndex];
        if (_nodesOverlap(left, right)) {
          conflicts
            ..add(left.peerId)
            ..add(right.peerId);
          continue;
        }
        routes.addAll(_routesBetween(left, right));
      }
    }
    routes.sort((left, right) => left.routeId.compareTo(right.routeId));
    return RemoteInputWorkspaceGraph(
      nodes: Map<String, RemoteInputWorkspaceNode>.unmodifiable(nodes),
      routes: List<RemoteInputWorkspaceRoute>.unmodifiable(routes),
      conflictingPeerIds: Set<String>.unmodifiable(conflicts),
    );
  }

  List<RemoteInputWorkspaceRoute> routesFrom(String peerId) => routes
      .where((route) => route.sourcePeerId == peerId)
      .toList(growable: false);

  Set<String> reachableFrom(String rootPeerId, {Set<String>? allowedPeerIds}) {
    if (!nodes.containsKey(rootPeerId) ||
        conflictingPeerIds.contains(rootPeerId) ||
        (allowedPeerIds != null && !allowedPeerIds.contains(rootPeerId))) {
      return <String>{};
    }
    final reachable = <String>{rootPeerId};
    final pending = <String>[rootPeerId];
    while (pending.isNotEmpty) {
      final sourcePeerId = pending.removeLast();
      for (final route in routesFrom(sourcePeerId)) {
        final sinkPeerId = route.sinkPeerId;
        if (conflictingPeerIds.contains(sinkPeerId) ||
            (allowedPeerIds != null && !allowedPeerIds.contains(sinkPeerId)) ||
            !reachable.add(sinkPeerId)) {
          continue;
        }
        pending.add(sinkPeerId);
      }
    }
    return reachable;
  }

  static bool _nodesOverlap(
    RemoteInputWorkspaceNode left,
    RemoteInputWorkspaceNode right,
  ) {
    for (final leftDisplay in left.placedDisplays) {
      for (final rightDisplay in right.placedDisplays) {
        if (_rectsOverlap(leftDisplay.rect, rightDisplay.rect)) {
          return true;
        }
      }
    }
    return false;
  }

  static Iterable<RemoteInputWorkspaceRoute> _routesBetween(
    RemoteInputWorkspaceNode left,
    RemoteInputWorkspaceNode right,
  ) sync* {
    final leftDisplays = left.placedDisplays;
    final rightDisplays = right.placedDisplays;
    for (final leftDisplay in leftDisplays) {
      for (final rightDisplay in rightDisplays) {
        for (final leftEdge in RemoteInputEdge.values) {
          final rightEdge = RemoteInputLayoutGeometry.oppositeEdge(leftEdge);
          final segment = RemoteInputLayoutGeometry.sharedEdgeSegment(
            source: leftDisplay,
            sourceEdge: leftEdge,
            sinkInLayout: rightDisplay,
            sinkEdge: rightEdge,
          );
          if (segment == null ||
              !RemoteInputLayoutGeometry.isOuterEdgeSegment(
                display: leftDisplay,
                edge: leftEdge,
                displays: leftDisplays,
                segmentStart: segment.start,
                segmentEnd: segment.end,
              ) ||
              !RemoteInputLayoutGeometry.isOuterEdgeSegment(
                display: rightDisplay,
                edge: rightEdge,
                displays: rightDisplays,
                segmentStart: segment.start,
                segmentEnd: segment.end,
              )) {
            continue;
          }
          yield _directedRoute(
            source: left,
            sourceDisplay: leftDisplay,
            sourceEdge: leftEdge,
            sink: right,
            sinkDisplay: rightDisplay,
            sinkEdge: rightEdge,
            globalStart: segment.start,
            globalEnd: segment.end,
          );
          yield _directedRoute(
            source: right,
            sourceDisplay: rightDisplay,
            sourceEdge: rightEdge,
            sink: left,
            sinkDisplay: leftDisplay,
            sinkEdge: leftEdge,
            globalStart: segment.start,
            globalEnd: segment.end,
          );
        }
      }
    }
  }

  static RemoteInputWorkspaceRoute _directedRoute({
    required RemoteInputWorkspaceNode source,
    required RemoteInputDisplay sourceDisplay,
    required RemoteInputEdge sourceEdge,
    required RemoteInputWorkspaceNode sink,
    required RemoteInputDisplay sinkDisplay,
    required RemoteInputEdge sinkEdge,
    required int globalStart,
    required int globalEnd,
  }) {
    final vertical =
        sourceEdge == RemoteInputEdge.left ||
        sourceEdge == RemoteInputEdge.right;
    final sourceOffset = vertical ? source.offsetY : source.offsetX;
    final sinkOffset = vertical ? sink.offsetY : sink.offsetX;
    final routeId = <Object>[
      'workspace',
      source.peerId,
      sourceDisplay.displayId,
      sourceEdge.name,
      globalStart,
      globalEnd,
      sink.peerId,
      sinkDisplay.displayId,
      sinkEdge.name,
    ].join('|');
    final mapping = RemoteInputEdgeMapping(
      routeId: routeId,
      sourceDisplayId: sourceDisplay.displayId,
      sourceEdge: sourceEdge,
      sourceSegmentStart: globalStart - sourceOffset,
      sourceSegmentEnd: globalEnd - sourceOffset,
      sinkDisplayId: sinkDisplay.displayId,
      sinkEdge: sinkEdge,
      sinkSegmentStart: globalStart - sinkOffset,
      sinkSegmentEnd: globalEnd - sinkOffset,
    );
    return RemoteInputWorkspaceRoute(
      routeId: routeId,
      sourcePeerId: source.peerId,
      sinkPeerId: sink.peerId,
      mapping: mapping,
    );
  }

  static bool _rectsOverlap(
    RemoteInputScreenRect left,
    RemoteInputScreenRect right,
  ) {
    return left.left < right.right &&
        left.right > right.left &&
        left.top < right.bottom &&
        left.bottom > right.top;
  }
}

class RemoteInputWorkspaceSnapResult {
  const RemoteInputWorkspaceSnapResult({
    required this.node,
    required this.anchorPeerId,
    required this.distanceInCanvas,
  });

  final RemoteInputWorkspaceNode node;
  final String anchorPeerId;
  final double distanceInCanvas;
}

abstract final class RemoteInputWorkspaceSnapper {
  static const double defaultThreshold = 24;
  static const int defaultMinimumSharedEdge = 1;

  static RemoteInputWorkspaceSnapResult? snap({
    required RemoteInputWorkspaceNode moving,
    required Iterable<RemoteInputWorkspaceNode> anchors,
    required double canvasScale,
    double threshold = defaultThreshold,
    int minimumSharedEdge = defaultMinimumSharedEdge,
  }) {
    if (canvasScale <= 0 ||
        threshold < 0 ||
        minimumSharedEdge <= 0 ||
        moving.topology.isEmpty) {
      return null;
    }
    final anchorList =
        anchors
            .where(
              (node) =>
                  node.peerId != moving.peerId && node.topology.isNotEmpty,
            )
            .toList(growable: false)
          ..sort((left, right) => left.peerId.compareTo(right.peerId));
    _SnapCandidate? best;
    for (final anchor in anchorList) {
      final anchorDisplays = anchor.placedDisplays;
      final movingDisplays = moving.placedDisplays;
      for (final anchorDisplay in anchorDisplays) {
        for (final movingDisplay in movingDisplays) {
          for (final anchorEdge in RemoteInputEdge.values) {
            final movingEdge = RemoteInputLayoutGeometry.oppositeEdge(
              anchorEdge,
            );
            final delta = _snapDelta(
              anchor: anchorDisplay.rect,
              moving: movingDisplay.rect,
              anchorEdge: anchorEdge,
              minimumSharedEdge: minimumSharedEdge,
            );
            final distance =
                math.sqrt(delta.x * delta.x + delta.y * delta.y) * canvasScale;
            if (distance > threshold) {
              continue;
            }
            final candidateNode = moving.translated(dx: delta.x, dy: delta.y);
            final candidateDisplays = candidateNode.placedDisplays;
            final candidateDisplay = candidateDisplays.firstWhere(
              (display) => display.displayId == movingDisplay.displayId,
            );
            final segment = RemoteInputLayoutGeometry.sharedEdgeSegment(
              source: anchorDisplay,
              sourceEdge: anchorEdge,
              sinkInLayout: candidateDisplay,
              sinkEdge: movingEdge,
            );
            if (segment == null ||
                !RemoteInputLayoutGeometry.isOuterEdgeSegment(
                  display: anchorDisplay,
                  edge: anchorEdge,
                  displays: anchorDisplays,
                  segmentStart: segment.start,
                  segmentEnd: segment.end,
                ) ||
                !RemoteInputLayoutGeometry.isOuterEdgeSegment(
                  display: candidateDisplay,
                  edge: movingEdge,
                  displays: candidateDisplays,
                  segmentStart: segment.start,
                  segmentEnd: segment.end,
                ) ||
                anchorList.any(
                  (other) =>
                      other.peerId != anchor.peerId &&
                      RemoteInputWorkspaceGraph._nodesOverlap(
                        candidateNode,
                        other,
                      ),
                )) {
              continue;
            }
            final candidate = _SnapCandidate(
              result: RemoteInputWorkspaceSnapResult(
                node: candidateNode,
                anchorPeerId: anchor.peerId,
                distanceInCanvas: distance,
              ),
              tieBreak: <Object>[
                anchor.peerId,
                anchorDisplay.displayId,
                anchorEdge.name,
                movingDisplay.displayId,
              ].join('|'),
            );
            if (best == null || candidate.isBetterThan(best)) {
              best = candidate;
            }
          }
        }
      }
    }
    return best?.result;
  }

  static math.Point<int> _snapDelta({
    required RemoteInputScreenRect anchor,
    required RemoteInputScreenRect moving,
    required RemoteInputEdge anchorEdge,
    required int minimumSharedEdge,
  }) {
    final vertical =
        anchorEdge == RemoteInputEdge.left ||
        anchorEdge == RemoteInputEdge.right;
    final sharedEdge = math.min(
      minimumSharedEdge,
      vertical
          ? math.min(anchor.height, moving.height)
          : math.min(anchor.width, moving.width),
    );
    switch (anchorEdge) {
      case RemoteInputEdge.left:
        return math.Point<int>(
          anchor.left - moving.right,
          _clamp(
                moving.top,
                anchor.top - moving.height + sharedEdge,
                anchor.bottom - sharedEdge,
              ) -
              moving.top,
        );
      case RemoteInputEdge.right:
        return math.Point<int>(
          anchor.right - moving.left,
          _clamp(
                moving.top,
                anchor.top - moving.height + sharedEdge,
                anchor.bottom - sharedEdge,
              ) -
              moving.top,
        );
      case RemoteInputEdge.top:
        return math.Point<int>(
          _clamp(
                moving.left,
                anchor.left - moving.width + sharedEdge,
                anchor.right - sharedEdge,
              ) -
              moving.left,
          anchor.top - moving.bottom,
        );
      case RemoteInputEdge.bottom:
        return math.Point<int>(
          _clamp(
                moving.left,
                anchor.left - moving.width + sharedEdge,
                anchor.right - sharedEdge,
              ) -
              moving.left,
          anchor.bottom - moving.top,
        );
    }
  }

  static int _clamp(int value, int minimum, int maximum) =>
      math.max(minimum, math.min(maximum, value));
}

abstract final class RemoteInputWorkspaceMagnetizer {
  static const int minimumSharedEdge = 96;

  static Map<String, RemoteInputWorkspaceNode> connectAll({
    required RemoteInputWorkspaceNode root,
    required Iterable<RemoteInputWorkspaceNode> nodes,
    double canvasScale = 1,
    String preferredPeerId = '',
  }) {
    final pending = <String, RemoteInputWorkspaceNode>{
      for (final node in nodes.where(
        (node) =>
            node.peerId.isNotEmpty &&
            node.peerId != root.peerId &&
            node.topology.isNotEmpty,
      ))
        node.peerId: node,
    };
    final placed = <String, RemoteInputWorkspaceNode>{root.peerId: root};

    void preserveConnectedNodes() {
      var changed = true;
      while (changed) {
        changed = false;
        for (final peerId in pending.keys.toList()..sort()) {
          final node = pending[peerId]!;
          final graph = RemoteInputWorkspaceGraph.build(
            <RemoteInputWorkspaceNode>[...placed.values, node],
          );
          final touchesPlaced = graph.routes.any(
            (route) =>
                route.sourcePeerId == node.peerId &&
                placed.containsKey(route.sinkPeerId) &&
                _hasUsableContact(route, graph),
          );
          if (graph.conflictingPeerIds.isNotEmpty || !touchesPlaced) {
            continue;
          }
          placed[peerId] = node;
          pending.remove(peerId);
          changed = true;
        }
      }
    }

    preserveConnectedNodes();
    while (pending.isNotEmpty) {
      final candidates =
          preferredPeerId.isNotEmpty && pending.containsKey(preferredPeerId)
          ? <RemoteInputWorkspaceNode>[pending[preferredPeerId]!]
          : (pending.values.toList()
              ..sort((left, right) => left.peerId.compareTo(right.peerId)));
      RemoteInputWorkspaceSnapResult? best;
      String bestPeerId = '';
      for (final moving in candidates) {
        final candidate = RemoteInputWorkspaceSnapper.snap(
          moving: moving,
          anchors: placed.values,
          canvasScale: canvasScale,
          threshold: double.infinity,
          minimumSharedEdge: minimumSharedEdge,
        );
        if (candidate == null) {
          continue;
        }
        if (best == null ||
            candidate.distanceInCanvas < best.distanceInCanvas ||
            (candidate.distanceInCanvas == best.distanceInCanvas &&
                moving.peerId.compareTo(bestPeerId) < 0)) {
          best = candidate;
          bestPeerId = moving.peerId;
        }
      }

      final fallbackPeerId =
          preferredPeerId.isNotEmpty && pending.containsKey(preferredPeerId)
          ? preferredPeerId
          : (pending.keys.toList()..sort()).first;
      final peerId = bestPeerId.isNotEmpty ? bestPeerId : fallbackPeerId;
      final connectedNode =
          best?.node ??
          _attachOutsideRight(moving: pending[peerId]!, anchors: placed.values);
      placed[peerId] = connectedNode;
      pending.remove(peerId);
      preserveConnectedNodes();
    }

    return Map<String, RemoteInputWorkspaceNode>.unmodifiable(placed);
  }

  static bool _hasUsableContact(
    RemoteInputWorkspaceRoute route,
    RemoteInputWorkspaceGraph graph,
  ) {
    RemoteInputDisplay? displayFor(String peerId, String displayId) {
      for (final display
          in graph.nodes[peerId]?.placedDisplays ??
              const <RemoteInputDisplay>[]) {
        if (display.displayId == displayId) {
          return display;
        }
      }
      return null;
    }

    final source = displayFor(
      route.sourcePeerId,
      route.mapping.sourceDisplayId,
    );
    final sink = displayFor(route.sinkPeerId, route.mapping.sinkDisplayId);
    if (source == null || sink == null) {
      return false;
    }
    final vertical =
        route.mapping.sourceEdge == RemoteInputEdge.left ||
        route.mapping.sourceEdge == RemoteInputEdge.right;
    final available = vertical
        ? math.min(source.height, sink.height)
        : math.min(source.width, sink.width);
    final required = math.min(minimumSharedEdge, available);
    return route.mapping.sourceSegmentEnd - route.mapping.sourceSegmentStart >=
        required;
  }

  static RemoteInputWorkspaceNode _attachOutsideRight({
    required RemoteInputWorkspaceNode moving,
    required Iterable<RemoteInputWorkspaceNode> anchors,
  }) {
    final anchorDisplays =
        anchors.expand((node) => node.placedDisplays).toList(growable: false)
          ..sort((left, right) {
            final edge = right.right.compareTo(left.right);
            return edge != 0 ? edge : left.displayId.compareTo(right.displayId);
          });
    final movingDisplays = moving.placedDisplays.toList(growable: false)
      ..sort((left, right) {
        final edge = left.left.compareTo(right.left);
        return edge != 0 ? edge : left.displayId.compareTo(right.displayId);
      });
    final anchor = anchorDisplays.first;
    final movingDisplay = movingDisplays.first;
    return moving.translated(
      dx: anchor.right - movingDisplay.left,
      dy: anchor.top - movingDisplay.top,
    );
  }
}

class _SnapCandidate {
  const _SnapCandidate({required this.result, required this.tieBreak});

  final RemoteInputWorkspaceSnapResult result;
  final String tieBreak;

  bool isBetterThan(_SnapCandidate other) {
    final distance = result.distanceInCanvas.compareTo(
      other.result.distanceInCanvas,
    );
    return distance < 0 ||
        (distance == 0 && tieBreak.compareTo(other.tieBreak) < 0);
  }
}
