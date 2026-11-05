import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/capture/capture_marks.dart';
import 'package:whisper/new_ui/capture/capture_tools.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/whisper_window.dart';

/// surfaces.md「截图标注」: a picture that is not on screen any more, one waiting
/// to be sent or one from where nothing could be drawn in place: full window, in
/// place of what is behind it. Returns the PNG once it is done, null if cancelled.
///
/// [scale] is how many of its pixels make a point on the screen it comes from,
/// so that it shows at its real size, sharp, unless the window is too small.
Future<Uint8List?> showCaptureEditor(
  NavigatorState navigator, {
  required ui.Image image,
  required double scale,
  required String doneLabel,
}) => navigator.push<Uint8List>(
  PageRouteBuilder<Uint8List>(
    opaque: true,
    pageBuilder: (context, animation, secondary) =>
        CaptureEditor(image: image, scale: scale, doneLabel: doneLabel),
    transitionsBuilder: (context, animation, secondary, child) =>
        FadeTransition(opacity: animation, child: child),
  ),
);

class CaptureEditor extends StatefulWidget {
  const CaptureEditor({
    super.key,
    required this.image,
    required this.scale,
    required this.doneLabel,
  });

  final ui.Image image;
  final double scale;
  final String doneLabel;

  @override
  State<CaptureEditor> createState() => _CaptureEditorState();
}

class _CaptureEditorState extends State<CaptureEditor> {
  CaptureTools? _tools;
  var _busy = false;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final picture = await CapturePicture.of(
      widget.image,
      block: math.max(4, (WhisperCapture.block * widget.scale).round()),
    );
    if (!mounted) {
      picture.dispose();
      return;
    }
    setState(() => _tools = CaptureTools(picture, tool: CaptureTool.rect));
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _tools?.picture.dispose();
    _tools?.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _done() async {
    if (_busy) return;
    setState(() => _busy = true);
    final png = await _tools!.png();
    if (mounted) Navigator.of(context).pop(png);
  }

  Future<void> _save() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final png = await _tools!.png();
      if (png == null) return;
      final path = await FilePicker.saveFile(
        dialogTitle: l10n.captureSave,
        fileName: captureFileName(),
        initialDirectory: await LocalSetting().saveDialogFolder(),
        bytes: png,
      );
      if (path != null) {
        await File(path).writeAsBytes(png);
        if (mounted) Navigator.of(context).pop();
      }
    } on Object {
      showAppToast(l10n.screenshotFailed, tone: AppToastTone.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final tools = _tools;
    return Material(
      color: c.canvas,
      child: tools == null
          ? const SizedBox.expand()
          : Focus(
              focusNode: _focus,
              onKeyEvent: (_, event) => tools.key(
                event,
                onDone: () => unawaited(_done()),
                onCancel: () => Navigator.of(context).pop(),
              ),
              child: ListenableBuilder(
                listenable: tools,
                builder: (context, _) => Column(
                  children: [
                    // The window's buttons and the island are up here.
                    SizedBox(height: WhisperWindow.sheetGap / 2),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                        child: LayoutBuilder(
                          builder: (context, box) => Center(
                            child: _canvas(context, tools, box.biggest),
                          ),
                        ),
                      ),
                    ),
                    if (tools.tool != null) ...[
                      CaptureOptionsBar(tools: tools),
                      const SizedBox(height: 8),
                    ],
                    CaptureToolbar(
                      tools: tools,
                      doneLabel: widget.doneLabel,
                      busy: _busy,
                      onDone: () => unawaited(_done()),
                      onSave: () => unawaited(_save()),
                      onCancel: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _canvas(BuildContext context, CaptureTools tools, Size room) {
    final bounds = tools.picture.bounds;
    final natural = bounds.size / widget.scale;
    final shrink = math.min(
      1.0,
      math.min(room.width / natural.width, room.height / natural.height),
    );
    final size = natural * shrink;
    final fit = size.width / bounds.width;
    tools
      ..unit = 1 / fit
      ..baseStyle = Theme.of(context).textTheme.bodyMedium!;
    Offset toPicture(Offset view) => Offset(
      (view.dx / fit).clamp(0, bounds.width).toDouble(),
      (view.dy / fit).clamp(0, bounds.height).toDouble(),
    );
    final at = tools.textAt;
    return SizedBox(
      width: size.width,
      height: size.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          boxShadow: WhisperShadow.e2(Theme.of(context).brightness),
        ),
        child: MouseRegion(
          cursor: tools.tool == CaptureTool.text
              ? SystemMouseCursors.text
              : SystemMouseCursors.precise,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              if (event.buttons != kPrimaryButton) return;
              final hadText = tools.textAt != null;
              tools.down(toPicture(event.localPosition));
              if (hadText) _focus.requestFocus();
            },
            onPointerMove: (event) =>
                tools.move(toPicture(event.localPosition)),
            onPointerUp: (_) => tools.up(),
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _PicturePainter(
                        tools,
                        fit,
                        MediaQuery.devicePixelRatioOf(context),
                      ),
                    ),
                  ),
                ),
                if (at != null)
                  Positioned(
                    left: at.dx * fit,
                    top: at.dy * fit,
                    child: CaptureTextField(
                      tools: tools,
                      room: size.width - at.dx * fit,
                      onLeft: _focus.requestFocus,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String captureFileName() {
  String two(int v) => v.toString().padLeft(2, '0');
  final t = DateTime.now();
  return 'Screenshot ${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}.${two(t.minute)}.${two(t.second)}.png';
}

class _PicturePainter extends CustomPainter {
  const _PicturePainter(this.tools, this.fit, this.dpr);

  final CaptureTools tools;
  final double fit, dpr;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(fit);
    paintCapture(canvas, tools.picture, [
      ...tools.marks,
      ?tools.live,
    ], quality: captureViewQuality(fit, dpr));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PicturePainter old) => true;
}
