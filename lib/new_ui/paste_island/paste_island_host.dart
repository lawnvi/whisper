import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/main_window_calls.dart';
import 'package:whisper/new_ui/paste_island/paste_island_app.dart';
import 'package:whisper/remote_input/remote_clipboard_paste_watch.dart';

/// The main engine's end of the floating island: makes its window the first
/// time a paste has to wait for its files, and tells it how they come. The
/// window is an engine of its own, so it is only made when wanted.
class PasteIslandHost {
  PasteIslandHost({
    required RemoteClipboardPasteWatch watch,
    required String Function(String peerId) deviceName,
    required String Function() locale,
  }) : _watch = watch,
       _deviceName = deviceName,
       _locale = locale {
    _watch.addListener(_changed);
    MainWindowCalls.on('pasteIsland', _onCall);
  }

  final RemoteClipboardPasteWatch _watch;
  final String Function(String peerId) _deviceName;
  final String Function() _locale;

  WindowController? _window;
  Future<void>? _starting;
  String? _myId;
  bool _ready = false;
  bool _sending = false;
  bool _again = false;

  void dispose() => _watch.removeListener(_changed);

  void _changed() {
    if (_watch.current == null) return;
    unawaited(_push());
  }

  /// The latest state, one call at a time: progress comes four times a second.
  Future<void> _push() async {
    if (_sending) {
      _again = true;
      return;
    }
    _sending = true;
    try {
      do {
        _again = false;
        await (_starting ??= _start());
        final paste = _watch.current;
        final window = _window;
        if (!_ready || paste == null || window == null) return;
        await window.invokeMethod<void>('state', {
          'host': _myId,
          'locale': _locale(),
          'device': _deviceName(paste.peerId),
          'paste': paste.toMap(),
        });
      } while (_again);
    } on Object {
      // The window went away: the paste goes on without it.
    } finally {
      _sending = false;
    }
  }

  Future<void> _start() async {
    // Its engine needs only a few plugins, like the tray panel's.
    if (Platform.isWindows) {
      try {
        await const MethodChannel(
          'com.vireen.whisper/window_theme',
        ).invokeMethod<void>('nextWindowIsPanel');
      } on Object {
        // An older runner registers everything.
      }
    }
    final window = await WindowController.create(
      const WindowConfiguration(
        hiddenAtLaunch: true,
        arguments: pasteIslandArgument,
      ),
    );
    _window = window;
    _myId = (await WindowController.fromCurrentEngine()).windowId;
    for (var i = 0; i < 100; i++) {
      try {
        await window
            .invokeMethod<Object?>('ping', 0)
            .timeout(const Duration(milliseconds: 200));
        _ready = true;
        break;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> _onCall(Object? arguments) async {
    final action = (arguments as Map?)?['action'];
    if (action == 'cancel') _watch.cancel();
  }
}
