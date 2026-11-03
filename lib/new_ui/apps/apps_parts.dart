import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';
import 'package:whisper/window_stream/remote/window_stream_host.dart';

/// `repeat(auto-fill, minmax(minWidth, 1fr))`.
class ShellAutoGrid extends StatelessWidget {
  const ShellAutoGrid({
    super.key,
    required this.minWidth,
    required this.spacing,
    required this.runSpacing,
    required this.children,
  });

  final double minWidth, spacing, runSpacing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final count = ((box.maxWidth + spacing) / (minWidth + spacing))
          .floor()
          .clamp(1, 64);
      final width = (box.maxWidth - spacing * (count - 1)) / count;
      return Wrap(
        spacing: spacing,
        runSpacing: runSpacing,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

/// `.thumb-w`: a window's last picture, or its shape while there is none.
class ShellWindowThumb extends StatefulWidget {
  const ShellWindowThumb({
    super.key,
    required this.title,
    required this.onTap,
    this.picture,
    this.badge,
    this.closeLabel,
    this.onClose,
    this.touch = false,
    this.onLongPress,
    this.closing = false,
  });

  final String title;
  final Uint8List? picture;
  final String? badge;
  final ValueChanged<Rect> onTap;
  final String? closeLabel;
  final VoidCallback? onClose;

  /// On a phone: its text is larger and a finger lights the ring a pointer would.
  final bool touch;

  /// What a pointer has on hover, a finger has on a long press.
  final VoidCallback? onLongPress;

  /// Asked to close, and not gone yet.
  final bool closing;

  @override
  State<ShellWindowThumb> createState() => _ShellWindowThumbState();
}

class _ShellWindowThumbState extends State<ShellWindowThumb> {
  bool _hover = false;
  bool _down = false;

  Rect _rect() {
    final box = context.findRenderObject() as RenderBox?;
    return box == null || !box.hasSize
        ? Rect.zero
        : box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: widget.touch);
    final picture = widget.picture;
    final brightness = Theme.of(context).brightness;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.touch ? (_) => setState(() => _down = true) : null,
        onTapCancel: widget.touch ? () => setState(() => _down = false) : null,
        onTapUp: widget.touch ? (_) => setState(() => _down = false) : null,
        onTap: () => widget.onTap(_rect()),
        onLongPress: widget.onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 96,
              clipBehavior: Clip.antiAlias,
              foregroundDecoration: widget.closing
                  ? BoxDecoration(color: c.content.withValues(alpha: .5))
                  : null,
              decoration: BoxDecoration(
                color: c.canvas,
                borderRadius: BorderRadius.circular(WhisperRadius.s),
                boxShadow: [
                  if (_hover || _down)
                    BoxShadow(color: c.accent, spreadRadius: 3)
                  else
                    ...WhisperShadow.e1(brightness),
                ],
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (picture != null)
                    Image.memory(
                      picture,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FractionallySizedBox(
                            widthFactor: .46,
                            child: _Bar(color: c.ink3),
                          ),
                          const SizedBox(height: 6),
                          _Bar(color: c.fill2),
                          const SizedBox(height: 6),
                          FractionallySizedBox(
                            widthFactor: .7,
                            child: _Bar(color: c.fill2),
                          ),
                        ],
                      ),
                    ),
                  if (_hover && widget.onClose != null)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: ShellIconButton(
                        glyph: WhisperGlyph.x,
                        iconSize: 12,
                        weight: 2,
                        label: widget.closeLabel ?? '',
                        onTap: widget.onClose,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 7, 2, 0),
              child: Text(
                widget.badge == null
                    ? widget.title
                    : '${widget.title} · ${widget.badge}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: type.tiny,
                  height: 1.4,
                  color: c.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    height: 6,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(WhisperRadius.thumbBar),
    ),
  );
}

/// `.appi`: 50 with corners of 12, a top highlight, the name under it.
class ShellAppIcon extends StatelessWidget {
  const ShellAppIcon({
    super.key,
    required this.label,
    required this.hue,
    required this.onTap,
    this.icon,
    this.busy = false,
    this.touch = false,
    this.running = false,
    this.openHere = false,
  });

  final String label;
  final Color hue;
  final Uint8List? icon;
  final bool busy;
  final VoidCallback onTap;
  final bool touch;

  /// Has a window over there, and that window is open here. Both are a dot under
  /// the name.
  final bool running, openHere;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: touch);
    return Pressable(
      onTap: busy ? null : onTap,
      radius: WhisperRadius.s,
      label: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        child: Column(
          children: [
            Container(
              width: 50,
              height: 50,
              clipBehavior: Clip.antiAlias,
              foregroundDecoration: const _TopHighlight(),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(WhisperRadius.appIcon),
                gradient: icon != null
                    ? null
                    : LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color.lerp(hue, Colors.white, .12)!,
                          Color.lerp(hue, Colors.black, .12)!,
                        ],
                      ),
                boxShadow: WhisperShadow.appIcon,
              ),
              child: busy
                  ? const Center(child: CupertinoActivityIndicator())
                  : icon != null
                  ? Image.memory(
                      icon!,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    )
                  : Center(
                      child: Text(
                        label.isEmpty ? '' : label.characters.first,
                        style: const TextStyle(
                          fontSize: WhisperSizes.appIconLetter,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: type.tiny, height: 1.3, color: c.ink),
            ),
            if (running || openHere)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Container(
                  key: const ValueKey('app-running-dot'),
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: openHere ? c.accentText : c.ink3,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// `inset 0 .5px 0`: the hairline along the top of an app's icon, following its
/// corners.
class _TopHighlight extends Decoration {
  const _TopHighlight();

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _TopHighlightPainter();
}

class _TopHighlightPainter extends BoxPainter {
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(rect.left, rect.top, rect.width, WhisperRadius.appIcon / 2),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.deflate(.25),
        const Radius.circular(WhisperRadius.appIcon),
      ),
      Paint()
        ..color = WhisperShadow.appIconHighlight
        ..style = PaintingStyle.stroke
        ..strokeWidth = .5,
    );
    canvas.restore();
  }
}

/// 送到 ‹设备›: this desktop's windows, each flying over when clicked.
class ShellSendWindows extends StatefulWidget {
  const ShellSendWindows({
    super.key,
    required this.deviceName,
    required this.available,
    required this.onSend,
    this.touch = false,
  });

  final String deviceName;
  final bool available, touch;
  final void Function(RemoteWindowInfo window, Rect from, Uint8List? picture)
  onSend;

  @override
  State<ShellSendWindows> createState() => _ShellSendWindowsState();
}

class _ShellSendWindowsState extends State<ShellSendWindows> {
  WindowStreamHost get _host => WindowStreamHost.shared;
  List<RemoteWindowInfo>? _windows;
  final _pictures = <int, Uint8List>{};
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    // Window lists change while this is open; reading them captures nothing.
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final windows = await _host.localWindows();
    if (!mounted) return;
    setState(() => _windows = windows);
    // Pictures are screen captures: one at a time, front windows first.
    for (final window in windows.take(12)) {
      if (_pictures.containsKey(window.id) || !mounted) continue;
      final jpeg = await _host.localThumbnail(window.id, maxEdge: 480);
      if (jpeg != null && mounted) {
        setState(() => _pictures[window.id] = jpeg);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = AppLocalizations.of(context)!;
    final type = WhisperType(touch: widget.touch);
    final windows = _windows;
    if (!widget.available) {
      return Text(
        l10n.windowStreamSendUnavailable(widget.deviceName),
        style: TextStyle(fontSize: type.note, color: c.ink2),
      );
    }
    if (windows == null) return const CupertinoActivityIndicator();
    if (windows.isEmpty) {
      return Text(
        l10n.windowStreamNoLocalWindows,
        style: TextStyle(fontSize: type.note, color: c.ink2),
      );
    }
    return ShellAutoGrid(
      minWidth: 160,
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final window in windows)
          ShellWindowThumb(
            touch: widget.touch,
            title: window.title.isEmpty ? window.appName : window.title,
            picture: _pictures[window.id],
            onTap: (from) => widget.onSend(window, from, _pictures[window.id]),
          ),
      ],
    );
  }
}
