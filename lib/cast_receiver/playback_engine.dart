import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class CastPlaybackState {
  const CastPlaybackState({
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.failed = false,
  });

  final bool playing;
  final bool buffering;
  final bool completed;
  final Duration position;
  final Duration duration;
  final bool failed;
}

abstract class CastPlaybackEngine {
  VideoController? get videoController;
  CastPlaybackState get state;
  Stream<void> get changes;
  Future<void> open(String uri);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> dispose();
}

/// Created only when media starts; no separate app, window or player process.
class MediaKitCastEngine implements CastPlaybackEngine {
  MediaKitCastEngine() {
    MediaKit.ensureInitialized();
    _player = Player(
      configuration: const PlayerConfiguration(
        title: 'Whisper',
        bufferSize: 16 * 1024 * 1024,
      ),
    );
    videoController = VideoController(_player);
    _subscriptions.addAll([
      _player.stream.playing.listen((_) => _emit()),
      _player.stream.buffering.listen((_) => _emit()),
      _player.stream.completed.listen((_) => _emit()),
      _player.stream.position.listen((_) => _emit()),
      _player.stream.duration.listen((_) => _emit()),
      _player.stream.error.listen((_) {
        _failed = true;
        _emit();
      }),
    ]);
  }

  late final Player _player;
  @override
  late final VideoController videoController;
  final _changes = StreamController<void>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _failed = false;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  CastPlaybackState get state => CastPlaybackState(
    playing: _player.state.playing,
    buffering: _player.state.buffering,
    completed: _player.state.completed,
    position: _player.state.position,
    duration: _player.state.duration,
    failed: _failed,
  );

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> open(String uri) async {
    _failed = false;
    await _player.open(Media(uri));
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume * 100);

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    await _changes.close();
  }
}
