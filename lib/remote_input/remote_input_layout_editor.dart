import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/theme/app_theme.dart';

class RemoteInputLayoutEditorScreen extends StatefulWidget {
  const RemoteInputLayoutEditorScreen({
    super.key,
    required this.initialLayout,
    required this.peerName,
  });

  final RemoteInputLayoutData initialLayout;
  final String peerName;

  @override
  State<RemoteInputLayoutEditorScreen> createState() =>
      _RemoteInputLayoutEditorScreenState();
}

class _RemoteInputLayoutEditorScreenState
    extends State<RemoteInputLayoutEditorScreen> {
  static const RemoteInputScreenRect _localScreen = RemoteInputScreenRect(
    x: 0,
    y: 0,
    width: 1000,
    height: 800,
  );

  late RemoteInputScreenRect _peerScreen;

  @override
  void initState() {
    super.initState();
    _peerScreen = RemoteInputScreenRect(
      x: widget.initialLayout.x,
      y: widget.initialLayout.y,
      width: widget.initialLayout.width,
      height: widget.initialLayout.height,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final edge = RemoteInputLayoutGeometry.adjacentEdge(
      local: _localScreen,
      peer: _peerScreen,
    );

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
          '屏幕排列',
          style: TextStyle(color: colorScheme.onSurface),
        ),
        actions: [
          IconButton(
            tooltip: '保存',
            onPressed: () {
              Navigator.of(context).pop(
                widget.initialLayout.copyWith(
                  x: _peerScreen.x,
                  y: _peerScreen.y,
                  width: _peerScreen.width,
                  height: _peerScreen.height,
                  enabled: true,
                ),
              );
            },
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
                        '当前：${_edgeLabel(edge)}',
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
                      tooltip: '贴左',
                      selected: edge == RemoteInputEdge.left,
                      onPressed: () => _snapTo(RemoteInputEdge.left),
                    ),
                    _EdgeIconButton(
                      icon: Icons.align_horizontal_right_rounded,
                      tooltip: '贴右',
                      selected: edge == RemoteInputEdge.right,
                      onPressed: () => _snapTo(RemoteInputEdge.right),
                    ),
                    _EdgeIconButton(
                      icon: Icons.vertical_align_top_rounded,
                      tooltip: '贴上',
                      selected: edge == RemoteInputEdge.top,
                      onPressed: () => _snapTo(RemoteInputEdge.top),
                    ),
                    _EdgeIconButton(
                      icon: Icons.vertical_align_bottom_rounded,
                      tooltip: '贴下',
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.maxWidth,
          math.max(280.0, constraints.maxHeight),
        );
        final transform = _ArrangementTransform.forScreens(
          size: size,
          local: _localScreen,
          peer: _peerScreen,
        );
        final localRect = transform.toCanvasRect(_localScreen);
        final peerRect = transform.toCanvasRect(_peerScreen);

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
                Positioned.fromRect(
                  rect: localRect,
                  child: _ScreenRectView(
                    label: '本机',
                    color: colorScheme.primary.withValues(alpha: 0.12),
                    borderColor: colorScheme.primary,
                    textColor: colorScheme.onSurface,
                  ),
                ),
                Positioned.fromRect(
                  rect: peerRect,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) {
                        setState(() {
                          _peerScreen = RemoteInputScreenRect(
                            x: _peerScreen.x +
                                (details.delta.dx / transform.scale).round(),
                            y: _peerScreen.y +
                                (details.delta.dy / transform.scale).round(),
                            width: _peerScreen.width,
                            height: _peerScreen.height,
                          );
                        });
                      },
                      onPanEnd: (_) {
                        setState(() {
                          _peerScreen =
                              RemoteInputLayoutGeometry.snapToNearestEdge(
                            local: _localScreen,
                            peer: _peerScreen,
                          );
                        });
                      },
                      child: _ScreenRectView(
                        label: widget.peerName.isEmpty ? '对端' : widget.peerName,
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
    setState(() {
      switch (edge) {
        case RemoteInputEdge.left:
          _peerScreen = RemoteInputScreenRect(
            x: _localScreen.left - _peerScreen.width,
            y: 0,
            width: _peerScreen.width,
            height: _peerScreen.height,
          );
          break;
        case RemoteInputEdge.right:
          _peerScreen = RemoteInputScreenRect(
            x: _localScreen.right,
            y: 0,
            width: _peerScreen.width,
            height: _peerScreen.height,
          );
          break;
        case RemoteInputEdge.top:
          _peerScreen = RemoteInputScreenRect(
            x: 0,
            y: _localScreen.top - _peerScreen.height,
            width: _peerScreen.width,
            height: _peerScreen.height,
          );
          break;
        case RemoteInputEdge.bottom:
          _peerScreen = RemoteInputScreenRect(
            x: 0,
            y: _localScreen.bottom,
            width: _peerScreen.width,
            height: _peerScreen.height,
          );
          break;
      }
    });
  }

  String _edgeLabel(RemoteInputEdge? edge) {
    switch (edge) {
      case RemoteInputEdge.left:
        return '左侧';
      case RemoteInputEdge.right:
        return '右侧';
      case RemoteInputEdge.top:
        return '上方';
      case RemoteInputEdge.bottom:
        return '下方';
      case null:
        return '未贴边';
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
    required RemoteInputScreenRect local,
    required RemoteInputScreenRect peer,
  }) {
    const padding = 28.0;
    final left = math.min(local.left, peer.left).toDouble() - 160;
    final top = math.min(local.top, peer.top).toDouble() - 160;
    final right = math.max(local.right, peer.right).toDouble() + 160;
    final bottom = math.max(local.bottom, peer.bottom).toDouble() + 160;
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
