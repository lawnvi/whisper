import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/desktop_screenshot.dart';
import 'package:whisper/helper/main_window_calls.dart';
import 'package:whisper/new_ui/capture/capture_overlay.dart';

/// What came back from the overlay: 'copy', 'save' or 'cancel'.
typedef CaptureOutcome = ({String action, Uint8List? png});

/// The main engine's side of the overlay. Its window and engine are made when a
/// screenshot starts, and get the picture while the selection is being made, so
/// that the tools are there the moment the mouse is let go. On a Mac they go when
/// it is over: making them takes a tenth of a second, and keeping them a lot of
/// memory. Elsewhere they stay, with nothing in them: on Windows taking an engine
/// down is what crashes when the app exits.
class CaptureOverlayHost {
  CaptureOverlayHost._();

  static final shared = CaptureOverlayHost._();

  WindowController? _window;
  Future<void>? _preparing;
  Future<void>? _loading;
  ScreenshotPicture? _picture;
  Completer<CaptureOutcome>? _result;
  VoidCallback? _onShown;

  /// The screen being worked on: all of it, until the screenshot is over.
  ScreenshotPicture? get picture => _picture;

  Future<void> prepare() => _preparing ??= _create().catchError((Object error) {
    _preparing = null;
    throw error;
  });

  Future<void> _create() async {
    // Its engine only needs a few plugins, and on Windows must not get them all.
    if (Platform.isWindows) {
      await const MethodChannel(
        'com.vireen.whisper/window_theme',
      ).invokeMethod<void>('nextWindowIsPanel');
    }
    final window = await WindowController.create(
      const WindowConfiguration(
        hiddenAtLaunch: true,
        arguments: captureOverlayArgument,
      ),
    );
    MainWindowCalls.on('captureResult', _onResult);
    // The engine takes a moment; it answers once its handler is up.
    for (var i = 0; i < 100; i++) {
      try {
        await window
            .invokeMethod<Object?>('ping', 0)
            .timeout(const Duration(milliseconds: 200));
        _window = window;
        return;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    throw StateError('capture overlay did not start');
  }

  Future<void> _onResult(Object? arguments) async {
    final map = Map<String, dynamic>.from(arguments! as Map);
    final action = map['action'] as String;
    if (action == 'shown') {
      _onShown?.call();
      _onShown = null;
      return;
    }
    _result?.complete((action: action, png: map['png'] as Uint8List?));
    _result = null;
  }

  /// Draws the screen, out of sight.
  void load(
    ScreenshotPicture picture, {
    required bool dark,
    required String locale,
  }) {
    _picture = picture;
    _loading = () async {
      await prepare();
      final me = await WindowController.fromCurrentEngine();
      await _window!.invokeMethod<void>('load', {
        'host': me.windowId,
        'width': picture.width,
        'height': picture.height,
        'rgba': picture.rgba,
        'scale': picture.scale,
        'frame': picture.frame,
        'dark': dark,
        'locale': locale,
      });
    }();
  }

  /// [onShown] when it is on screen, and what was there before can go.
  Future<CaptureOutcome> open(
    List<double> selection, {
    required VoidCallback onShown,
  }) async {
    await _loading;
    _onShown = onShown;
    final result = _result = Completer<CaptureOutcome>();
    await _window!
        .invokeMethod<void>('open', selection)
        .timeout(const Duration(seconds: 8));
    return result.future;
  }

  /// After a save dialog that was cancelled: back to where it was.
  Future<CaptureOutcome> resume() async {
    final result = _result = Completer<CaptureOutcome>();
    await _window!.invokeMethod<void>('resume');
    return result.future;
  }

  /// It has been used, or was not needed. Never waits for an answer: the engine
  /// on the other side may be going, and a screenshot that is over must be over.
  void finish() {
    _picture = null;
    _loading = null;
    final window = _window;
    if (window == null) return;
    if (Platform.isMacOS) {
      _window = null;
      _preparing = null;
    }
    unawaited(
      window
          .invokeMethod<void>(Platform.isMacOS ? 'destroy' : 'finish')
          .catchError((Object _) {}),
    );
  }
}
