import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:whisper/helper/local.dart';

/// Owns one reusable child window in the existing Whisper process.
class CastPlaybackWindowBridge {
  CastPlaybackWindowBridge();

  static final shared = CastPlaybackWindowBridge();
  static const events = WindowMethodChannel(
    'whisper.cast_playback.events',
    mode: ChannelMode.unidirectional,
  );

  WindowController? _window;
  Completer<void>? _ready;
  Future<void>? _initializing;
  Future<void>? _creating;
  void Function(Map<String, dynamic>)? onEvent;
  bool get hasWindow => _window != null;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    await events.setMethodCallHandler((call) async {
      if (call.method != 'event' || call.arguments is! Map) return null;
      final event = Map<String, dynamic>.from(call.arguments as Map);
      if (event['name'] == 'ready') {
        // A child can become ready before createWindow returns to this engine.
        if (_window == null || event['windowId'] == _window!.windowId) {
          if (_ready?.isCompleted == false) _ready!.complete();
        }
      } else if (event['windowId'] == _window?.windowId) {
        onEvent?.call(event);
      }
      return null;
    });
    onWindowsChanged.listen((_) => unawaited(_checkWindow()));
  }

  Future<void> _checkWindow() async {
    final window = _window;
    if (window == null) return;
    final windows = await WindowController.getAll();
    if (identical(_window, window) &&
        !windows.any((candidate) => candidate.windowId == window.windowId)) {
      _window = null;
      _ready = null;
      onEvent?.call({'name': 'closed'});
    }
  }

  Future<void> _ensureWindow() async {
    await initialize();
    if (_window == null) {
      await (_creating ??= _createWindow());
    }
    await _ready?.future.timeout(const Duration(seconds: 15));
  }

  Future<void> _createWindow() async {
    _ready = Completer<void>();
    try {
      _window = await WindowController.create(
        const WindowConfiguration(
          hiddenAtLaunch: true,
          arguments: 'cast_playback',
        ),
      );
    } finally {
      _creating = null;
    }
  }

  Future<Map<String, dynamic>> command(
    String command, [
    Map<String, Object> data = const {},
  ]) async {
    await _ensureWindow();
    final result = await _window!.invokeMethod<Map>('cast_command', {
      'command': command,
      'data': data,
      'locale': await LocalSetting().localization(),
    });
    if (result == null) throw StateError('Missing playback response');
    final snapshot = Map<String, dynamic>.from(result['snapshot'] as Map);
    if (result['failed'] == true) {
      onEvent?.call({'name': 'state', 'snapshot': snapshot});
      throw StateError('Playback command failed');
    }
    return snapshot;
  }
}
