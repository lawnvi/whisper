import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/input/input_controller.dart';
import 'package:whisper/new_ui/input/input_rules.dart';
import 'package:whisper/new_ui/share/share_parts.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/state/chat_session_list.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/island/island_home.dart';

const _canvasMinHeight = 240.0;
const _displayGap = 2.0;
const _statusMinHeight = 44.0;

/// docs/design/surfaces.md「键鼠」: screens arranged like the system's display
/// settings. Fills the area right of the sidebar, toolbar included.
class ShellInputPage extends StatefulWidget {
  const ShellInputPage({
    super.key,
    required this.rightInset,
    required this.selfDevice,
    required this.sessions,
    this.controller,
    this.titleKey,
    this.controlsKey,
  });

  /// Room for the window buttons, as on a device's page.
  final double rightInset;
  final DeviceData? selfDevice;

  /// Every device in the sidebar's order. Phones are left out here.
  final List<ChatSessionItem> sessions;
  final ShellInputController? controller;
  final GlobalKey? titleKey, controlsKey;

  @override
  State<ShellInputPage> createState() => _ShellInputPageState();
}

class _Drag {
  _Drag({
    required this.peerId,
    required this.fromCandidate,
    required this.grabX,
    required this.grabY,
    required this.x,
    required this.y,
  });

  final String peerId;
  final bool fromCandidate;

  /// Where in the screen it is held, in arrangement units.
  final double grabX, grabY;
  int x, y;
  math.Point<int>? snap;
  bool inside = false;
}

class _ShellInputPageState extends State<ShellInputPage>
    with WidgetsBindingObserver {
  late final ShellInputController _controller =
      widget.controller ?? ShellInputController.shared;
  final _canvasKey = GlobalKey();
  InputFit _fit = const InputFit(.08, 0, 0);
  _Drag? _drag;

  List<DeviceData> get _devices => [
    for (final session in widget.sessions) session.device,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.attach(devices: _devices, self: widget.selfDevice);
  }

  @override
  void didUpdateWidget(ShellInputPage old) {
    super.didUpdateWidget(old);
    if (!identical(old.sessions, widget.sessions) ||
        old.selfDevice != widget.selfDevice) {
      // Reporting what changed notifies listeners, which may be in this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _controller.updateDevices(devices: _devices, self: widget.selfDevice);
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.detach();
    super.dispose();
  }

  @override
  void didChangeMetrics() => unawaited(_controller.refreshLocalTopology());

  // ---- Dragging: a screen on the canvas, or a candidate coming in ----

  RenderBox? get _canvasBox =>
      _canvasKey.currentContext?.findRenderObject() as RenderBox?;

  Offset _toModel(Offset global) {
    final box = _canvasBox;
    final local = box?.globalToLocal(global) ?? Offset.zero;
    return Offset(
      (local.dx - _fit.dx) / _fit.scale,
      (local.dy - _fit.dy) / _fit.scale,
    );
  }

  void _startScreenDrag(InputScreen screen, Offset global) {
    final model = _toModel(global);
    setState(() {
      _drag = _Drag(
        peerId: screen.peerId,
        fromCandidate: false,
        grabX: model.dx - screen.bounds.x,
        grabY: model.dy - screen.bounds.y,
        x: screen.bounds.x,
        y: screen.bounds.y,
      );
      _updateDrag(global);
    });
  }

  void _startCandidateDrag(String peerId, Offset global) {
    final preview = _controller.previewScreen(peerId);
    if (preview == null) return;
    final model = _toModel(global);
    final grabX = preview.bounds.width / 2, grabY = preview.bounds.height / 2;
    setState(() {
      _drag = _Drag(
        peerId: peerId,
        fromCandidate: true,
        grabX: grabX,
        grabY: grabY,
        x: (model.dx - grabX).round(),
        y: (model.dy - grabY).round(),
      );
      _updateDrag(global);
    });
  }

  void _updateDrag(Offset global) {
    final drag = _drag;
    final box = _canvasBox;
    if (drag == null || box == null) return;
    final local = box.globalToLocal(global);
    final model = Offset(
      (local.dx - _fit.dx) / _fit.scale,
      (local.dy - _fit.dy) / _fit.scale,
    );
    drag.x = (model.dx - drag.grabX).round();
    drag.y = (model.dy - drag.grabY).round();
    drag.inside = (Offset.zero & box.size).contains(local);
    drag.snap = drag.inside
        ? _controller.snapFor(drag.peerId, drag.x, drag.y)
        : null;
  }

  void _endDrag() {
    final drag = _drag;
    if (drag == null) return;
    setState(() => _drag = null);
    final snap = drag.snap;
    if (drag.inside && snap != null) {
      unawaited(_controller.place(drag.peerId, snap.x, snap.y));
    } else if (!drag.fromCandidate) {
      // Dragged out of the canvas: it leaves.
      unawaited(_controller.remove(drag.peerId));
    }
  }

  void _cancelDrag() {
    if (_drag != null) setState(() => _drag = null);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    return IslandHome(
      home: IslandHomes.input,
      child: ColoredBox(
        color: c.canvas,
        child: Material(
          type: MaterialType.transparency,
          child: ShareEntrance(
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                final controlledBy = _controller.controlledBy;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ShareToolbar(
                      title: l10n.shellInput,
                      rightInset: widget.rightInset,
                      titleKey: widget.titleKey,
                      controlsKey: widget.controlsKey,
                      // The one being controlled cannot start anything.
                      trailing: controlledBy != null
                          ? null
                          : ShareSwitch(
                              label: l10n.inputSwitchLabel,
                              value: _controller.on,
                              onChanged: _controller.switchEnabled
                                  ? (on) => unawaited(_controller.setOn(on))
                                  : null,
                            ),
                    ),
                    Expanded(
                      child: controlledBy != null
                          ? _Controlled(
                              peerId: controlledBy,
                              sessions: widget.sessions,
                              controller: _controller,
                            )
                          : _arrangement(context),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _arrangement(BuildContext context) {
    final candidates = _controller.candidates;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: _canvasMinHeight),
                child: _canvas(context),
              ),
            ),
            if (candidates.isNotEmpty) ...[
              const SizedBox(height: 14),
              ConstrainedBox(
                // Two rows at most: the canvas keeps its room.
                constraints: const BoxConstraints(maxHeight: 76),
                child: SingleChildScrollView(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final candidate in candidates)
                          _CandidateChip(
                            key: ValueKey(candidate.device.uid),
                            candidate: candidate,
                            onAdd: () => unawaited(
                              _controller.add(candidate.device.uid),
                            ),
                            onDragStart: (global) => _startCandidateDrag(
                              candidate.device.uid,
                              global,
                            ),
                            onDragUpdate: (global) =>
                                setState(() => _updateDrag(global)),
                            onDragEnd: _endDrag,
                            onDragCancel: _cancelDrag,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            _Footer(controller: _controller),
          ],
        ),
      ),
    );
  }

  Widget _canvas(BuildContext context) {
    final screens = _controller.screens;
    var left = screens.first.bounds.left, top = screens.first.bounds.top;
    var right = screens.first.bounds.right;
    var bottom = screens.first.bounds.bottom;
    for (final screen in screens.skip(1)) {
      left = math.min(left, screen.bounds.left);
      top = math.min(top, screen.bounds.top);
      right = math.max(right, screen.bounds.right);
      bottom = math.max(bottom, screen.bounds.bottom);
    }
    return _CanvasFrame(
      key: _canvasKey,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (_controller.selected != null) _controller.select(null);
        },
        child: LayoutBuilder(
          builder: (context, constraints) => _smooth(
            left.toDouble(),
            (l) => _smooth(
              top.toDouble(),
              (t) => _smooth(
                right.toDouble(),
                (r) => _smooth(bottom.toDouble(), (b) {
                  // The canvas follows the window at once; only the screens
                  // being added or removed animate the scale.
                  final fit = InputFit.of(
                    left: l,
                    top: t,
                    right: r,
                    bottom: b,
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                  );
                  _fit = fit;
                  return _stack(fit, screens);
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _smooth(double value, Widget Function(double) child) => SpringBuilder(
    value: value,
    spring: WhisperSprings.smooth,
    builder: (context, v, _) => child(v),
  );

  Widget _stack(InputFit fit, List<InputScreen> screens) {
    final drag = _drag;
    final moving = drag == null
        ? null
        : drag.fromCandidate
        ? _controller.previewScreen(drag.peerId)
        : screens.where((s) => s.peerId == drag.peerId).firstOrNull;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final screen in screens)
          if (screen.peerId != moving?.peerId) _screen(fit, screen),
        if (drag != null && drag.snap != null && moving != null)
          _Ghost(
            rect: Rect.fromLTWH(
              fit.dx + drag.snap!.x * fit.scale,
              fit.dy + drag.snap!.y * fit.scale,
              moving.bounds.width * fit.scale,
              moving.bounds.height * fit.scale,
            ),
          ),
        if (moving != null) _screen(fit, moving, at: drag),
        if (_controller.on) _pointer(fit, screens),
      ],
    );
  }

  Widget _screen(InputFit fit, InputScreen screen, {_Drag? at}) {
    final held = at != null;
    final targetX = (at?.x ?? screen.bounds.x).toDouble();
    final targetY = (at?.y ?? screen.bounds.y).toDouble();
    final spring = held ? WhisperSprings.follow : WhisperSprings.snappy;
    return SpringBuilder(
      key: ValueKey('screen-${screen.peerId}'),
      value: targetX,
      spring: spring,
      builder: (context, x, _) => SpringBuilder(
        value: targetY,
        spring: spring,
        builder: (context, y, _) => Positioned(
          left: fit.dx + x * fit.scale,
          top: fit.dy + y * fit.scale,
          width: screen.bounds.width * fit.scale,
          height: screen.bounds.height * fit.scale,
          child: _ScreenBlock(
            screen: screen,
            scale: fit.scale,
            held: held,
            selected: _controller.selected == screen.peerId,
            selfName: _selfName,
            onTap: () =>
                _controller.select(screen.isSelf ? null : screen.peerId),
            onDragStart: screen.isSelf
                ? null
                : (global) => _startScreenDrag(screen, global),
            onDragUpdate: (global) => setState(() => _updateDrag(global)),
            onDragEnd: _endDrag,
            onDragCancel: _cancelDrag,
            onNudge: screen.isSelf
                ? null
                : (dx, dy) =>
                      unawaited(_controller.nudge(screen.peerId, dx, dy)),
          ),
        ),
      ),
    );
  }

  String get _selfName => widget.selfDevice?.name ?? '';

  Widget _pointer(InputFit fit, List<InputScreen> screens) {
    final peerId = _controller.pointerPeerId;
    final on = screens.where((s) => s.peerId == peerId).firstOrNull;
    final bounds = (on ?? screens.first).bounds;
    return SpringBuilder(
      key: const ValueKey('pointer'),
      value: bounds.x + bounds.width * .62,
      builder: (context, x, _) => SpringBuilder(
        value: bounds.y + bounds.height * .62,
        builder: (context, y, _) => Positioned(
          left: fit.dx + x * fit.scale,
          top: fit.dy + y * fit.scale,
          child: const IgnorePointer(child: _Arrow()),
        ),
      ),
    );
  }
}

/// `.kb-canvas`: a dip in the page, not a card. The shadow is on the inside.
class _CanvasFrame extends StatelessWidget {
  const _CanvasFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final radius = BorderRadius.circular(WhisperRadius.m);
    return Semantics(
      container: true,
      label: context.shellL10n.remoteInputWorkspaceCanvasTitle,
      child: ClipRRect(
        borderRadius: radius,
        child: CustomPaint(
          painter: _CanvasInset(
            fill: c.fill,
            line: c.sep,
            hairline: math.max(.5, 1 / MediaQuery.devicePixelRatioOf(context)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _CanvasInset extends CustomPainter {
  const _CanvasInset({
    required this.fill,
    required this.line,
    required this.hairline,
  });

  final Color fill, line;
  final double hairline;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(WhisperRadius.m),
    );
    canvas.drawRRect(shape, Paint()..color = fill);
    const inset = WhisperScreens.canvasInset;
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect.inflate(inset.blurRadius * 3))
      ..addRRect(shape);
    canvas.save();
    canvas.clipRRect(shape);
    canvas.translate(inset.offset.dx, inset.offset.dy);
    canvas.drawPath(outside, inset.toPaint());
    canvas.restore();
    canvas.drawRRect(
      shape.deflate(hairline / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = hairline
        ..color = line,
    );
  }

  @override
  bool shouldRepaint(_CanvasInset old) =>
      old.fill != fill || old.line != line || old.hairline != hairline;
}

/// `.kb-ghost`: where it will land.
class _Ghost extends StatelessWidget {
  const _Ghost({required this.rect});

  final Rect rect;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.accent.withValues(alpha: .22),
            borderRadius: BorderRadius.circular(WhisperRadius.xs),
            border: Border.all(
              color: c.accent,
              width: 1.5,
              strokeAlign: BorderSide.strokeAlignInside,
            ),
          ),
        ),
      ),
    );
  }
}

/// `CURSOR`: the real arrow, 15 × 21.
class _Arrow extends StatelessWidget {
  const _Arrow();

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(size: Size(15, 21), painter: _ArrowPainter());
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter();

  static final _path = Path()
    ..moveTo(1, 1)
    ..lineTo(1, 16.5)
    ..lineTo(4.8, 13.1)
    ..lineTo(7.5, 19.3)
    ..lineTo(10.2, 18.1)
    ..lineTo(7.5, 12)
    ..lineTo(12.7, 12)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    const shadow = WhisperScreens.pointerShadow;
    canvas.drawPath(
      _path.shift(shadow.offset),
      Paint()
        ..color = shadow.color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadow.blurSigma),
    );
    canvas.drawPath(_path, Paint()..color = WhisperScreens.pointerFill);
    canvas.drawPath(
      _path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeJoin = StrokeJoin.round
        ..color = WhisperScreens.pointerStroke,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => false;
}

/// `.scr`: one device's screens. Its label belongs to the whole device, so two
/// displays share one name across the gap.
class _ScreenBlock extends StatefulWidget {
  const _ScreenBlock({
    required this.screen,
    required this.scale,
    required this.held,
    required this.selected,
    required this.selfName,
    required this.onTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    required this.onNudge,
  });

  final InputScreen screen;
  final double scale;
  final bool held, selected;
  final String selfName;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd, onDragCancel;
  final void Function(int dx, int dy)? onNudge;

  @override
  State<_ScreenBlock> createState() => _ScreenBlockState();
}

class _ScreenBlockState extends State<_ScreenBlock> {
  final _focus = FocusNode(debugLabel: 'screen');
  bool _focused = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      widget.onTap();
      return KeyEventResult.handled;
    }
    final step = HardwareKeyboard.instance.isShiftPressed ? 400 : 100;
    final nudge = widget.onNudge;
    if (nudge == null) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowLeft) {
      nudge(-step, 0);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      nudge(step, 0);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      nudge(0, -step);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      nudge(0, step);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  String? _statusText(BuildContext context) {
    final l10n = context.shellL10n;
    return switch (widget.screen.status) {
      InputScreenStatus.none => null,
      InputScreenStatus.waiting => l10n.inputStatusWaiting,
      InputScreenStatus.notConnected => l10n.inputStatusNotConnected,
      InputScreenStatus.controlling => l10n.mobileControlActive,
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    final screen = widget.screen;
    final scale = widget.scale;
    final name = screen.isSelf
        ? (widget.selfName.isEmpty ? screen.name : widget.selfName)
        : screen.name;
    final height = screen.bounds.height * scale;
    final status = _statusText(context);
    final block = Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        SpringBuilder(
          value: widget.held ? 1 : 0,
          spring: WhisperSprings.snappy,
          animateWhenReduced: true,
          builder: (context, lifted, _) => Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              for (final display in screen.displays)
                _Display(
                  rect: _displayRect(display, screen.bounds, scale),
                  self: screen.isSelf,
                  selected: widget.selected,
                  lifted: lifted.clamp(0.0, 1.0),
                ),
            ],
          ),
        ),
        Center(
          child: IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: height < 20
                  ? null
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Label(
                          text: name,
                          size: const WhisperType(touch: false).note,
                          weight: FontWeight.w600,
                        ),
                        if (status != null && height >= _statusMinHeight)
                          Opacity(
                            opacity: .92,
                            child: _Label(
                              text: status,
                              size: const WhisperType(touch: false).tiny,
                              weight: FontWeight.w400,
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ),
        if (_focused && !widget.selected)
          Positioned(
            left: -3,
            top: -3,
            right: -3,
            bottom: -3,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(WhisperRadius.xs + 3),
                  border: Border.all(
                    color: c.accent.withValues(alpha: .45),
                    width: 3,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    final draggable = widget.onDragStart != null;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: l10n.inputScreenLabel(name, _resolutionText(context, screen)),
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        onFocusChange: (focused) => setState(
          () => _focused =
              focused &&
              FocusManager.instance.highlightMode ==
                  FocusHighlightMode.traditional,
        ),
        child: MouseRegion(
          cursor: !draggable
              ? SystemMouseCursors.basic
              : widget.held
              ? SystemMouseCursors.grabbing
              : SystemMouseCursors.grab,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _focus.requestFocus();
              widget.onTap();
            },
            onPanStart: draggable
                ? (details) => widget.onDragStart!(details.globalPosition)
                : null,
            onPanUpdate: draggable
                ? (details) => widget.onDragUpdate(details.globalPosition)
                : null,
            onPanEnd: draggable ? (_) => widget.onDragEnd() : null,
            onPanCancel: draggable ? widget.onDragCancel : null,
            child: block,
          ),
        ),
      ),
    );
  }
}

/// `2560×1440`, or how many screens there are when there are several.
String _resolutionText(BuildContext context, InputScreen screen) {
  final l10n = context.shellL10n;
  if (screen.displays.length > 1) {
    return l10n.inputScreenCount(screen.displays.length);
  }
  return l10n.inputResolution(screen.bounds.width, screen.bounds.height);
}

Rect _displayRect(
  RemoteInputScreenRect display,
  RemoteInputScreenRect bounds,
  double scale,
) {
  final left = (display.left - bounds.left) * scale;
  final top = (display.top - bounds.top) * scale;
  final gapX = display.left > bounds.left ? _displayGap : 0.0;
  final gapY = display.top > bounds.top ? _displayGap : 0.0;
  return Rect.fromLTWH(
    left + gapX,
    top + gapY,
    math.max(1, display.width * scale - gapX),
    math.max(1, display.height * scale - gapY),
  );
}

class _Label extends StatelessWidget {
  const _Label({required this.text, required this.size, required this.weight});

  final String text;
  final double size;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.center,
    style: TextStyle(
      fontSize: size,
      fontWeight: weight,
      height: 1.25,
      leadingDistribution: TextLeadingDistribution.even,
      color: context.wc.ink,
    ),
  );
}

/// `.disp`: wallpaper, the white bar of a menu bar, a shade over both.
class _Display extends StatelessWidget {
  const _Display({
    required this.rect,
    required this.self,
    required this.selected,
    required this.lifted,
  });

  final Rect rect;
  final bool self, selected;
  final double lifted;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final radius = BorderRadius.circular(WhisperRadius.xs);
    return Positioned.fromRect(
      rect: rect,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: self ? c.tint : c.raised,
          borderRadius: radius,
          // On the screen itself, so there is no gap to it.
          border: Border.all(
            color: selected ? c.accent : c.border,
            width: selected ? 2 : .5,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
          boxShadow: [
            ...WhisperScreens.shadow,
            for (final shadow in WhisperScreens.lifted)
              shadow.copyWith(
                color: shadow.color.withValues(alpha: shadow.color.a * lifted),
              ),
          ],
        ),
      ),
    );
  }
}

const _grey = <double>[
  .2126, .7152, .0722, 0, 0, //
  .2126, .7152, .0722, 0, 0, //
  .2126, .7152, .0722, 0, 0, //
  0, 0, 0, 1, 0, //
];

/// `.bchip`: 34 high, a little screen and a name. Tap or drag to bring it in.
class _CandidateChip extends StatefulWidget {
  const _CandidateChip({
    super.key,
    required this.candidate,
    required this.onAdd,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  final InputCandidate candidate;
  final VoidCallback onAdd;
  final ValueChanged<Offset> onDragStart, onDragUpdate;
  final VoidCallback onDragEnd, onDragCancel;

  @override
  State<_CandidateChip> createState() => _CandidateChipState();
}

class _CandidateChipState extends State<_CandidateChip> {
  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: false);
    final candidate = widget.candidate;
    final enabled = candidate.enabled;
    final device = candidate.device;
    final mini = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WhisperRadius.xs - 2),
        border: Border.all(color: WhisperScreens.shadow.last.color, width: .5),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: deviceArtFor(device, size: 1).wallpaper.gradient,
          borderRadius: BorderRadius.circular(WhisperRadius.xs - 2),
        ),
        child: const SizedBox(width: 32, height: 22),
      ),
    );
    final note = switch (candidate.state) {
      InputCandidateState.unsupported => l10n.inputCandidateUnsupported,
      InputCandidateState.available => null,
    };
    return ShareHover(
      enabled: enabled,
      builder: (context, hover) => Opacity(
        opacity: enabled ? 1 : .55,
        child: Pressable(
          radius: WhisperRadius.capsule,
          label: l10n.inputAddLabel(device.name),
          onTap: enabled ? widget.onAdd : null,
          child: GestureDetector(
            onPanStart: enabled
                ? (details) => widget.onDragStart(details.globalPosition)
                : null,
            onPanUpdate: enabled
                ? (details) => widget.onDragUpdate(details.globalPosition)
                : null,
            onPanEnd: enabled ? (_) => widget.onDragEnd() : null,
            onPanCancel: enabled ? widget.onDragCancel : null,
            child: Container(
              height: 34,
              padding: const EdgeInsets.fromLTRB(6, 0, 12, 0),
              decoration: BoxDecoration(
                color: enabled ? Color.lerp(c.group, c.raised, hover) : c.fill,
                borderRadius: BorderRadius.circular(WhisperRadius.capsule),
                boxShadow: enabled
                    ? WhisperShadow.e1(Theme.of(context).brightness)
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (enabled)
                    mini
                  else
                    ColorFiltered(
                      colorFilter: const ColorFilter.matrix(_grey),
                      child: mini,
                    ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      device.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: type.note,
                        fontWeight: FontWeight.w500,
                        color: c.ink,
                      ),
                    ),
                  ),
                  if (note != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      note,
                      maxLines: 1,
                      style: TextStyle(fontSize: type.tiny, color: c.ink2),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.gs-foot`: one line, 28 high, whatever it says, so that the canvas above
/// never moves.
class _Footer extends StatelessWidget {
  const _Footer({required this.controller});

  final ShellInputController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: false);
    final muted = TextStyle(fontSize: type.note, color: c.ink2);
    Widget line(String text, {Color? color}) => Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: color == null ? muted : muted.copyWith(color: color),
    );
    final footer = controller.footer;
    final children = <Widget>[
      switch (footer) {
        InputFooterHint() => const Spacer(),
        InputFooterExit(:final shortcut) => Expanded(
          child: _ExitHint(shortcut: shortcut),
        ),
        InputFooterNoTargets() => Expanded(
          child: line(l10n.remoteInputWorkspaceNoTargets),
        ),
        InputFooterPermission() => Expanded(
          child: line(l10n.inputPermissionNeeded, color: c.warn),
        ),
        InputFooterFailed() => Expanded(
          child: line(l10n.connectFailed, color: c.warn),
        ),
        InputFooterScreen() => const SizedBox.shrink(),
      },
    ];
    if (footer is InputFooterPermission) {
      children.addAll([
        const SizedBox(width: 8),
        ShareButton(
          label: l10n.shareOpenSettings,
          onTap: () => unawaited(controller.openPermission()),
        ),
      ]);
    }
    if (footer is InputFooterScreen) {
      final screen = footer.screen;
      final failure = footer.failure;
      final resolution = _resolutionText(context, screen);
      final place = switch (footer.side) {
        InputSide.right => l10n.inputSideRight,
        InputSide.left => l10n.inputSideLeft,
        InputSide.above => l10n.inputSideAbove,
        InputSide.below => l10n.inputSideBelow,
        InputSide.elsewhere => l10n.inputSideElsewhere,
      };
      children
        ..clear()
        ..addAll([
          Expanded(
            child: Row(
              children: [
                Flexible(
                  flex: 3,
                  child: Text(
                    screen.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: type.note,
                      fontWeight: FontWeight.w600,
                      color: c.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  flex: 2,
                  child: line(
                    failure == null
                        ? l10n.inputDetail(resolution, place)
                        : resolution,
                  ),
                ),
                if (failure != null) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    flex: 3,
                    child: line(_failureText(context, failure), color: c.warn),
                  ),
                ],
              ],
            ),
          ),
          if (failure != null) ...[
            const SizedBox(width: 8),
            ShareButton(
              label: l10n.retry,
              onTap: () => unawaited(controller.retry(screen.peerId)),
            ),
          ],
          const SizedBox(width: 8),
          // The word lines up with the canvas; its padding hangs outside.
          Transform.translate(
            offset: const Offset(14, 0),
            child: ShareButton(
              label: l10n.inputRemove,
              kind: ShareButtonKind.plain,
              onTap: () => unawaited(controller.remove(screen.peerId)),
            ),
          ),
        ]);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 28),
      child: Row(children: children),
    );
  }
}

String _failureText(BuildContext context, InputFailure failure) {
  final l10n = context.shellL10n;
  return switch (failure) {
    InputFailure.localNotTrusting => l10n.inputReasonNotTrusted,
    InputFailure.peerNotTrusting => l10n.inputReasonPeerNotTrusting,
    InputFailure.unsupported => l10n.inputReasonUnsupported,
    InputFailure.blocked => l10n.inputReasonBlocked,
    InputFailure.peerPermission => l10n.inputReasonPeerPermission,
    InputFailure.busy => l10n.inputReasonBusy,
    InputFailure.other => l10n.connectFailed,
  };
}

/// The way back, which cannot be left out: the page cannot be clicked while the
/// pointer is on another screen. The keys sit in a `kbd`.
class _ExitHint extends StatelessWidget {
  const _ExitHint({required this.shortcut});

  final String shortcut;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    const mark = '\u0000';
    final parts = context.shellL10n.inputHintExit(mark).split(mark);
    final style = TextStyle(fontSize: type.note, color: c.ink2);
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: parts.first),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: c.group,
                borderRadius: BorderRadius.circular(WhisperRadius.xs),
                boxShadow: WhisperShadow.e1(Theme.of(context).brightness),
              ),
              child: Text(
                shortcut,
                style: TextStyle(fontSize: type.tiny, height: 1, color: c.ink),
              ),
            ),
          ),
          if (parts.length > 1) TextSpan(text: parts.last),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// `.empty`: this device is being controlled, and can only stop that.

class _Controlled extends StatelessWidget {
  const _Controlled({
    required this.peerId,
    required this.sessions,
    required this.controller,
  });

  final String peerId;
  final List<ChatSessionItem> sessions;
  final ShellInputController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: false);
    DeviceData? device;
    for (final session in sessions) {
      if (session.device.uid == peerId) device = session.device;
    }
    final source = device;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (source == null)
              const DeviceArt(
                kind: DeviceKind.desktop,
                wallpaper: DeviceWallpaper.unpaired,
                size: 96,
              )
            else
              deviceArtFor(source, size: 96),
            const SizedBox(height: 10),
            Text(
              l10n.inputControlledTitle(source?.name ?? ''),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: type.title,
                fontWeight: FontWeight.w600,
                height: 1.4,
                color: c.ink,
              ),
            ),
            const SizedBox(height: 16),
            ShareButton(
              label: l10n.remoteInputWorkspaceStop,
              large: true,
              onTap: () => unawaited(controller.stopBeingControlled()),
            ),
          ],
        ),
      ),
    );
  }
}
