import 'dart:convert';
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
  IntColumn get layoutVersion =>
      integer().named('layout_version').withDefault(const Constant(1))();
  TextColumn get layoutJson =>
      text().named('layout_json').withDefault(const Constant(''))();
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

class RemoteInputDisplay {
  const RemoteInputDisplay({
    required this.displayId,
    required this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.scale,
    required this.isPrimary,
  });

  final String displayId;
  final String name;
  final int x;
  final int y;
  final int width;
  final int height;
  final double scale;
  final bool isPrimary;

  int get left => x;
  int get right => x + width;
  int get top => y;
  int get bottom => y + height;

  RemoteInputScreenRect get rect => RemoteInputScreenRect(
        x: x,
        y: y,
        width: width,
        height: height,
      );

  RemoteInputDisplay translated({
    required int dx,
    required int dy,
  }) {
    return RemoteInputDisplay(
      displayId: displayId,
      name: name,
      x: x + dx,
      y: y + dy,
      width: width,
      height: height,
      scale: scale,
      isPrimary: isPrimary,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'displayId': displayId,
        'name': name,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'scale': scale,
        'isPrimary': isPrimary,
      };

  factory RemoteInputDisplay.fromJson(Map<String, dynamic> json) {
    return RemoteInputDisplay(
      displayId: json['displayId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      x: _intJson(json['x']),
      y: _intJson(json['y']),
      width: math.max(1, _intJson(json['width'], fallback: 1)),
      height: math.max(1, _intJson(json['height'], fallback: 1)),
      scale: _doubleJson(json['scale'], fallback: 1),
      isPrimary: json['isPrimary'] as bool? ?? false,
    );
  }
}

class RemoteInputTopology {
  const RemoteInputTopology({
    required this.platform,
    required this.displays,
    required this.updatedAt,
  });

  final String platform;
  final List<RemoteInputDisplay> displays;
  final int updatedAt;

  bool get isEmpty => displays.isEmpty;
  bool get isNotEmpty => displays.isNotEmpty;

  RemoteInputDisplay get primaryDisplay {
    if (displays.isEmpty) {
      return RemoteInputTopology.fallback(platform: platform).primaryDisplay;
    }
    return displays.firstWhere(
      (display) => display.isPrimary,
      orElse: () => displays.first,
    );
  }

  RemoteInputScreenRect get virtualBounds {
    if (displays.isEmpty) {
      return const RemoteInputScreenRect(x: 0, y: 0, width: 1, height: 1);
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

  RemoteInputDisplay? displayById(String displayId) {
    for (final display in displays) {
      if (display.displayId == displayId) {
        return display;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'platform': platform,
        'displays': displays.map((display) => display.toJson()).toList(),
        'updatedAt': updatedAt,
      };

  factory RemoteInputTopology.fromJson(Map<String, dynamic> json) {
    return RemoteInputTopology(
      platform: json['platform'] as String? ?? '',
      displays: (json['displays'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) =>
              RemoteInputDisplay.fromJson(Map<String, dynamic>.from(item)))
          .where((display) => display.displayId.isNotEmpty)
          .toList(growable: false),
      updatedAt: _intJson(json['updatedAt']),
    );
  }

  factory RemoteInputTopology.fallback({
    String platform = '',
    int width = 1000,
    int height = 800,
  }) {
    return RemoteInputTopology(
      platform: platform,
      displays: [
        RemoteInputDisplay(
          displayId: 'primary',
          name: 'Primary',
          x: 0,
          y: 0,
          width: math.max(1, width),
          height: math.max(1, height),
          scale: 1,
          isPrimary: true,
        ),
      ],
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class RemoteInputSharedEdgeSegment {
  const RemoteInputSharedEdgeSegment({
    required this.sourceDisplayId,
    required this.sinkDisplayId,
    required this.sourceEdge,
    required this.sinkEdge,
    required this.start,
    required this.end,
  });

  final String sourceDisplayId;
  final String sinkDisplayId;
  final RemoteInputEdge sourceEdge;
  final RemoteInputEdge sinkEdge;
  final int start;
  final int end;

  int get length => math.max(0, end - start);
  bool get isVertical =>
      sourceEdge == RemoteInputEdge.left || sourceEdge == RemoteInputEdge.right;
  bool get isHorizontal => !isVertical;
}

class RemoteInputSavedLayout {
  const RemoteInputSavedLayout({
    required this.sourceDisplayId,
    required this.sinkDisplayId,
    required this.sourceEdge,
    required this.sinkEdge,
    required this.sinkOffsetX,
    required this.sinkOffsetY,
    required this.sharedSegmentStart,
    required this.sharedSegmentEnd,
  });

  final String sourceDisplayId;
  final String sinkDisplayId;
  final RemoteInputEdge sourceEdge;
  final RemoteInputEdge sinkEdge;
  final int sinkOffsetX;
  final int sinkOffsetY;
  final int sharedSegmentStart;
  final int sharedSegmentEnd;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sourceDisplayId': sourceDisplayId,
        'sinkDisplayId': sinkDisplayId,
        'sourceEdge': sourceEdge.name,
        'sinkEdge': sinkEdge.name,
        'sinkOffsetX': sinkOffsetX,
        'sinkOffsetY': sinkOffsetY,
        'sharedSegmentStart': sharedSegmentStart,
        'sharedSegmentEnd': sharedSegmentEnd,
      };

  String toJsonString() => jsonEncode(toJson());

  factory RemoteInputSavedLayout.fromJson(Map<String, dynamic> json) {
    return RemoteInputSavedLayout(
      sourceDisplayId: json['sourceDisplayId'] as String? ?? '',
      sinkDisplayId: json['sinkDisplayId'] as String? ?? '',
      sourceEdge: _edgeJson(json['sourceEdge'], RemoteInputEdge.right),
      sinkEdge: _edgeJson(json['sinkEdge'], RemoteInputEdge.left),
      sinkOffsetX: _intJson(json['sinkOffsetX']),
      sinkOffsetY: _intJson(json['sinkOffsetY']),
      sharedSegmentStart: _intJson(json['sharedSegmentStart']),
      sharedSegmentEnd: _intJson(json['sharedSegmentEnd']),
    );
  }

  factory RemoteInputSavedLayout.fromJsonString(String value) {
    final decoded = jsonDecode(value);
    if (decoded is Map<String, dynamic>) {
      return RemoteInputSavedLayout.fromJson(decoded);
    }
    if (decoded is Map) {
      return RemoteInputSavedLayout.fromJson(
          Map<String, dynamic>.from(decoded));
    }
    throw const FormatException('remote input layout json must be an object');
  }
}

class RemoteInputResolvedLayout {
  const RemoteInputResolvedLayout({
    required this.savedLayout,
    required this.sourceDisplay,
    required this.sinkDisplay,
    required this.sinkDisplayInLayout,
    required this.sharedSegment,
    required this.sinkSegmentStart,
    required this.sinkSegmentEnd,
  });

  final RemoteInputSavedLayout savedLayout;
  final RemoteInputDisplay sourceDisplay;
  final RemoteInputDisplay sinkDisplay;
  final RemoteInputDisplay sinkDisplayInLayout;
  final RemoteInputSharedEdgeSegment sharedSegment;
  final int sinkSegmentStart;
  final int sinkSegmentEnd;
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

  static RemoteInputSharedEdgeSegment? sharedEdgeSegment({
    required RemoteInputDisplay source,
    required RemoteInputEdge sourceEdge,
    required RemoteInputDisplay sinkInLayout,
    required RemoteInputEdge sinkEdge,
  }) {
    if (!_areOppositeEdges(sourceEdge, sinkEdge)) {
      return null;
    }
    if (sourceEdge == RemoteInputEdge.right &&
        source.right != sinkInLayout.left) {
      return null;
    }
    if (sourceEdge == RemoteInputEdge.left &&
        source.left != sinkInLayout.right) {
      return null;
    }
    if (sourceEdge == RemoteInputEdge.bottom &&
        source.bottom != sinkInLayout.top) {
      return null;
    }
    if (sourceEdge == RemoteInputEdge.top &&
        source.top != sinkInLayout.bottom) {
      return null;
    }

    final isVertical = sourceEdge == RemoteInputEdge.left ||
        sourceEdge == RemoteInputEdge.right;
    final start = isVertical
        ? math.max(source.top, sinkInLayout.top)
        : math.max(source.left, sinkInLayout.left);
    final end = isVertical
        ? math.min(source.bottom, sinkInLayout.bottom)
        : math.min(source.right, sinkInLayout.right);
    if (end <= start) {
      return null;
    }
    return RemoteInputSharedEdgeSegment(
      sourceDisplayId: source.displayId,
      sinkDisplayId: sinkInLayout.displayId,
      sourceEdge: sourceEdge,
      sinkEdge: sinkEdge,
      start: start,
      end: end,
    );
  }

  static RemoteInputResolvedLayout? resolveSavedLayout({
    required RemoteInputSavedLayout savedLayout,
    required RemoteInputTopology sourceTopology,
    required RemoteInputTopology sinkTopology,
  }) {
    final sourceDisplay =
        sourceTopology.displayById(savedLayout.sourceDisplayId);
    final sinkDisplay = sinkTopology.displayById(savedLayout.sinkDisplayId);
    if (sourceDisplay == null || sinkDisplay == null) {
      return null;
    }
    final sinkInLayout = sinkDisplay.translated(
      dx: savedLayout.sinkOffsetX,
      dy: savedLayout.sinkOffsetY,
    );
    final segment = sharedEdgeSegment(
      source: sourceDisplay,
      sourceEdge: savedLayout.sourceEdge,
      sinkInLayout: sinkInLayout,
      sinkEdge: savedLayout.sinkEdge,
    );
    if (segment == null) {
      return null;
    }
    final isVertical = segment.isVertical;
    final sinkOffset =
        isVertical ? savedLayout.sinkOffsetY : savedLayout.sinkOffsetX;
    return RemoteInputResolvedLayout(
      savedLayout: savedLayout,
      sourceDisplay: sourceDisplay,
      sinkDisplay: sinkDisplay,
      sinkDisplayInLayout: sinkInLayout,
      sharedSegment: segment,
      sinkSegmentStart: segment.start - sinkOffset,
      sinkSegmentEnd: segment.end - sinkOffset,
    );
  }

  static double edgeUnitForCoordinate({
    required RemoteInputSharedEdgeSegment segment,
    required int coordinate,
  }) {
    if (coordinate <= segment.start) {
      return 0;
    }
    if (coordinate >= segment.end) {
      return 1;
    }
    return (coordinate - segment.start) / segment.length;
  }

  static int coordinateForEdgeUnit({
    required RemoteInputSharedEdgeSegment segment,
    required double edgeUnit,
  }) {
    final clamped = edgeUnit.clamp(0, 1).toDouble();
    return segment.start + (segment.length * clamped).round();
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

  static bool _areOppositeEdges(RemoteInputEdge a, RemoteInputEdge b) {
    return (a == RemoteInputEdge.left && b == RemoteInputEdge.right) ||
        (a == RemoteInputEdge.right && b == RemoteInputEdge.left) ||
        (a == RemoteInputEdge.top && b == RemoteInputEdge.bottom) ||
        (a == RemoteInputEdge.bottom && b == RemoteInputEdge.top);
  }
}

int _intJson(Object? value, {int fallback = 0}) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return fallback;
}

double _doubleJson(Object? value, {double fallback = 0}) {
  if (value is num) {
    return value.toDouble();
  }
  return fallback;
}

RemoteInputEdge _edgeJson(Object? value, RemoteInputEdge fallback) {
  final name = value as String?;
  for (final edge in RemoteInputEdge.values) {
    if (edge.name == name) {
      return edge;
    }
  }
  return fallback;
}
