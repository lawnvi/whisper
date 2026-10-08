import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'playback_engine.dart';
import 'playback_window.dart';

/// Serializes phone and local controls against the same in-app player.
class CastPlayer extends ChangeNotifier {
  CastPlayer({
    Future<CastPlaybackEngine> Function()? engineFactory,
    Future<void> Function()? revealWindow,
    PlaybackWindowBridge? windowBridge,
  }) : _engineFactory = engineFactory ?? (() async => MediaKitCastEngine()),
       _revealWindow = revealWindow,
       _windowBridge = windowBridge {
    _windowBridge?.onEvent = _handleWindowEvent;
  }

  static final shared = CastPlayer(windowBridge: PlaybackWindowBridge.shared);
  final Future<CastPlaybackEngine> Function() _engineFactory;
  final Future<void> Function()? _revealWindow;
  final PlaybackWindowBridge? _windowBridge;
  CastPlaybackEngine? _engine;
  StreamSubscription<void>? _events;
  Future<void> _pending = Future<void>.value();
  bool _accepting = false;
  bool _visible = false;
  bool _paused = false;
  String _uri = '';
  String _metadata = '';

  final status = <String, dynamic>{
    'state': 'NO_MEDIA_PRESENT',
    'position': 0.0,
    'duration': 0.0,
    'volume': 1.0,
    'muted': false,
    'ready': false,
    'error': '',
  };

  bool get visible => _visible;
  String get uri => _uri;
  String get metadata => _metadata;
  bool get paused => _paused;
  VideoController? get videoController => _engine?.videoController;

  Map<String, Object> get snapshot => {
    'status': Map<String, dynamic>.of(status),
    'visible': _visible,
    'paused': _paused,
    'uri': _uri,
    'metadata': _metadata,
  };

  void _applySnapshot(Map<String, dynamic> snapshot) {
    status.addAll(Map<String, dynamic>.from(snapshot['status'] as Map));
    _visible = snapshot['visible'] == true;
    _paused = snapshot['paused'] == true;
    _uri = snapshot['uri'] as String;
    _metadata = snapshot['metadata'] as String;
    notifyListeners();
  }

  void _handleWindowEvent(Map<String, dynamic> event) {
    if (!_accepting) return;
    if (event['name'] == 'closed') {
      _visible = false;
      _reset(_uri.isEmpty ? 'NO_MEDIA_PRESENT' : 'STOPPED');
      notifyListeners();
    } else if (event['name'] == 'state') {
      _applySnapshot(Map<String, dynamic>.from(event['snapshot'] as Map));
    }
  }

  Future<void> _commandInWindow(
    String command,
    Map<String, Object> data,
  ) async {
    final bridge = _windowBridge!;
    if (command == 'stop' && !bridge.hasWindow) return;
    if (command == 'play') {
      if (_uri.isEmpty) throw StateError('No media');
      // Only a destroyed window needs its media restored. Resume in the same
      // window must not load the URI again or lose the playback position.
      if (!bridge.hasWindow) {
        await bridge.command('load', {'url': _uri, 'metadata': _metadata});
        await bridge.command('volume', {'value': status['volume'] as double});
        await bridge.command('mute', {'value': status['muted'] == true});
      }
    }
    final snapshot = await bridge.command(command, data);
    if (_accepting) _applySnapshot(snapshot);
  }

  void activate() => _accepting = true;

  Future<void> command(String command, [Map<String, Object> data = const {}]) =>
      _enqueue(() async {
        if (!_accepting) throw StateError('Receiver stopped');
        if (_windowBridge != null) return _commandInWindow(command, data);
        switch (command) {
          case 'load':
            await _releaseEngine();
            _uri = data['url'] as String;
            _metadata = data['metadata'] as String? ?? '';
            _reset('STOPPED');
          case 'play':
            if (_uri.isEmpty) throw StateError('No media');
            _paused = false;
            if (_engine == null || status['error'] != '') {
              await _releaseEngine();
              // VideoController initializes after a Flutter frame, which an
              // occluded desktop window may withhold until it becomes visible.
              await _revealWindow?.call();
              if (!_accepting) return;
              _visible = true;
              status['state'] = 'TRANSITIONING';
              status['error'] = '';
              notifyListeners();
              try {
                final engine = await _engineFactory();
                if (!_accepting) {
                  await engine.dispose();
                  return;
                }
                _engine = engine;
                _events = engine.changes.listen((_) => _syncState());
                notifyListeners();
                await engine.setVolume(_effectiveVolume);
                await engine.open(_uri);
              } on Object {
                await _releaseEngine();
                _visible = _accepting;
                _reset('STOPPED');
                status['error'] = 'playback_failed';
                notifyListeners();
                rethrow;
              }
            } else {
              _syncState();
              await _engine!.play();
            }
            _syncState();
          case 'pause':
            if (_engine == null) throw StateError('No active media');
            _paused = true;
            // Publish the intent before the platform player acknowledges it;
            // media-kit can take a noticeable moment to cross the native
            // boundary, while the phone expects the transport state quickly.
            _syncState();
            try {
              await _engine!.pause();
            } on Object {
              _paused = false;
              _syncState();
              rethrow;
            }
            _syncState();
          case 'stop':
            await _releaseEngine();
            _reset(_uri.isEmpty ? 'NO_MEDIA_PRESENT' : 'STOPPED');
          case 'seek':
            if (_engine == null) throw StateError('No active media');
            final seconds = (data['seconds'] as num).toDouble();
            if (!seconds.isFinite || seconds < 0) {
              throw ArgumentError.value(seconds, 'seconds');
            }
            await _engine!.seek(
              Duration(
                microseconds: (seconds * Duration.microsecondsPerSecond)
                    .round(),
              ),
            );
            _syncState();
          case 'volume':
            final value = (data['value'] as num).toDouble();
            if (!value.isFinite || value < 0 || value > 1) {
              throw ArgumentError.value(value, 'volume');
            }
            await _engine?.setVolume(status['muted'] == true ? 0 : value);
            status['volume'] = value;
          case 'mute':
            final muted = data['value'] == true;
            await _engine?.setVolume(muted ? 0 : status['volume'] as double);
            status['muted'] = muted;
          default:
            throw ArgumentError.value(command, 'command');
        }
        notifyListeners();
      });

  double get _effectiveVolume =>
      status['muted'] == true ? 0 : status['volume'] as double;

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.catchError((Object _) {});
    return result;
  }

  void _syncState() {
    final engine = _engine;
    if (engine == null) return;
    final state = engine.state;
    status
      ..['position'] =
          state.position.inMicroseconds / Duration.microsecondsPerSecond
      ..['duration'] =
          state.duration.inMicroseconds / Duration.microsecondsPerSecond
      ..['ready'] = !state.buffering && !state.failed
      ..['error'] = state.failed ? 'playback_failed' : ''
      ..['state'] = state.failed || state.completed
          ? 'STOPPED'
          : _paused
          ? 'PAUSED_PLAYBACK'
          : state.buffering || !state.playing
          ? 'TRANSITIONING'
          : 'PLAYING';
    notifyListeners();
  }

  void _reset(String state) {
    _paused = false;
    status
      ..['state'] = state
      ..['position'] = 0.0
      ..['duration'] = 0.0
      ..['ready'] = false
      ..['error'] = '';
  }

  Future<void> _releaseEngine() async {
    _visible = false;
    final engine = _engine;
    _engine = null;
    notifyListeners();
    await _events?.cancel();
    _events = null;
    await engine?.dispose();
  }

  /// Stop accepting new commands immediately, then drain and release playback.
  Future<void> close() {
    _accepting = false;
    return _enqueue(() async {
      try {
        if (_windowBridge case final bridge? when bridge.hasWindow) {
          await bridge.command('shutdown');
        }
      } finally {
        await _releaseEngine();
        _uri = '';
        _metadata = '';
        _reset('NO_MEDIA_PRESENT');
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _windowBridge?.onEvent = null;
    super.dispose();
  }
}
