import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';

typedef AudioPlaybackWriteFailure = void Function(
  Object error,
  StackTrace stackTrace,
);

class AudioPlaybackSink {
  AudioPlaybackSink({
    required AudioCodec codec,
    required AudioPlatform platform,
    double playbackGain = 1.0,
    this.onWriteFailure,
    this.maxBufferedItems = 8,
    this.maxBufferedBytes = 2 * 1024 * 1024,
    this.maxBufferedDuration = const Duration(milliseconds: 160),
  })  : _codec = codec,
        _platform = platform,
        _playbackGain = normalizePlaybackGain(playbackGain) {
    if (maxBufferedItems <= 0 ||
        maxBufferedBytes <= 0 ||
        maxBufferedDuration <= Duration.zero) {
      throw ArgumentError('playback buffer limits must be positive');
    }
  }

  static double normalizePlaybackGain(double gain) {
    if (!gain.isFinite) {
      return 1.0;
    }
    return gain.clamp(1.0, 3.0).toDouble();
  }

  final AudioCodec _codec;
  final AudioPlatform _platform;
  final int maxBufferedItems;
  final int maxBufferedBytes;
  final Duration maxBufferedDuration;
  final AudioPlaybackWriteFailure? onWriteFailure;
  final Queue<_QueuedPcmWrite> _queue = Queue<_QueuedPcmWrite>();
  double _playbackGain;
  String _sessionId = '';
  int _frameDurationMicros = 0;
  int _queuedBytes = 0;
  int _queuedDurationMicros = 0;
  int _droppedPackets = 0;
  int _generation = 0;
  bool _started = false;
  bool _accepting = false;
  bool _writeInFlight = false;
  bool _codecDisposed = false;
  bool _writeFailureReported = false;
  _QueuedPcmWrite? _activeWrite;
  Completer<void>? _idleCompleter;
  Future<void>? _stopFuture;

  int get bufferedItems => _queue.length + (_activeWrite == null ? 0 : 1);
  int get bufferedBytes =>
      _queuedBytes + (_activeWrite?.pcm.lengthInBytes ?? 0);
  Duration get bufferedDuration => Duration(
        microseconds:
            _queuedDurationMicros + (_activeWrite?.durationMicros ?? 0),
      );
  int get droppedPackets => _droppedPackets;
  bool get isWriteInFlight => _writeInFlight;

  Future<void> start({
    required String sessionId,
    required AudioStreamFormat format,
  }) async {
    if (_started || _stopFuture != null || _codecDisposed) {
      throw StateError('audio playback sink is single-use');
    }
    _started = true;
    _generation += 1;
    _sessionId = sessionId;
    _frameDurationMicros = format.frameDurationMs.clamp(1, 1000) *
        Duration.microsecondsPerMillisecond;
    _accepting = true;
    _droppedPackets = 0;
    await _platform.startPlayback(
      sessionId: sessionId,
      format: format,
    );
  }

  void enqueuePacket(AudioPacketFrame packet) {
    if (!_accepting || packet.sessionId != _sessionId) {
      return;
    }
    final pcm = _applyPlaybackGain(_codec.decode(packet.payload));
    _enqueue(
      _QueuedPcmWrite(
        sessionId: packet.sessionId,
        pcm: pcm,
        durationMicros: _frameDurationMicros,
      ),
    );
  }

  Future<void> handlePacket(AudioPacketFrame packet) {
    if (!_accepting || packet.sessionId != _sessionId) {
      return Future<void>.value();
    }
    try {
      final completer = Completer<void>();
      final pcm = _applyPlaybackGain(_codec.decode(packet.payload));
      _enqueue(
        _QueuedPcmWrite(
          sessionId: packet.sessionId,
          pcm: pcm,
          durationMicros: _frameDurationMicros,
          completion: completer,
        ),
      );
      return completer.future;
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
  }

  void updatePlaybackGain(double gain) {
    _playbackGain = normalizePlaybackGain(gain);
  }

  Future<void> waitForIdle() {
    if (_activeWrite == null && _queue.isEmpty) {
      return Future<void>.value();
    }
    return (_idleCompleter ??= Completer<void>()).future;
  }

  Future<void> stop() {
    final existing = _stopFuture;
    if (existing != null) {
      return existing;
    }
    return _stopFuture = _stop();
  }

  Future<void> _stop() async {
    final sessionId = _sessionId;
    _generation += 1;
    _sessionId = '';
    _accepting = false;
    while (_queue.isNotEmpty) {
      _dropOldest(countDrop: false);
    }
    final active = _activeWrite;
    _activeWrite = null;
    _writeInFlight = false;
    _completeWrite(active);
    _completeIdle();
    if (sessionId.isNotEmpty) {
      await _platform.stopPlayback(sessionId: sessionId);
    }
    if (!_codecDisposed) {
      _codecDisposed = true;
      _codec.dispose();
    }
  }

  void _enqueue(_QueuedPcmWrite item) {
    while (_wouldOverflow(item) && _queue.isNotEmpty) {
      _dropOldest();
    }
    if (_wouldOverflow(item)) {
      _drop(item);
      return;
    }
    _queue.addLast(item);
    _queuedBytes += item.pcm.lengthInBytes;
    _queuedDurationMicros += item.durationMicros;
    _startPump();
  }

  bool _wouldOverflow(_QueuedPcmWrite item) {
    return bufferedItems >= maxBufferedItems ||
        item.pcm.lengthInBytes > maxBufferedBytes - bufferedBytes ||
        item.durationMicros >
            maxBufferedDuration.inMicroseconds -
                bufferedDuration.inMicroseconds;
  }

  void _dropOldest({bool countDrop = true}) {
    final item = _queue.removeFirst();
    _queuedBytes -= item.pcm.lengthInBytes;
    _queuedDurationMicros -= item.durationMicros;
    _drop(item, countDrop: countDrop);
  }

  void _drop(_QueuedPcmWrite item, {bool countDrop = true}) {
    if (countDrop) {
      _droppedPackets += 1;
    }
    _completeWrite(item);
  }

  void _startPump() {
    if (_writeInFlight || !_accepting || _queue.isEmpty) {
      return;
    }
    final generation = _generation;
    final item = _queue.removeFirst();
    _queuedBytes -= item.pcm.lengthInBytes;
    _queuedDurationMicros -= item.durationMicros;
    _activeWrite = item;
    _writeInFlight = true;
    unawaited(_write(item, generation));
  }

  Future<void> _write(_QueuedPcmWrite item, int generation) async {
    try {
      await _platform.writePcm(
        sessionId: item.sessionId,
        pcm: item.pcm,
      );
      _completeWrite(item);
    } catch (error, stackTrace) {
      _completeWrite(item, error: error, stackTrace: stackTrace);
      if (!_writeFailureReported) {
        _writeFailureReported = true;
        _accepting = false;
        while (_queue.isNotEmpty) {
          _dropOldest(countDrop: false);
        }
        try {
          onWriteFailure?.call(error, stackTrace);
        } catch (_) {}
      }
    } finally {
      if (generation == _generation && identical(_activeWrite, item)) {
        _activeWrite = null;
        _writeInFlight = false;
        if (_queue.isEmpty) {
          _completeIdle();
        } else {
          _startPump();
        }
      }
    }
  }

  void _completeWrite(
    _QueuedPcmWrite? item, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final completion = item?.completion;
    if (completion == null || completion.isCompleted) {
      return;
    }
    if (error == null) {
      completion.complete();
    } else {
      completion.completeError(error, stackTrace);
    }
  }

  void _completeIdle() {
    final completer = _idleCompleter;
    _idleCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  Int16List _applyPlaybackGain(Int16List pcm) {
    if (_playbackGain == 1.0) {
      return pcm;
    }
    final amplified = Int16List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      amplified[i] =
          (pcm[i] * _playbackGain).round().clamp(-32768, 32767).toInt();
    }
    return amplified;
  }
}

final class _QueuedPcmWrite {
  const _QueuedPcmWrite({
    required this.sessionId,
    required this.pcm,
    required this.durationMicros,
    this.completion,
  });

  final String sessionId;
  final Int16List pcm;
  final int durationMicros;
  final Completer<void>? completion;
}
