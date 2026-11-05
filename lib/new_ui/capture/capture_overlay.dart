import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/image_memory_budget.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/capture/capture_marks.dart';
import 'package:whisper/new_ui/capture/capture_tools.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:window_manager/window_manager.dart';

const captureOverlayArgument = 'capture_overlay';
const _theme = MethodChannel('com.vireen.whisper/window_theme');

/// surfaces.md「截图」: the screen, as it was, with the selection and its tools.
/// A window and an engine of their own, over everything: the selection overlay
/// of each platform hands over to this one the moment the selection is made, and
/// nothing on screen moves as it does.
///
/// Nothing is drawn until the window has its size. A Flutter view that has drawn
/// a frame holds up the main thread when it is resized, until it has one of the
/// new size: in practice a second, with the selection frozen.
Future<void> startCaptureOverlay() async {
  await applyImageMemoryBudget(background: true);
  await windowManager.ensureInitialized();
  // See the tray panel: on Windows this creates the plugin's taskbar object.
  if (Platform.isWindows) await windowManager.waitUntilReadyToShow();
  if (!Platform.isMacOS) await windowManager.setSkipTaskbar(true);
  final me = await WindowController.fromCurrentEngine();
  await me.setWindowMethodHandler(_CaptureOverlay.instance._handle);
}

class _Session {
  _Session({
    required this.tools,
    required this.scale,
    required this.selection,
    required this.host,
  });

  final CaptureTools tools;
  final double scale;
  final String host;

  /// In points of that screen, from its top left.
  Rect selection;

  /// The part of the picture that will come out.
  Rect get pixels => Rect.fromLTRB(
    (selection.left * scale).roundToDouble(),
    (selection.top * scale).roundToDouble(),
    (selection.right * scale).roundToDouble(),
    (selection.bottom * scale).roundToDouble(),
  ).intersect(tools.picture.bounds);

  Size get pixelSize => pixels.size;
}

class _CaptureOverlay extends ChangeNotifier {
  _CaptureOverlay._();

  static final instance = _CaptureOverlay._();

  /// While it is on screen its blur and picture need room; otherwise nothing
  /// is kept for them.
  static const _inUse = 96 * 1024 * 1024, _idle = 8 * 1024 * 1024;

  _Session? session;
  var dark = false;
  var locale = 'zh';
  var busy = false;
  var _running = false;

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'ping':
        return call.arguments;
      case 'load':
        await _load(Map<String, dynamic>.from(call.arguments as Map));
      case 'open':
        await _open((call.arguments as List).cast<num>());
      case 'resume':
        await _reveal();
        busy = false;
        notifyListeners();
      case 'finish':
        await _finish();
      case 'destroy':
        await _theme.invokeMethod<bool>('closeCover');
    }
    return null;
  }

  /// What can take a while, done out of sight while the selection is being made.
  /// The whole screen is drawn, with its tools, so that nothing is left to do but
  /// to say where the selection is.
  Future<void> _load(Map<String, dynamic> a) async {
    await _dropSession();
    await _gpuCache(_inUse);
    final frame = (a['frame'] as List).cast<num>().map((v) => v.toDouble());
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      a['rgba'] as Uint8List,
      a['width'] as int,
      a['height'] as int,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    final scale = (a['scale'] as num).toDouble();
    final picture = await CapturePicture.of(
      image,
      block: math.max(4, (WhisperCapture.block * scale).round()),
    );
    await _cover(frame.toList());
    final points = picture.bounds.size / scale;
    dark = a['dark'] as bool? ?? false;
    locale = a['locale'] as String? ?? 'zh';
    busy = false;
    session = _Session(
      tools: CaptureTools(picture),
      scale: scale,
      selection: Rect.fromCenter(
        center: points.center(Offset.zero),
        width: points.width / 2,
        height: points.height / 2,
      ),
      host: a['host'] as String,
    );
    if (_running) {
      notifyListeners();
    } else {
      _running = true;
      runApp(const CaptureOverlayApp());
    }
    await _frame();
    await _frame();
  }

  /// Its next frame, unless it makes none where it can't be seen.
  Future<void> _frame() => WidgetsBinding.instance.endOfFrame.timeout(
    const Duration(milliseconds: 200),
    onTimeout: () {},
  );

  Future<void> _open(List<num> s) async {
    final current = session;
    if (current == null) throw StateError('nothing loaded');
    current.selection = Rect.fromLTWH(
      s[0].toDouble(),
      s[1].toDouble(),
      s[2].toDouble(),
      s[3].toDouble(),
    );
    notifyListeners();
    await _frame();
    await _reveal();
    await _frame();
    await _send('shown');
  }

  Future<void> _cover(List<double> frame) async {
    if (Platform.isLinux) {
      await windowManager.setAsFrameless();
      await windowManager.setBounds(
        Rect.fromLTWH(frame[0], frame[1], frame[2], frame[3]),
      );
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show();
      await windowManager.setFullScreen(true);
      return;
    }
    await _theme.invokeMethod<bool>('coverDisplay', frame);
  }

  Future<void> _reveal() async {
    if (Platform.isLinux) {
      await windowManager.show();
      await windowManager.focus();
      return;
    }
    await _theme.invokeMethod<bool>('revealCover');
  }

  Future<void> _hideWindow() async {
    if (Platform.isLinux) {
      await windowManager.setFullScreen(false);
      await windowManager.hide();
      return;
    }
    await _theme.invokeMethod<bool>('hideCover');
  }

  Future<void> _gpuCache(int bytes) async {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    await SystemChannels.skia.invokeMethod<void>(
      'Skia.setResourceCacheMaxBytes',
      bytes,
    );
  }

  /// Back to the main engine, which does what this one has no plugins for.
  Future<void> _send(String action, [Uint8List? png]) async {
    final host = session?.host;
    if (host == null) return;
    await WindowController.fromWindowId(
      host,
    ).invokeMethod<void>('captureResult', {'action': action, 'png': png});
  }

  /// Where this engine stays: the picture goes, and a screen's worth of surface
  /// with it. On a Mac it is taken down instead.
  Future<void> _finish() async {
    await _dropSession();
    await _gpuCache(_idle);
    // Windows keeps its size: back from 1×1 the next picture came out on a
    // surface of the wrong shape, squashed and half black.
    if (Platform.isLinux) {
      await windowManager.setBounds(const Rect.fromLTWH(0, 0, 1, 1));
    }
    await _frame();
    await _hideWindow();
  }

  Future<void> _dropSession() async {
    final current = session;
    if (current == null) return;
    session = null;
    notifyListeners();
    // A frame without them: they may still be on the one on screen.
    await _frame();
    current.tools.picture.dispose();
    current.tools.dispose();
    PaintingBinding.instance.imageCache.clear();
  }

  Future<void> deliver(String action) async {
    final current = session;
    if (current == null || busy) return;
    busy = true;
    notifyListeners();
    final png = await current.tools.png(crop: current.pixels);
    await _hideWindow();
    await _send(action, png);
  }

  Future<void> cancel() async {
    await _hideWindow();
    await _send('cancel');
  }
}

class CaptureOverlayApp extends StatelessWidget {
  const CaptureOverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    final overlay = _CaptureOverlay.instance;
    return ListenableBuilder(
      listenable: overlay,
      builder: (context, _) {
        final session = overlay.session;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: overlay.dark ? AppTheme.darkTheme : AppTheme.lightTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale(overlay.locale),
          home: Scaffold(
            backgroundColor: Colors.transparent,
            body: session == null
                ? const SizedBox.expand()
                : _Overlay(
                    key: ValueKey(session),
                    session: session,
                    busy: overlay.busy,
                    onCopy: () => unawaited(overlay.deliver('copy')),
                    onSave: () => unawaited(overlay.deliver('save')),
                    onCancel: () => unawaited(overlay.cancel()),
                  ),
          ),
        );
      },
    );
  }
}

enum _Edit { none, create, move, resize }

class _Overlay extends StatefulWidget {
  const _Overlay({
    super.key,
    required this.session,
    required this.busy,
    required this.onCopy,
    required this.onSave,
    required this.onCancel,
  });

  final _Session session;
  final bool busy;
  final VoidCallback onCopy, onSave, onCancel;

  @override
  State<_Overlay> createState() => _OverlayState();
}

class _OverlayState extends State<_Overlay> {
  static const _left = 1, _right = 2, _top = 4, _bottom = 8, _inside = 16;
  static const _edge = 8.0;

  final _focus = FocusNode();
  var _edit = _Edit.none;
  var _hit = 0;
  var _hover = 0;
  Offset _anchor = Offset.zero;
  Rect _from = Rect.zero;
  bool _moved = false;
  DateTime _lastClick = DateTime(0);

  _Session get _session => widget.session;
  CaptureTools get _tools => _session.tools;

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  int _hitAt(Offset p) {
    final s = _session.selection;
    if (!s.inflate(_edge).contains(p)) return 0;
    var hit = 0;
    if ((p.dx - s.left).abs() <= _edge) {
      hit |= _left;
    } else if ((p.dx - s.right).abs() <= _edge) {
      hit |= _right;
    }
    if ((p.dy - s.top).abs() <= _edge) {
      hit |= _top;
    } else if ((p.dy - s.bottom).abs() <= _edge) {
      hit |= _bottom;
    }
    return hit == 0 ? _inside : hit;
  }

  MouseCursor get _cursor {
    final tool = _tools.tool;
    if (tool != null) {
      if (!_session.selection.contains(_hoverAt)) {
        return SystemMouseCursors.basic;
      }
      return tool == CaptureTool.text
          ? SystemMouseCursors.text
          : SystemMouseCursors.precise;
    }
    return switch (_hover) {
      _inside => SystemMouseCursors.move,
      _left || _right => SystemMouseCursors.resizeLeftRight,
      _top || _bottom => SystemMouseCursors.resizeUpDown,
      5 || 10 => SystemMouseCursors.resizeUpLeftDownRight,
      6 || 9 => SystemMouseCursors.resizeUpRightDownLeft,
      _ => SystemMouseCursors.precise,
    };
  }

  Offset _hoverAt = Offset.zero;

  Offset _picture(Offset view) {
    // What is drawn stays inside the selection.
    final s = _session.selection;
    final at = Offset(
      view.dx.clamp(s.left, s.right).toDouble(),
      view.dy.clamp(s.top, s.bottom).toDouble(),
    );
    return at * _session.scale;
  }

  void _down(PointerDownEvent event) {
    final p = event.localPosition;
    if (event.buttons == kSecondaryButton) {
      widget.onCancel();
      return;
    }
    if (event.buttons != kPrimaryButton) return;
    if (_tools.tool != null) {
      if (_session.selection.contains(p)) {
        final hadText = _tools.textAt != null;
        _tools.down(_picture(p));
        if (hadText) _focus.requestFocus();
      } else if (_tools.textAt != null) {
        _tools.commitText();
        _focus.requestFocus();
      }
      return;
    }
    _anchor = p;
    _from = _session.selection;
    _moved = false;
    _hit = _hitAt(p);
    setState(() {
      _edit = switch (_hit) {
        0 => _Edit.create,
        _inside => _Edit.move,
        _ => _Edit.resize,
      };
    });
  }

  void _move(PointerMoveEvent event, Size screen) {
    final p = Offset(
      event.localPosition.dx.clamp(0, screen.width).toDouble(),
      event.localPosition.dy.clamp(0, screen.height).toDouble(),
    );
    if (_tools.tool != null) {
      _tools.move(_picture(p));
      return;
    }
    if (_edit == _Edit.none) return;
    _moved = _moved || (p - _anchor).distance > 3;
    if (!_moved) return;
    setState(() {
      switch (_edit) {
        case _Edit.create:
          _session.selection = Rect.fromPoints(_anchor, p);
        case _Edit.move:
          final dx = (p.dx - _anchor.dx)
              .clamp(-_from.left, screen.width - _from.right)
              .toDouble();
          final dy = (p.dy - _anchor.dy)
              .clamp(-_from.top, screen.height - _from.bottom)
              .toDouble();
          _session.selection = _from.shift(Offset(dx, dy));
        case _Edit.resize:
          final left = _hit & _left != 0 ? p.dx : _from.left;
          final right = _hit & _right != 0 ? p.dx : _from.right;
          final top = _hit & _top != 0 ? p.dy : _from.top;
          final bottom = _hit & _bottom != 0 ? p.dy : _from.bottom;
          _session.selection = Rect.fromLTRB(
            math.min(left, right),
            math.min(top, bottom),
            math.max(left, right),
            math.max(top, bottom),
          );
        case _Edit.none:
          break;
      }
    });
  }

  void _up(PointerUpEvent event) {
    if (_tools.tool != null) {
      _tools.up();
      return;
    }
    final clickedInside = !_moved && _hit == _inside;
    setState(() {
      // Too small to be a selection: the one before stays.
      if (_session.selection.width < 2 || _session.selection.height < 2) {
        _session.selection = _from;
      }
      _edit = _Edit.none;
    });
    if (clickedInside) {
      final now = DateTime.now();
      if (now.difference(_lastClick) < kDoubleTapTimeout) widget.onCopy();
      _lastClick = now;
    }
  }

  @override
  Widget build(BuildContext context) {
    _tools
      ..unit = _session.scale
      ..baseStyle = Theme.of(context).textTheme.bodyMedium!;
    return LayoutBuilder(
      builder: (context, box) => Focus(
        focusNode: _focus,
        onKeyEvent: (_, event) =>
            _tools.key(event, onDone: widget.onCopy, onCancel: widget.onCancel),
        child: ListenableBuilder(
          listenable: _tools,
          builder: (context, _) => _content(context, box.biggest),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, Size screen) {
    final session = _session;
    final s = session.selection;
    final at = _tools.textAt;
    return Stack(
      children: [
        Positioned.fill(
          child: MouseRegion(
            cursor: _cursor,
            onHover: (event) => setState(() {
              _hoverAt = event.localPosition;
              _hover = _hitAt(event.localPosition);
            }),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _down,
              onPointerMove: (event) => _move(event, screen),
              onPointerUp: _up,
              child: CustomPaint(
                painter: _OverlayPainter(
                  session,
                  MediaQuery.devicePixelRatioOf(context),
                  accent: context.wc.accent,
                  handles: _tools.tool == null,
                ),
              ),
            ),
          ),
        ),
        if (at != null)
          Positioned(
            left: at.dx / session.scale,
            top: at.dy / session.scale,
            child: CaptureTextField(
              tools: _tools,
              room: s.right - at.dx / session.scale,
              onLeft: _focus.requestFocus,
            ),
          ),
        IgnorePointer(
          child: CustomSingleChildLayout(
            delegate: _AboveSelection(s),
            child: _SizeLabel(session.pixelSize),
          ),
        ),
        // Gone while the selection is being dragged, and back beside it after.
        if (_edit == _Edit.none)
          CustomSingleChildLayout(
            delegate: _BesideSelection(s),
            child: _bars(context, s, screen),
          ),
      ],
    );
  }

  Widget _bars(BuildContext context, Rect s, Size screen) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        CaptureToolbar(
          tools: _tools,
          doneLabel: l10n.screenshotConfirm,
          busy: widget.busy,
          onDone: widget.onCopy,
          onSave: widget.onSave,
          onCancel: widget.onCancel,
        ),
        if (_tools.tool != null) ...[
          const SizedBox(height: 6),
          CaptureOptionsBar(tools: _tools),
        ],
      ],
    );
  }
}

/// How large the picture will come out, in pixels.
class _SizeLabel extends StatelessWidget {
  const _SizeLabel(this.size);

  final Size size;

  @override
  Widget build(BuildContext context) => Container(
    height: WhisperCapture.sizeLabelHeight,
    padding: const EdgeInsets.symmetric(
      horizontal: WhisperCapture.sizeLabelPadding,
    ),
    decoration: BoxDecoration(
      color: WhisperCapture.sizeLabelFill,
      borderRadius: BorderRadius.circular(WhisperRadius.xs),
    ),
    // As wide as its text, with the text in the middle of its height.
    child: Align(
      widthFactor: 1,
      child: Text(
        '${size.width.round()} × ${size.height.round()}',
        style: const TextStyle(
          color: Radix.white,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          fontFeatures: [ui.FontFeature.tabularFigures()],
        ),
      ),
    ),
  );
}

/// Above the selection's top left corner, or just inside it at the top of the
/// screen.
class _AboveSelection extends SingleChildLayoutDelegate {
  const _AboveSelection(this.selection);

  final Rect selection;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size child) {
    const gap = WhisperCapture.sizeLabelGap;
    final above = selection.top - child.height - gap;
    return Offset(
      selection.left
          .clamp(gap, math.max(gap, size.width - child.width - gap))
          .toDouble(),
      above >= gap ? above : selection.top + gap,
    );
  }

  @override
  bool shouldRelayout(_AboveSelection old) => old.selection != selection;
}

/// Under the selection, at its right edge. Above it where there is no room, and
/// inside it for one that fills the screen. Its top stays put, so that the options
/// appearing below the tools move neither.
class _BesideSelection extends SingleChildLayoutDelegate {
  const _BesideSelection(this.selection);

  final Rect selection;
  static const _gap = 8.0, _margin = 10.0;

  /// The tools and the options, whichever is on screen, have this much to fit.
  static const _room = 96.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = (selection.right - child.width)
        .clamp(_margin, math.max(_margin, size.width - child.width - _margin))
        .toDouble();
    double y;
    if (selection.bottom + _gap + _room <= size.height - _margin) {
      y = selection.bottom + _gap;
    } else if (selection.top - _gap - _room >= _margin) {
      y = selection.top - _gap - _room;
    } else {
      y = selection.bottom - _room - _margin;
    }
    return Offset(x, y.clamp(_margin, size.height - _room).toDouble());
  }

  @override
  bool shouldRelayout(_BesideSelection old) => old.selection != selection;
}

class _OverlayPainter extends CustomPainter {
  const _OverlayPainter(
    this.session,
    this.dpr, {
    required this.accent,
    required this.handles,
  });

  final _Session session;
  final double dpr;
  final Color accent;
  final bool handles;

  @override
  void paint(Canvas canvas, Size size) {
    final tools = session.tools;
    final s = session.selection;
    final fit = 1 / session.scale;
    canvas.save();
    canvas.scale(fit);
    canvas.drawImage(
      tools.picture.image,
      Offset.zero,
      Paint()..filterQuality = captureViewQuality(fit, dpr),
    );
    canvas.clipRect(
      Rect.fromLTRB(s.left / fit, s.top / fit, s.right / fit, s.bottom / fit),
    );
    for (final mark in [...tools.marks, ?tools.live]) {
      mark.paint(canvas, tools.picture);
    }
    canvas.restore();

    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(s),
      Paint()..color = WhisperCapture.dim,
    );
    canvas.drawRect(
      s,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = WhisperCapture.selectionStroke
        ..color = accent,
    );
    if (!handles) return;
    final fill = Paint()..color = Radix.white;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = WhisperCapture.handleStroke
      ..color = accent;
    for (final x in [s.left, s.center.dx, s.right]) {
      for (final y in [s.top, s.center.dy, s.bottom]) {
        if (x == s.center.dx && y == s.center.dy) continue;
        canvas.drawCircle(Offset(x, y), WhisperCapture.handle, fill);
        canvas.drawCircle(Offset(x, y), WhisperCapture.handle, ring);
      }
    }
  }

  @override
  bool shouldRepaint(_OverlayPainter old) => true;
}
