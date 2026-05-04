import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

enum RemoteInputAutoRole {
  source,
  sink,
}

class RemoteInputLayout extends Table {
  TextColumn get peerId => text().named('peer_id')();
  TextColumn get peerName =>
      text().named('peer_name').withDefault(const Constant(''))();
  IntColumn get x => integer().withDefault(const Constant(1000))();
  IntColumn get y => integer().withDefault(const Constant(0))();
  IntColumn get width => integer().withDefault(const Constant(900))();
  IntColumn get height => integer().withDefault(const Constant(600))();
  BoolColumn get enabled => boolean().withDefault(const Constant(false))();
  BoolColumn get autoActivate =>
      boolean().named('auto_activate').withDefault(const Constant(false))();
  TextColumn get autoRole => text()
      .named('auto_role')
      .withDefault(Constant(RemoteInputAutoRole.source.name))();
  IntColumn get edgeThresholdPx =>
      integer().named('edge_threshold_px').withDefault(const Constant(6))();
  TextColumn get releaseHotkey => text()
      .named('release_hotkey')
      .withDefault(const Constant('ctrl+alt+esc'))();
  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column<Object>> get primaryKey => {peerId};
}

class RemoteInputScreenRect {
  const RemoteInputScreenRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;

  int get left => x;
  int get right => x + width;
  int get top => y;
  int get bottom => y + height;
}

class RemoteInputLayoutGeometry {
  const RemoteInputLayoutGeometry._();

  static RemoteInputScreenRect snapToNearestEdge({
    required RemoteInputScreenRect local,
    required RemoteInputScreenRect peer,
  }) {
    final candidates = <RemoteInputScreenRect>[
      RemoteInputScreenRect(
        x: local.right,
        y: _clampInt(peer.y, local.top - peer.height + 1, local.bottom - 1),
        width: peer.width,
        height: peer.height,
      ),
      RemoteInputScreenRect(
        x: local.left - peer.width,
        y: _clampInt(peer.y, local.top - peer.height + 1, local.bottom - 1),
        width: peer.width,
        height: peer.height,
      ),
      RemoteInputScreenRect(
        x: _clampInt(peer.x, local.left - peer.width + 1, local.right - 1),
        y: local.top - peer.height,
        width: peer.width,
        height: peer.height,
      ),
      RemoteInputScreenRect(
        x: _clampInt(peer.x, local.left - peer.width + 1, local.right - 1),
        y: local.bottom,
        width: peer.width,
        height: peer.height,
      ),
    ];
    candidates.sort((a, b) {
      final distanceA = _edgeDistance(local, peer, a);
      final distanceB = _edgeDistance(local, peer, b);
      return distanceA.compareTo(distanceB);
    });
    return candidates.first;
  }

  static RemoteInputEdge? adjacentEdge({
    required RemoteInputScreenRect local,
    required RemoteInputScreenRect peer,
  }) {
    if (local.right == peer.left && _verticalOverlap(local, peer) > 0) {
      return RemoteInputEdge.right;
    }
    if (local.left == peer.right && _verticalOverlap(local, peer) > 0) {
      return RemoteInputEdge.left;
    }
    if (local.top == peer.bottom && _horizontalOverlap(local, peer) > 0) {
      return RemoteInputEdge.top;
    }
    if (local.bottom == peer.top && _horizontalOverlap(local, peer) > 0) {
      return RemoteInputEdge.bottom;
    }
    return null;
  }

  static int _horizontalOverlap(
    RemoteInputScreenRect a,
    RemoteInputScreenRect b,
  ) {
    return math.min(a.right, b.right) - math.max(a.left, b.left);
  }

  static int _verticalOverlap(
    RemoteInputScreenRect a,
    RemoteInputScreenRect b,
  ) {
    return math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
  }

  static int _edgeDistance(
    RemoteInputScreenRect local,
    RemoteInputScreenRect original,
    RemoteInputScreenRect snapped,
  ) {
    if (snapped.left == local.right) {
      return (original.left - local.right).abs();
    }
    if (snapped.right == local.left) {
      return (original.right - local.left).abs();
    }
    if (snapped.bottom == local.top) {
      return (original.bottom - local.top).abs();
    }
    return (original.top - local.bottom).abs();
  }

  static int _clampInt(int value, int minimum, int maximum) {
    if (value < minimum) {
      return minimum;
    }
    if (value > maximum) {
      return maximum;
    }
    return value;
  }
}
