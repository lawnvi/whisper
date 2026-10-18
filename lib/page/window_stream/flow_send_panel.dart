import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show lerpDouble;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../window_stream/remote/window_stream_control.dart';
import '../../window_stream/remote/window_stream_host.dart';
import 'flow_app_icon.dart';
import 'flow_space_theme.dart';
import 'flow_space_widgets.dart';

/// "送到 ‹设备›": this desktop's windows, each one a card that flies over to
/// the device when tapped. The opposite of the device's own apps above it,
/// which open here.
class FlowSendPanel extends StatefulWidget {
  const FlowSendPanel({
    super.key,
    required this.deviceName,
    required this.available,
    required this.gutter,
    required this.onSend,
    WindowStreamHost? host,
  }) : _host = host;

  final String deviceName;

  /// The device is connected and can receive windows.
  final bool available;
  final double gutter;

  /// Called with the window, where its card is on screen and its picture.
  final void Function(RemoteWindowInfo window, Rect from, Uint8List? picture)
  onSend;
  final WindowStreamHost? _host;

  @override
  State<FlowSendPanel> createState() => _FlowSendPanelState();
}

class _FlowSendPanelState extends State<FlowSendPanel> {
  WindowStreamHost get _host => widget._host ?? WindowStreamHost.shared;
  List<RemoteWindowInfo>? _windows;
  final _pictures = <int, Uint8List>{};
  final _icons = <String, Uint8List>{};
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
    if (!mounted) {
      return;
    }
    setState(() => _windows = windows);
    for (final window in windows) {
      if (!_icons.containsKey(window.appId)) {
        unawaited(
          _host.localIcon(window.appId).then((png) {
            if (png != null && mounted) {
              setState(() => _icons[window.appId] = png);
            }
          }),
        );
      }
    }
    // Pictures are screen captures: one at a time, front windows first,
    // cached for minutes by the host.
    for (final window in windows.take(12)) {
      if (_pictures.containsKey(window.id) || !mounted) {
        continue;
      }
      final jpeg = await _host.localThumbnail(window.id, maxEdge: 480);
      if (jpeg != null && mounted) {
        setState(() => _pictures[window.id] = jpeg);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = FlowSpaceColors.of(context);
    final windows = _windows;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(widget.gutter, 18, widget.gutter, 4),
          sliver: SliverToBoxAdapter(
            child: FlowSectionHeader(
              title: l10n.windowStreamSendTo(widget.deviceName),
              count: windows?.length,
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(widget.gutter, 2, widget.gutter, 14),
          sliver: SliverToBoxAdapter(
            child: widget.available
                ? Text(
                    l10n.windowStreamSendHint(widget.deviceName),
                    style: TextStyle(
                      color: colors.secondaryLabel,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  )
                : FlowNotice(
                    icon: CupertinoIcons.info_circle_fill,
                    text: l10n.windowStreamSendUnavailable(widget.deviceName),
                  ),
          ),
        ),
        if (windows == null)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: CupertinoActivityIndicator(),
            ),
          )
        else if (windows.isEmpty)
          SliverToBoxAdapter(
            child: FlowEmptyState(
              icon: CupertinoIcons.macwindow,
              title: l10n.windowStreamNoLocalWindows,
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(widget.gutter, 4, widget.gutter, 32),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 260,
                mainAxisSpacing: 18,
                crossAxisSpacing: 18,
                childAspectRatio: 1.18,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final window = windows[index];
                return _SendCard(
                  window: window,
                  picture: _pictures[window.id],
                  icon: _icons[window.appId],
                  enabled: widget.available,
                  onTap: (rect) =>
                      widget.onSend(window, rect, _pictures[window.id]),
                );
              }, childCount: windows.length),
            ),
          ),
      ],
    );
  }
}

class _SendCard extends StatefulWidget {
  const _SendCard({
    required this.window,
    required this.picture,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final RemoteWindowInfo window;
  final Uint8List? picture;
  final Uint8List? icon;
  final bool enabled;
  final ValueChanged<Rect> onTap;

  @override
  State<_SendCard> createState() => _SendCardState();
}

class _SendCardState extends State<_SendCard> {
  bool _hovered = false;
  bool _pressed = false;

  Rect _rect() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return Rect.zero;
    }
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final brightness = Theme.of(context).brightness;
    final hue = flowAppHue(widget.window.appId, brightness);
    final reduceMotion = flowReduceMotion(context);
    final title = widget.window.title.isEmpty
        ? widget.window.appName
        : widget.window.title;
    final scale = _pressed ? 0.96 : (_hovered && widget.enabled ? 1.03 : 1.0);
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.enabled
            ? () {
                HapticFeedback.lightImpact();
                widget.onTap(_rect());
              }
            : null,
        child: AnimatedScale(
          duration: reduceMotion
              ? Duration.zero
              : FlowSpaceTokens.quickDuration,
          curve: const SpringCurve(FlowSpaceTokens.snappySpring, 0.3),
          scale: scale,
          child: AnimatedOpacity(
            duration: FlowSpaceTokens.quickDuration,
            opacity: widget.enabled ? 1 : 0.5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.circular(
                          FlowSpaceTokens.tileRadius,
                        ),
                        side: BorderSide(color: colors.hairline),
                      ),
                      color: colors.raised,
                      shadows: _hovered && widget.enabled
                          ? colors.liftedShadow(hue)
                          : colors.cardShadow,
                    ),
                    child: ClipPath(
                      clipper: ShapeBorderClipper(
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(
                            FlowSpaceTokens.tileRadius,
                          ),
                        ),
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (widget.picture != null)
                            Image.memory(
                              widget.picture!,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            )
                          else
                            DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [hue, hue.withValues(alpha: 0.55)],
                                ),
                              ),
                              child: Center(
                                child: FlowAppIcon(
                                  label: widget.window.appName,
                                  hue: hue,
                                  icon: widget.icon,
                                  size: 52,
                                  onColor: true,
                                ),
                              ),
                            ),
                          // Outward arrow: this one leaves this computer.
                          Positioned(
                            right: 8,
                            top: 8,
                            child: AnimatedOpacity(
                              duration: FlowSpaceTokens.quickDuration,
                              opacity: _hovered && widget.enabled ? 1 : 0,
                              child: FlowGlass(
                                radius: FlowSpaceTokens.capsuleRadius,
                                tint: Colors.black.withValues(alpha: 0.42),
                                padding: const EdgeInsets.all(6),
                                child: const Icon(
                                  CupertinoIcons.arrow_up_right,
                                  size: 14,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FlowAppIcon(
                      label: widget.window.appName,
                      hue: hue,
                      icon: widget.icon,
                      size: 20,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.label,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Flies a window's picture from [from] to [to] along an arc, shrinking
/// into the target, then completes. With reduced motion it only fades.
Future<void> flowFlyWindow(
  BuildContext context, {
  required Rect from,
  required Rect to,
  required Color hue,
  Uint8List? picture,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final done = Completer<void>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _FlyingWindow(
      from: from,
      to: to,
      hue: hue,
      picture: picture,
      reduceMotion: flowReduceMotion(context),
      onDone: () {
        entry.remove();
        if (!done.isCompleted) {
          done.complete();
        }
      },
    ),
  );
  overlay.insert(entry);
  return done.future;
}

class _FlyingWindow extends StatefulWidget {
  const _FlyingWindow({
    required this.from,
    required this.to,
    required this.hue,
    required this.picture,
    required this.reduceMotion,
    required this.onDone,
  });

  final Rect from;
  final Rect to;
  final Color hue;
  final Uint8List? picture;
  final bool reduceMotion;
  final VoidCallback onDone;

  @override
  State<_FlyingWindow> createState() => _FlyingWindowState();
}

class _FlyingWindowState extends State<_FlyingWindow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.reduceMotion ? 220 : 640),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = Curves.easeInOutCubic.transform(_controller.value);
          final from = widget.from;
          final to = widget.to;
          if (widget.reduceMotion) {
            return Positioned.fromRect(
              rect: from,
              child: Opacity(opacity: 1 - t, child: _card()),
            );
          }
          // Quadratic arc that rises above both ends before landing.
          final control = Offset(
            (from.center.dx + to.center.dx) / 2,
            (from.top < to.top ? from.top : to.top) - 90,
          );
          final a = Offset.lerp(from.center, control, t)!;
          final b = Offset.lerp(control, to.center, t)!;
          final center = Offset.lerp(a, b, t)!;
          final endScale = (to.height / from.height).clamp(0.12, 1.0) * 0.6;
          final scale = lerpDouble(1, endScale, t)!;
          final opacity = t < 0.8 ? 1.0 : 1 - (t - 0.8) / 0.2;
          return Positioned(
            left: center.dx - from.width / 2,
            top: center.dy - from.height / 2,
            width: from.width,
            height: from.height,
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.scale(scale: scale, child: _card()),
            ),
          );
        },
      ),
    );
  }

  Widget _card() {
    final picture = widget.picture;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(FlowSpaceTokens.tileRadius),
        ),
        color: widget.hue,
        shadows: [
          BoxShadow(
            color: widget.hue.withValues(alpha: 0.35),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: picture == null
          ? const SizedBox.expand()
          : ClipPath(
              clipper: ShapeBorderClipper(
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(
                    FlowSpaceTokens.tileRadius,
                  ),
                ),
              ),
              child: Image.memory(picture, fit: BoxFit.cover),
            ),
    );
  }
}
