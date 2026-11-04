import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:whisper/helper/main_window_calls.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:whisper/new_ui/tray/tray_model.dart';
import 'package:whisper/new_ui/tray/tray_panel.dart';
import 'package:window_manager/window_manager.dart';

/// The main engine's end of the tray panel: owns the window, puts it under (or
/// on Windows, above) the tray icon, keeps it up to date, carries out what it
/// asks for. Created when the app starts, hidden: making the window takes over a
/// second, which clicking the icon should not have to wait for.
class TrayPanelHost {
  TrayPanelHost({required this.onAction});

  final void Function(String action, Object? value) onAction;

  WindowController? _window;
  bool _visible = false;
  TrayState _state = const TrayState();
  String? _myId;

  /// The panel's engine answers: until then there is no one to send state to.
  bool _ready = false;

  Map<String, Object?> get _stateMap => {..._state.toMap(), 'host': _myId};

  static const _margin = 10.0, _rightMargin = 12.0;

  Future<void>? _starting;

  /// The panel is an engine of its own, tens of MB. It is made the first time it
  /// is wanted.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (!trayPanelSupported) return;
    // Its engine only needs a few plugins, and on Windows must not get them all.
    if (Platform.isWindows) {
      try {
        await const MethodChannel(
          'com.vireen.whisper/window_theme',
        ).invokeMethod<void>('nextWindowIsPanel');
      } on Object {
        // An older runner: it registers everything, as before.
      }
    }
    final window = await WindowController.create(
      const WindowConfiguration(
        hiddenAtLaunch: true,
        arguments: trayPanelArgument,
      ),
    );
    _window = window;
    final me = await WindowController.fromCurrentEngine();
    _myId = me.windowId;
    MainWindowCalls.on('trayAction', _onCall);
    // The child's engine takes a moment; it answers once its handler is up.
    for (var i = 0; i < 100; i++) {
      try {
        await window
            .invokeMethod<Object?>('ping', 0)
            .timeout(const Duration(milliseconds: 200));
        break;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    _ready = true;
    await window.invokeMethod<void>('state', _stateMap);
    // One frame to measure itself in, or it opens at the wrong height.
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  Future<void> _onCall(Object? arguments) async {
    final args = Map<String, dynamic>.from(arguments! as Map);
    final action = args['action'] as String;
    if (action == 'closed') {
      _visible = false;
      return;
    }
    onAction(action, args['value']);
  }

  void update(TrayState state) {
    _state = state;
    if (!_ready) return;
    unawaited(
      _window?.invokeMethod<void>('state', _stateMap).catchError((Object _) {}),
    );
  }

  Future<void> toggle() async {
    final window = _window;
    if (window == null || !_ready) return;
    if (_visible) {
      _visible = false;
      await window.invokeMethod<void>('hide');
      return;
    }
    final bounds = await trayManager.getBounds();
    final screen = await windowManager.getBounds();
    final up = Platform.isWindows;
    const width = 340.0;
    final centre = (bounds?.left ?? screen.right) + (bounds?.width ?? 0) / 2;
    await window.invokeMethod<void>('showAt', {
      'x': up
          ? (bounds?.right ?? screen.right) - width + _rightMargin
          : centre - width / 2,
      'y': up
          ? (bounds?.top ?? screen.bottom) - _margin
          : (bounds?.bottom ?? 30) + 6,
      'up': up,
      'maxHeight': 800.0,
    });
    _visible = true;
  }

  Future<void> hide() async {
    if (!_visible) return;
    _visible = false;
    await _window?.invokeMethod<void>('hide');
  }
}
