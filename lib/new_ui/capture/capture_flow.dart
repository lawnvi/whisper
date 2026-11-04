import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/helper/desktop_screenshot.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/capture/capture_editor.dart';
import 'package:whisper/new_ui/capture/capture_overlay_host.dart';
import 'package:window_manager/window_manager.dart';

Future<void> prepareScreenshotOverlay() async {
  try {
    await CaptureOverlayHost.shared.prepare();
  } on Object {
    // markUpScreenshot does without it.
  }
}

void loadScreenshotOverlay(ScreenshotPicture picture) {
  final context = appNavigatorKey.currentContext;
  if (context == null) return;
  CaptureOverlayHost.shared.load(
    picture,
    dark: Theme.of(context).brightness == Brightness.dark,
    locale: Localizations.localeOf(context).languageCode,
  );
}

void abandonScreenshotOverlay() => CaptureOverlayHost.shared.finish();

/// From the overlay: the selection stays on screen, its tools come up beside it,
/// and the result goes on the clipboard like any screenshot. Whisper's own window
/// stays out of it, wherever it is.
Future<bool> markUpScreenshot(
  List<double> selection,
  ScreenshotPicture? picture,
  Future<void> Function() closeOverlay,
) async {
  final context = appNavigatorKey.currentContext;
  if (context == null) {
    await closeOverlay();
    return false;
  }
  if (picture != null) loadScreenshotOverlay(picture);
  final doneLabel = AppLocalizations.of(context)!.screenshotConfirm;
  final navigator = appNavigatorKey.currentState!;
  final host = CaptureOverlayHost.shared;
  CaptureOutcome outcome;
  try {
    outcome = await host.open(
      selection,
      onShown: () => unawaited(closeOverlay()),
    );
  } on Object {
    // No window of its own here: the same tools, in Whisper's own.
    final whole = host.picture;
    host.finish();
    await closeOverlay();
    if (whole == null) return false;
    return _markUpInWindow(navigator, whole, selection, doneLabel);
  }
  while (outcome.action == 'save') {
    if (await _saveAs(outcome.png)) {
      host.finish();
      return false;
    }
    outcome = await host.resume();
  }
  host.finish();
  return outcome.action == 'copy' && await _copy(outcome.png);
}

Future<bool> _saveAs(Uint8List? png) async {
  if (png == null) return true;
  final context = appNavigatorKey.currentContext;
  final l10n = context == null ? null : AppLocalizations.of(context);
  final path = await FilePicker.saveFile(
    dialogTitle: l10n?.captureSave,
    fileName: captureFileName(),
    bytes: png,
  );
  if (path == null) return false;
  await File(path).writeAsBytes(png);
  return true;
}

Future<bool> _copy(Uint8List? png) async {
  if (png == null) throw StateError('no picture');
  final file = await _write(png);
  if (!await const DesktopClipboardFileWriter().writeFilePaths([
    file.path,
  ], asImage: true)) {
    throw StateError('clipboard');
  }
  return true;
}

/// Where no window could take over. The selection only, in Whisper's own window.
Future<bool> _markUpInWindow(
  NavigatorState navigator,
  ScreenshotPicture pixels,
  List<double> s,
  String doneLabel,
) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels.rgba,
    pixels.width,
    pixels.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final whole = await completer.future;
  final crop = Rect.fromLTWH(
    (s[0] * pixels.scale).roundToDouble(),
    (s[1] * pixels.scale).roundToDouble(),
    (s[2] * pixels.scale).roundToDouble(),
    (s[3] * pixels.scale).roundToDouble(),
  );
  final recorder = ui.PictureRecorder();
  ui.Canvas(
    recorder,
  ).drawImage(whole, Offset(-crop.left, -crop.top), ui.Paint());
  final image = await recorder.endRecording().toImage(
    crop.width.round(),
    crop.height.round(),
  );
  whole.dispose();
  final wasHidden = !await windowManager.isVisible();
  final wasMinimized = await windowManager.isMinimized();
  if (wasMinimized) await windowManager.restore();
  await windowManager.show();
  await windowManager.focus();
  final png = await showCaptureEditor(
    navigator,
    image: image,
    scale: pixels.scale,
    doneLabel: doneLabel,
  );
  final copied = png != null && await _copy(png);
  if (wasHidden) {
    await windowManager.hide();
  } else if (wasMinimized) {
    await windowManager.minimize();
  }
  return copied;
}

/// From the composer: a picture waiting to be sent. Null when nothing changed.
Future<ClipboardImageDraft?> markUpDraftImage(
  NavigatorState navigator, {
  required Uint8List? bytes,
  required String path,
  required String doneLabel,
}) async {
  final source = bytes ?? await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(source);
  final frame = await codec.getNextFrame();
  codec.dispose();
  final png = await showCaptureEditor(
    navigator,
    image: frame.image,
    scale: ui.PlatformDispatcher.instance.views.first.devicePixelRatio,
    doneLabel: doneLabel,
  );
  if (png == null) return null;
  final file = await _write(png, name: p.basename(path));
  return ClipboardImageDraft(
    path: file.path,
    fileName: p.basename(file.path),
    size: png.length,
    bytes: png,
  );
}

Future<File> _write(Uint8List png, {String? name}) async {
  final directory = await Directory(
    p.join((await getTemporaryDirectory()).path, 'whisper-capture'),
  ).create(recursive: true);
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final stem = name == null ? 'Screenshot' : p.basenameWithoutExtension(name);
  return File(
    p.join(directory.path, '$stem-$stamp.png'),
  ).writeAsBytes(png, flush: true);
}
