import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/capture/capture_marks.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

enum CaptureTool { rect, ellipse, arrow, pen, text, mosaic }

/// What is being marked up, and with what: the picture's marks and the tool in
/// hand. Positions are in the picture's pixels; the screens that use this say how
/// large a point on screen is with [unit].
class CaptureTools extends ChangeNotifier {
  CaptureTools(this.picture, {CaptureTool? tool}) : _tool = tool;

  final CapturePicture picture;
  final marks = <CaptureMark>[];
  final _undone = <CaptureMark>[];

  CaptureMark? _live;
  CaptureTool? _tool;
  Color _color = WhisperCapture.colors.first;
  int _size = 1;
  Offset? _start;
  List<Offset>? _stroke;

  /// One point on screen, in the picture's pixels.
  double unit = 1;

  /// The app's text style, as what is written is drawn in it.
  TextStyle baseStyle = const TextStyle();

  final textController = TextEditingController();
  final textFocus = FocusNode();
  Offset? _textAt;

  CaptureMark? get live => _live;
  CaptureTool? get tool => _tool;
  Color get color => _color;
  int get size => _size;
  Offset? get textAt => _textAt;
  bool get canUndo => marks.isNotEmpty;
  bool get canRedo => _undone.isNotEmpty;

  set color(Color value) {
    _color = value;
    notifyListeners();
  }

  set size(int value) {
    _size = value;
    notifyListeners();
  }

  /// The tool again puts it down.
  void choose(CaptureTool tool) {
    commitText();
    _tool = _tool == tool ? null : tool;
    notifyListeners();
  }

  void undo() {
    commitText();
    if (marks.isEmpty) return;
    _undone.add(marks.removeLast());
    notifyListeners();
  }

  void redo() {
    if (_undone.isEmpty) return;
    marks.add(_undone.removeLast());
    notifyListeners();
  }

  void _add(CaptureMark mark) {
    marks.add(mark);
    _undone.clear();
    _live = null;
    notifyListeners();
  }

  double get _strokeWidth => WhisperCapture.strokes[_size] * unit;

  CaptureMark _shape(Offset from, Offset to) {
    final kind = switch (_tool) {
      CaptureTool.ellipse => CaptureShapeKind.ellipse,
      CaptureTool.arrow => CaptureShapeKind.arrow,
      _ => CaptureShapeKind.rect,
    };
    return CaptureShape(
      kind,
      from,
      HardwareKeyboard.instance.isShiftPressed ? _held(kind, from, to) : to,
      color: _color,
      width: _strokeWidth,
    );
  }

  /// With Shift: a square, a circle, an arrow along one of eight directions.
  Offset _held(CaptureShapeKind kind, Offset from, Offset to) {
    final line = to - from;
    if (kind == CaptureShapeKind.arrow) {
      const step = math.pi / 4;
      final angle = (line.direction / step).round() * step;
      return from + Offset.fromDirection(angle, line.distance);
    }
    final side = math.max(line.dx.abs(), line.dy.abs());
    return from +
        Offset(side * (line.dx < 0 ? -1 : 1), side * (line.dy < 0 ? -1 : 1));
  }

  void down(Offset at) {
    if (_tool == null) return;
    if (_tool == CaptureTool.text) {
      // A click elsewhere ends the text being written, and starts no other.
      if (_textAt != null) {
        commitText();
        return;
      }
      _textAt = at;
      notifyListeners();
      textFocus.requestFocus();
      return;
    }
    commitText();
    _start = at;
    if (_tool == CaptureTool.pen || _tool == CaptureTool.mosaic) {
      _stroke = [at];
      _updateStroke();
    }
  }

  void _updateStroke() {
    final points = List<Offset>.of(_stroke!);
    _live = _tool == CaptureTool.mosaic
        ? CaptureMosaic(points, width: WhisperCapture.mosaics[_size] * unit)
        : CapturePen(points, color: _color, width: _strokeWidth);
    notifyListeners();
  }

  void move(Offset at) {
    final start = _start;
    if (start == null) return;
    if (_stroke != null) {
      _stroke!.add(at);
      _updateStroke();
    } else {
      _live = _shape(start, at);
      notifyListeners();
    }
  }

  void up() {
    final live = _live;
    _start = null;
    _stroke = null;
    if (live == null) return;
    if (live is CaptureShape && (live.to - live.from).distance < 2) {
      _live = null;
      notifyListeners();
    } else {
      _add(live);
    }
  }

  TextStyle textStyle(double size) => baseStyle.copyWith(
    color: _color,
    fontSize: size,
    height: 1.25,
    fontWeight: FontWeight.w600,
  );

  void commitText() {
    final at = _textAt;
    if (at == null) return;
    final text = textController.text.trimRight();
    textController.clear();
    _textAt = null;
    if (text.isEmpty) {
      notifyListeners();
      return;
    }
    _add(
      CaptureText(
        at,
        text,
        style: textStyle(WhisperCapture.fonts[_size] * unit),
      ),
    );
  }

  void cancelText() {
    textController.clear();
    _textAt = null;
    notifyListeners();
  }

  /// [crop] in the picture's pixels: the whole picture without it.
  Future<Uint8List?> png({Rect? crop}) async {
    commitText();
    final image = await flattenCapture(picture, marks, crop: crop);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List();
  }

  /// Keys that apply while the screen has the keyboard, not the text being written.
  KeyEventResult key(
    KeyEvent event, {
    required VoidCallback onDone,
    required VoidCallback onCancel,
  }) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyZ &&
        (keys.isMetaPressed || keys.isControlPressed)) {
      keys.isShiftPressed ? redo() : undo();
      return KeyEventResult.handled;
    }
    if (_textAt != null) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      onCancel();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      onDone();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult textKey(KeyEvent event, {required VoidCallback onLeft}) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      cancelText();
      onLeft();
      return KeyEventResult.handled;
    }
    final composing = textController.value.composing;
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !(composing.isValid && !composing.isCollapsed)) {
      commitText();
      onLeft();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    textController.dispose();
    textFocus.dispose();
    super.dispose();
  }
}

/// What is being written, in place, as it will be drawn.
class CaptureTextField extends StatelessWidget {
  const CaptureTextField({
    super.key,
    required this.tools,
    required this.room,
    required this.onLeft,
  });

  final CaptureTools tools;
  final double room;
  final VoidCallback onLeft;

  @override
  Widget build(BuildContext context) {
    final font = WhisperCapture.fonts[tools.size];
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: font * 2,
        maxWidth: math.max(font * 2, room),
      ),
      child: IntrinsicWidth(
        child: Focus(
          onKeyEvent: (_, event) => tools.textKey(event, onLeft: onLeft),
          child: TextField(
            focusNode: tools.textFocus,
            controller: tools.textController,
            autofocus: true,
            maxLines: null,
            cursorColor: tools.color,
            style: tools.textStyle(font),
            decoration: const InputDecoration(
              isCollapsed: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );
  }
}

/// A strip of glass, as the composer is. Its shadow only goes outside it.
class CaptureGlass extends StatelessWidget {
  const CaptureGlass({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    const radius = WhisperRadius.m;
    return CustomPaint(
      painter: WhisperOutsideShadow(
        shadows: WhisperShadow.e2(Theme.of(context).brightness),
        radius: radius,
      ),
      child: WhisperGlass(
        kind: GlassKind.control,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Padding(padding: const EdgeInsets.all(5), child: child),
      ),
    );
  }
}

/// The size and colour of the tool in hand. A mosaic has no colour.
class CaptureOptionsBar extends StatelessWidget {
  const CaptureOptionsBar({super.key, required this.tools});

  final CaptureTools tools;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    return CaptureGlass(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < WhisperCapture.strokes.length; i++)
            Pressable(
              onTap: () => tools.size = i,
              radius: WhisperRadius.capsule,
              child: SizedBox.square(
                dimension: 26,
                child: Center(
                  child: Container(
                    width: 6 + i * 4,
                    height: 6 + i * 4,
                    decoration: BoxDecoration(
                      color: tools.size == i ? c.ink : c.ink3,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          if (tools.tool != CaptureTool.mosaic) ...[
            Container(
              width: 1,
              height: 16,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              color: c.sep,
            ),
            for (final color in WhisperCapture.colors)
              Pressable(
                onTap: () => tools.color = color,
                radius: WhisperRadius.capsule,
                child: SizedBox.square(
                  dimension: 26,
                  child: Center(
                    child: Container(
                      width: 22,
                      height: 22,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: tools.color == color
                            ? Border.all(color: c.ink, width: 1.5)
                            : null,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: c.sep),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Everything that can be done with the picture, on one line.
class CaptureToolbar extends StatelessWidget {
  const CaptureToolbar({
    super.key,
    required this.tools,
    required this.doneLabel,
    required this.busy,
    required this.onDone,
    required this.onSave,
    required this.onCancel,
  });

  final CaptureTools tools;
  final String doneLabel;
  final bool busy;
  final VoidCallback onDone, onSave, onCancel;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = AppLocalizations.of(context)!;
    Widget tool(CaptureTool tool, WhisperGlyph glyph, String label) =>
        ShellToolCapsuleItem(
          glyph: glyph,
          label: label,
          color: tools.tool == tool ? c.accentText : c.ink2,
          selected: tools.tool == tool,
          onTap: () => tools.choose(tool),
        );
    Widget plain(WhisperGlyph glyph, String label, VoidCallback? onTap) =>
        ShellToolCapsuleItem(
          glyph: glyph,
          label: label,
          color: onTap == null ? c.ink3 : c.ink2,
          onTap: onTap,
        );
    return CaptureGlass(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShellToolCapsule(
            children: [
              tool(CaptureTool.rect, WhisperGlyph.markRect, l10n.captureRect),
              tool(
                CaptureTool.ellipse,
                WhisperGlyph.markEllipse,
                l10n.captureEllipse,
              ),
              tool(
                CaptureTool.arrow,
                WhisperGlyph.markArrow,
                l10n.captureArrow,
              ),
              tool(CaptureTool.pen, WhisperGlyph.markPen, l10n.capturePen),
              tool(CaptureTool.text, WhisperGlyph.markText, l10n.captureText),
              tool(
                CaptureTool.mosaic,
                WhisperGlyph.markMosaic,
                l10n.captureMosaic,
              ),
            ],
          ),
          const SizedBox(width: 6),
          plain(
            WhisperGlyph.undo,
            l10n.captureUndo,
            tools.canUndo ? tools.undo : null,
          ),
          plain(
            WhisperGlyph.redo,
            l10n.captureRedo,
            tools.canRedo ? tools.redo : null,
          ),
          const SizedBox(width: 12),
          plain(WhisperGlyph.x, l10n.cancel, onCancel),
          plain(WhisperGlyph.download, l10n.captureSave, busy ? null : onSave),
          const SizedBox(width: 6),
          ShellButton(
            label: doneLabel,
            kind: ShellButtonKind.primary,
            onTap: busy ? null : onDone,
          ),
        ],
      ),
    );
  }
}

/// One pixel of the picture to one of the screen needs no filter, and any other
/// number than that does.
FilterQuality captureViewQuality(double fit, double devicePixelRatio) =>
    (fit * devicePixelRatio - 1).abs() < .001
    ? FilterQuality.none
    : FilterQuality.medium;
