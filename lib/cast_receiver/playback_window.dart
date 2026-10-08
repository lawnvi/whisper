import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:whisper/helper/local.dart';

/// Owns one reusable child window in the existing Whisper process.
class PlaybackWindowBridge {
  PlaybackWindowBridge({this.localVideo = false});

  static final shared = PlaybackWindowBridge();
  static final videos = PlaybackWindowBridge(localVideo: true);
  final bool localVideo;
  static WindowMethodChannel eventsFor({bool localVideo = false}) =>
      WindowMethodChannel(
        localVideo
            ? 'whisper.video_playback.events'
            : 'whisper.cast_playback.events',
        mode: ChannelMode.unidirectional,
      );

  late final events = eventsFor(localVideo: localVideo);
  Future<void> _opening = Future<void>.value();

  Future<void> openVideo(String path, String name) {
    final opening = _opening.then((_) async {
      await command('load', {
        'url': Uri.file(path).toString(),
        'metadata': name,
      });
      await command('play');
    });
    _opening = opening.catchError((Object _) {});
    return opening;
  }

  Future<void> close() async {
    await _opening;
    if (hasWindow) await command('shutdown');
  }

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
        WindowConfiguration(
          hiddenAtLaunch: true,
          arguments: localVideo ? 'video_playback' : 'cast_playback',
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
