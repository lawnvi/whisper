import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/theme/app_theme.dart';

class RemoteInputLayoutEditorScreen extends StatefulWidget {
  const RemoteInputLayoutEditorScreen({
    super.key,
    required this.initialLayout,
    required this.peerName,
    this.remoteTopology,
  });

  final RemoteInputLayoutData initialLayout;
  final String peerName;
  final RemoteInputTopology? remoteTopology;

  @override
  State<RemoteInputLayoutEditorScreen> createState() =>
      _RemoteInputLayoutEditorScreenState();
}

class _RemoteInputLayoutEditorScreenState
    extends State<RemoteInputLayoutEditorScreen> {
  late RemoteInputTopology _localTopology;
  late RemoteInputTopology _remoteTopology;
  late int _sinkOffsetX;
  late int _sinkOffsetY;

  @override
  void initState() {
    super.initState();
    _localTopology = RemoteInputTopology.fallback();
    _remoteTopology = widget.remoteTopology ??
        RemoteInputTopology.fallback(
          width: widget.initialLayout.width,
          height: widget.initialLayout.height,
        );
    final saved = widget.initialLayout.savedLayout;
    final remotePrimary = _remoteTopology.primaryDisplay;
    _sinkOffsetX =
        saved?.sinkOffsetX ?? widget.initialLayout.x - remotePrimary.x;
    _sinkOffsetY =
        saved?.sinkOffsetY ?? widget.initialLayout.y - remotePrimary.y;
    _loadLocalTopology();
  }

  Future<void> _loadLocalTopology() async {
    try {
      final topology = await RemoteInputCoordinator.shared.displayTopology();
      if (!mounted) {
        return;
      }
      setState(() {
        _localTopology =
            topology.isNotEmpty ? topology : RemoteInputTopology.fallback();
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    final connection = _currentConnection();
    final edge = connection?.segment.sourceEdge;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        leading: CupertinoNavigationBarBackButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          color: colorScheme.primary,
        ),
        title: Text(
          l10n.remoteInputLayoutTitle,
          style: TextStyle(color: colorScheme.onSurface),
        ),
        actions: [
          IconButton(
            tooltip: l10n.remoteInputLayoutSave,
            onPressed: connection == null ? null : () => _save(connection),
            icon: const Icon(Icons.check_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: _buildCanvas(context),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                border: Border(
                  top: BorderSide(color: palette.borderSubtle),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.remoteInputCurrentEdge(_edgeLabel(l10n, edge)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    _EdgeIconButton(
                      icon: Icons.align_horizontal_left_rounded,
                      tooltip: l10n.remoteInputSnapLeft,
                      selected: edge == RemoteInputEdge.left,
                      onPressed: () => _snapTo(RemoteInputEdge.left),
                    ),
                    _EdgeIconButton(
                      icon: Icons.align_horizontal_right_rounded,
                      tooltip: l10n.remoteInputSnapRight,
                      selected: edge == RemoteInputEdge.right,
                      onPressed: () => _snapTo(RemoteInputEdge.right),
                    ),
                    _EdgeIconButton(
                      icon: Icons.vertical_align_top_rounded,
                      tooltip: l10n.remoteInputSnapTop,
                      selected: edge == RemoteInputEdge.top,
                      onPressed: () => _snapTo(RemoteInputEdge.top),
                    ),
                    _EdgeIconButton(
                      icon: Icons.vertical_align_bottom_rounded,
                      tooltip: l10n.remoteInputSnapBottom,
                      selected: edge == RemoteInputEdge.bottom,
                      onPressed: () => _snapTo(RemoteInputEdge.bottom),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCanvas(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.maxWidth,
          math.max(280.0, constraints.maxHeight),
        );
        final transform = _ArrangementTransform.forScreens(
          size: size,
          screens: [
            ..._localTopology.displays.map((display) => display.rect),
            ..._translatedRemoteDisplays().map((display) => display.rect),
          ],
        );

        return DecoratedBox(
          decoration: BoxDecoration(
            color: palette.surfaceCanvas,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.borderSubtle),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _ArrangementGridPainter(
                      color: palette.borderSubtle,
                    ),
                  ),
                ),
                for (final display in _localTopology.displays)
                  Positioned.fromRect(
                    rect: transform.toCanvasRect(display.rect),
                    child: _ScreenRectView(
                      label: display.name.isEmpty
                          ? l10n.remoteInputLocalScreen
                          : display.name,
                      color: colorScheme.primary.withValues(alpha: 0.12),
                      borderColor: colorScheme.primary,
                      textColor: colorScheme.onSurface,
                    ),
                  ),
                for (final display in _translatedRemoteDisplays())
                  Positioned.fromRect(
                    rect: transform.toCanvasRect(display.rect),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.move,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (details) {
                          setState(() {
                            _sinkOffsetX +=
                                (details.delta.dx / transform.scale).round();
                            _sinkOffsetY +=
                                (details.delta.dy / transform.scale).round();
                          });
                        },
                        onPanEnd: (_) => _snapToNearestEdge(),
                        child: _ScreenRectView(
                          label: display.name.isEmpty
                              ? widget.peerName.isEmpty
                                  ? l10n.remoteInputPeerScreen
                                  : widget.peerName
                              : display.name,
                          color: palette.trusted.withValues(alpha: 0.14),
                          borderColor: palette.trusted,
                          textColor: colorScheme.onSurface,
                          selected: true,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _snapTo(RemoteInputEdge edge) {
    final source = _localTopology.primaryDisplay;
    final sink = _remoteTopology.primaryDisplay;
    setState(() {
      switch (edge) {
        case RemoteInputEdge.left:
          _sinkOffsetX = source.left - sink.right;
          _sinkOffsetY = source.top - sink.top;
          break;
        case RemoteInputEdge.right:
          _sinkOffsetX = source.right - sink.left;
          _sinkOffsetY = source.top - sink.top;
          break;
        case RemoteInputEdge.top:
          _sinkOffsetX = source.left - sink.left;
          _sinkOffsetY = source.top - sink.bottom;
          break;
        case RemoteInputEdge.bottom:
          _sinkOffsetX = source.left - sink.left;
          _sinkOffsetY = source.bottom - sink.top;
          break;
      }
    });
  }

  void _snapToNearestEdge() {
    _SnapCandidate? best;
    final remoteDisplays = _translatedRemoteDisplays();
    for (final source in _localTopology.displays) {
      for (var i = 0; i < remoteDisplays.length; i++) {
        final sink = remoteDisplays[i];
        final originalSink = _remoteTopology.displays[i];
        for (final edge in RemoteInputEdge.values) {
          final sinkEdge = _oppositeEdge(edge);
          if (!_isOuterEdge(source, edge, _localTopology.displays) ||
              !_isOuterEdge(sink, sinkEdge, remoteDisplays)) {
            continue;
          }
          final candidate = _snapCandidateFor(
            source: source,
            sink: sink,
            originalSink: originalSink,
            edge: edge,
          );
          if (best == null || candidate.score < best.score) {
            best = candidate;
          }
        }
      }
    }
    if (best == null) {
      return;
    }
    final winner = best;
    setState(() {
      _sinkOffsetX = winner.offsetX;
      _sinkOffsetY = winner.offsetY;
    });
  }

  _SnapCandidate _snapCandidateFor({
    required RemoteInputDisplay source,
    required RemoteInputDisplay sink,
    required RemoteInputDisplay originalSink,
    required RemoteInputEdge edge,
  }) {
    var offsetX = _sinkOffsetX;
    var offsetY = _sinkOffsetY;
    switch (edge) {
      case RemoteInputEdge.left:
        offsetX = source.left - originalSink.right;
        offsetY = _clampInt(
              sink.top,
              source.top - sink.height + 1,
              source.bottom - 1,
            ) -
            originalSink.top;
        break;
      case RemoteInputEdge.right:
        offsetX = source.right - originalSink.left;
        offsetY = _clampInt(
              sink.top,
              source.top - sink.height + 1,
              source.bottom - 1,
            ) -
            originalSink.top;
        break;
      case RemoteInputEdge.top:
        offsetX = _clampInt(
              sink.left,
              source.left - sink.width + 1,
              source.right - 1,
            ) -
            originalSink.left;
        offsetY = source.top - originalSink.bottom;
        break;
      case RemoteInputEdge.bottom:
        offsetX = _clampInt(
              sink.left,
              source.left - sink.width + 1,
              source.right - 1,
            ) -
            originalSink.left;
        offsetY = source.bottom - originalSink.top;
        break;
    }
    final dx = offsetX - _sinkOffsetX;
    final dy = offsetY - _sinkOffsetY;
    return _SnapCandidate(
      offsetX: offsetX,
      offsetY: offsetY,
      score: dx * dx + dy * dy,
    );
  }

  int _clampInt(int value, int minimum, int maximum) {
    if (value < minimum) {
      return minimum;
    }
    if (value > maximum) {
      return maximum;
    }
    return value;
  }

  List<RemoteInputDisplay> _translatedRemoteDisplays() {
    return _remoteTopology.displays
        .map(
          (display) => display.translated(
            dx: _sinkOffsetX,
            dy: _sinkOffsetY,
          ),
        )
        .toList(growable: false);
  }

  _LayoutConnection? _currentConnection() {
    _LayoutConnection? best;
    final remoteDisplays = _translatedRemoteDisplays();
    for (final source in _localTopology.displays) {
      for (var i = 0; i < remoteDisplays.length; i++) {
        final sink = remoteDisplays[i];
        final originalSink = _remoteTopology.displays[i];
        for (final edge in RemoteInputEdge.values) {
          final sinkEdge = _oppositeEdge(edge);
          if (!_isOuterEdge(source, edge, _localTopology.displays) ||
              !_isOuterEdge(sink, sinkEdge, remoteDisplays)) {
            continue;
          }
          final segment = RemoteInputLayoutGeometry.sharedEdgeSegment(
            source: source,
            sourceEdge: edge,
            sinkInLayout: sink,
            sinkEdge: sinkEdge,
          );
          if (segment == null) {
            continue;
          }
          final candidate = _LayoutConnection(
            source: source,
            sink: originalSink,
            sinkInLayout: sink,
            segment: segment,
          );
          if (best == null || candidate.segment.length > best.segment.length) {
            best = candidate;
          }
        }
      }
    }
    return best;
  }

  bool _isOuterEdge(
    RemoteInputDisplay display,
    RemoteInputEdge edge,
    List<RemoteInputDisplay> displays,
  ) {
    for (final other in displays) {
      if (other.displayId == display.displayId) {
        continue;
      }
      final segment = RemoteInputLayoutGeometry.sharedEdgeSegment(
        source: display,
        sourceEdge: edge,
        sinkInLayout: other,
        sinkEdge: _oppositeEdge(edge),
      );
      if (segment != null) {
        return false;
      }
    }
    return true;
  }

  RemoteInputEdge _oppositeEdge(RemoteInputEdge edge) {
    switch (edge) {
      case RemoteInputEdge.left:
        return RemoteInputEdge.right;
      case RemoteInputEdge.right:
        return RemoteInputEdge.left;
      case RemoteInputEdge.top:
        return RemoteInputEdge.bottom;
      case RemoteInputEdge.bottom:
        return RemoteInputEdge.top;
    }
  }

  void _save(_LayoutConnection connection) {
    final segment = connection.segment;
    final saved = RemoteInputSavedLayout(
      sourceDisplayId: connection.source.displayId,
      sinkDisplayId: connection.sink.displayId,
      sourceEdge: segment.sourceEdge,
      sinkEdge: segment.sinkEdge,
      sinkOffsetX: _sinkOffsetX,
      sinkOffsetY: _sinkOffsetY,
      sharedSegmentStart: segment.start,
      sharedSegmentEnd: segment.end,
    );
    Navigator.of(context).pop(
      widget.initialLayout.copyWith(
        x: connection.sinkInLayout.x,
        y: connection.sinkInLayout.y,
        width: connection.sinkInLayout.width,
        height: connection.sinkInLayout.height,
        enabled: true,
        layoutVersion: 2,
        layoutJson: saved.toJsonString(),
      ),
    );
  }

  String _edgeLabel(AppLocalizations l10n, RemoteInputEdge? edge) {
    switch (edge) {
      case RemoteInputEdge.left:
        return l10n.remoteInputEdgeLeft;
      case RemoteInputEdge.right:
        return l10n.remoteInputEdgeRight;
      case RemoteInputEdge.top:
        return l10n.remoteInputEdgeTop;
      case RemoteInputEdge.bottom:
        return l10n.remoteInputEdgeBottom;
      case null:
        return l10n.remoteInputEdgeNotAdjacent;
    }
  }
}

class _ArrangementTransform {
  const _ArrangementTransform({
    required this.scale,
    required this.offset,
  });

  final double scale;
  final Offset offset;

  factory _ArrangementTransform.forScreens({
    required Size size,
    required List<RemoteInputScreenRect> screens,
  }) {
    const padding = 28.0;
    final safeScreens = screens.isEmpty
        ? const [RemoteInputScreenRect(x: 0, y: 0, width: 1000, height: 800)]
        : screens;
    var left = safeScreens.first.left.toDouble();
    var top = safeScreens.first.top.toDouble();
    var right = safeScreens.first.right.toDouble();
    var bottom = safeScreens.first.bottom.toDouble();
    for (final screen in safeScreens.skip(1)) {
      left = math.min(left, screen.left.toDouble());
      top = math.min(top, screen.top.toDouble());
      right = math.max(right, screen.right.toDouble());
      bottom = math.max(bottom, screen.bottom.toDouble());
    }
    left -= 160;
    top -= 160;
    right += 160;
    bottom += 160;
    final worldWidth = right - left;
    final worldHeight = bottom - top;
    final widthScale = (size.width - padding * 2) / worldWidth;
    final heightScale = (size.height - padding * 2) / worldHeight;
    final scale = math.max(0.08, math.min(widthScale, heightScale));
    final renderedWidth = worldWidth * scale;
    final renderedHeight = worldHeight * scale;
    final offset = Offset(
      (size.width - renderedWidth) / 2 - left * scale,
      (size.height - renderedHeight) / 2 - top * scale,
    );
    return _ArrangementTransform(scale: scale, offset: offset);
  }

  Rect toCanvasRect(RemoteInputScreenRect screen) {
    return Rect.fromLTWH(
      offset.dx + screen.x * scale,
      offset.dy + screen.y * scale,
      screen.width * scale,
      screen.height * scale,
    );
  }
}

class _LayoutConnection {
  const _LayoutConnection({
    required this.source,
    required this.sink,
    required this.sinkInLayout,
    required this.segment,
  });

  final RemoteInputDisplay source;
  final RemoteInputDisplay sink;
  final RemoteInputDisplay sinkInLayout;
  final RemoteInputSharedEdgeSegment segment;
}

class _SnapCandidate {
  const _SnapCandidate({
    required this.offsetX,
    required this.offsetY,
    required this.score,
  });

  final int offsetX;
  final int offsetY;
  final int score;
}

class _ScreenRectView extends StatelessWidget {
  const _ScreenRectView({
    required this.label,
    required this.color,
    required this.borderColor,
    required this.textColor,
    this.selected = false,
  });

  final String label;
  final Color color;
  final Color borderColor;
  final Color textColor;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: borderColor,
          width: selected ? 2 : 1.4,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: borderColor.withValues(alpha: 0.18),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}

class _EdgeIconButton extends StatelessWidget {
  const _EdgeIconButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
        color: selected ? colorScheme.primary : colorScheme.onSurface,
        style: IconButton.styleFrom(
          backgroundColor: selected
              ? colorScheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          fixedSize: const Size(40, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}

class _ArrangementGridPainter extends CustomPainter {
  const _ArrangementGridPainter({
    required this.color,
  });

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    const gap = 24.0;
    for (double x = gap; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = gap; y < size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ArrangementGridPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
