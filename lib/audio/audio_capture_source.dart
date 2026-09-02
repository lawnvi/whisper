import 'dart:async';
import 'dart:typed_data';

import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_diagnostics.dart';

typedef AudioPacketSink = void Function(AudioPacketFrame packet);

class AudioCaptureSource {
  AudioCaptureSource({
    required AudioCodec codec,
    required AudioPlatform platform,
    required AudioPacketSink onPacket,
    AudioShareDiagnostics? diagnostics,
  }) : _codec = codec,
       _platform = platform,
       _onPacket = onPacket,
       _diagnostics = diagnostics ?? AudioShareDiagnostics.shared;

  final AudioCodec _codec;
  final AudioPlatform _platform;
  final AudioPacketSink _onPacket;
  final AudioShareDiagnostics _diagnostics;
  StreamSubscription<PlatformPcmFrame>? _subscription;
  final _PcmSampleBuffer _pendingPcm = _PcmSampleBuffer();
  Int16List? _packetPcm;
  String _sessionId = '';
  int _nextPacketSequence = 0;
  int _pendingCaptureTimeMicros = 0;
  Future<void>? _startFuture;
  Future<void>? _stopFuture;
  bool _startInvoked = false;
  bool _stopRequested = false;
  bool _codecDisposed = false;

  Future<void> start({
    required String sessionId,
    required AudioStreamFormat format,
  }) {
    if (_startInvoked || _stopRequested) {
      return Future<void>.error(
        StateError('audio capture source is single-use'),
      );
    }
    _startInvoked = true;
    _sessionId = sessionId;
    _pendingPcm.clear();
    _packetPcm = null;
    _nextPacketSequence = 0;
    _pendingCaptureTimeMicros = 0;
    _subscription = _platform.captureFrames.listen(_handleFrame);
    _diagnostics.captureStarted(
      sessionId: sessionId,
      sampleRate: format.sampleRate,
      channels: format.channels,
    );
    return _startFuture = _platform.startCapture(
      sessionId: sessionId,
      format: format,
    );
  }

  Future<void> stop() {
    final existing = _stopFuture;
    if (existing != null) {
      return existing;
    }
    _stopRequested = true;
    final sessionId = _sessionId;
    _sessionId = '';
    final subscription = _subscription;
    _subscription = null;
    _pendingPcm.clear();
    _packetPcm = null;
    _pendingCaptureTimeMicros = 0;
    return _stopFuture = _stop(
      sessionId: sessionId,
      subscription: subscription,
    );
  }

  Future<void> _stop({
    required String sessionId,
    required StreamSubscription<PlatformPcmFrame>? subscription,
  }) async {
    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    try {
      await subscription?.cancel();
    } catch (error, stackTrace) {
      cleanupError = error;
      cleanupStackTrace = stackTrace;
    }
    try {
      await _startFuture;
    } catch (_) {
      // A partially created native capture still needs the stop below.
    }
    if (sessionId.isNotEmpty) {
      try {
        await _platform.stopCapture(sessionId: sessionId);
      } catch (error, stackTrace) {
        cleanupError ??= error;
        cleanupStackTrace ??= stackTrace;
      }
    }
    if (!_codecDisposed) {
      _codecDisposed = true;
      _codec.dispose();
    }
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError, cleanupStackTrace!);
    }
  }

  void _handleFrame(PlatformPcmFrame frame) {
    if (frame.sessionId != _sessionId) {
      return;
    }
    final channels = _codec.config.channels <= 0 ? 1 : _codec.config.channels;
    final samplesPerPacket = _codec.config.frameSize * channels;
    if (samplesPerPacket <= 0) {
      return;
    }
    _diagnostics.captureFrame(
      sessionId: frame.sessionId,
      nativeSequence: frame.sequence,
      samples: frame.pcm.length,
      sampleRate: frame.sampleRate,
      channels: frame.channels,
    );

    final convertedPcm = _convertToCodecFormat(frame);
    if (convertedPcm.isEmpty) {
      return;
    }
    if (_pendingPcm.isEmpty) {
      _pendingCaptureTimeMicros = frame.captureTimeMicros;
    }
    if (_pendingPcm.isEmpty && convertedPcm.length == samplesPerPacket) {
      _emitPacket(
        sessionId: frame.sessionId,
        pcm: convertedPcm,
        captureTimeMicros: _pendingCaptureTimeMicros,
      );
      _pendingCaptureTimeMicros = 0;
      return;
    }
    _pendingPcm.addAll(convertedPcm);

    while (_pendingPcm.length >= samplesPerPacket) {
      var packetPcm = _packetPcm;
      if (packetPcm == null || packetPcm.length != samplesPerPacket) {
        packetPcm = Int16List(samplesPerPacket);
        _packetPcm = packetPcm;
      }
      _pendingPcm.removeFirstInto(packetPcm);
      _emitPacket(
        sessionId: frame.sessionId,
        pcm: packetPcm,
        captureTimeMicros: _pendingCaptureTimeMicros,
      );
      _pendingCaptureTimeMicros = _pendingPcm.isEmpty
          ? 0
          : _pendingCaptureTimeMicros + _codec.config.frameDurationMs * 1000;
    }
  }

  void _emitPacket({
    required String sessionId,
    required Int16List pcm,
    required int captureTimeMicros,
  }) {
    final payload = _codec.encode(pcm);
    final sequence = _nextPacketSequence++;
    _onPacket(
      AudioPacketFrame(
        sessionId: sessionId,
        sequence: sequence,
        captureTimeMicros: captureTimeMicros,
        payload: payload,
      ),
    );
    _diagnostics.capturePacket(
      sessionId: sessionId,
      sequence: sequence,
      payloadBytes: payload.length,
    );
  }

  Int16List _convertToCodecFormat(PlatformPcmFrame frame) {
    final sourceChannels = frame.channels <= 0 ? 1 : frame.channels;
    final targetChannels = _codec.config.channels <= 0
        ? sourceChannels
        : _codec.config.channels;
    final sourceRate = frame.sampleRate <= 0
        ? _codec.config.sampleRate
        : frame.sampleRate;
    final targetRate = _codec.config.sampleRate <= 0
        ? sourceRate
        : _codec.config.sampleRate;
    final sourceFrameCount = frame.pcm.length ~/ sourceChannels;
    if (sourceFrameCount <= 0 || targetChannels <= 0) {
      return Int16List(0);
    }
    if (sourceRate == targetRate &&
        sourceChannels == targetChannels &&
        frame.pcm.length == sourceFrameCount * sourceChannels) {
      return frame.pcm;
    }

    final targetFrameCount = sourceRate == targetRate
        ? sourceFrameCount
        : (sourceFrameCount * targetRate / sourceRate).round();
    if (targetFrameCount <= 0) {
      return Int16List(0);
    }

    final output = Int16List(targetFrameCount * targetChannels);
    if (sourceRate == targetRate) {
      for (var frameIndex = 0; frameIndex < sourceFrameCount; frameIndex++) {
        final sourceOffset = frameIndex * sourceChannels;
        final targetOffset = frameIndex * targetChannels;
        for (var channel = 0; channel < targetChannels; channel++) {
          final sourceChannel = sourceChannels == 1
              ? 0
              : channel.clamp(0, sourceChannels - 1);
          output[targetOffset + channel] =
              frame.pcm[sourceOffset + sourceChannel];
        }
      }
      return output;
    }
    for (var targetFrame = 0; targetFrame < targetFrameCount; targetFrame++) {
      final sourcePosition = targetFrame * sourceRate / targetRate;
      final sourceFrameA = sourcePosition.floor().clamp(
        0,
        sourceFrameCount - 1,
      );
      final sourceFrameB = (sourceFrameA + 1).clamp(0, sourceFrameCount - 1);
      final fraction = sourcePosition - sourceFrameA;
      for (var channel = 0; channel < targetChannels; channel++) {
        final sampleA = _sampleAt(
          frame.pcm,
          sourceFrameA,
          sourceChannels,
          channel,
        );
        final sampleB = _sampleAt(
          frame.pcm,
          sourceFrameB,
          sourceChannels,
          channel,
        );
        output[targetFrame * targetChannels + channel] = _lerpInt16(
          sampleA,
          sampleB,
          fraction,
        );
      }
    }
    return output;
  }

  int _sampleAt(
    Int16List pcm,
    int frame,
    int sourceChannels,
    int targetChannel,
  ) {
    final sourceChannel = sourceChannels == 1
        ? 0
        : targetChannel.clamp(0, sourceChannels - 1);
    return pcm[frame * sourceChannels + sourceChannel];
  }

  int _lerpInt16(int a, int b, double fraction) {
    final value = a + (b - a) * fraction;
    return value.round().clamp(-32768, 32767);
  }
}

final class _PcmSampleBuffer {
  Int16List _storage = Int16List(0);
  int _head = 0;
  int _length = 0;

  int get length => _length;
  bool get isEmpty => _length == 0;

  void clear() {
    _head = 0;
    _length = 0;
  }

  void addAll(Int16List samples) {
    if (samples.isEmpty) {
      return;
    }
    _ensureCapacity(_length + samples.length);
    final tail = (_head + _length) % _storage.length;
    final firstLength = samples.length.clamp(0, _storage.length - tail);
    _storage.setRange(tail, tail + firstLength, samples);
    final remaining = samples.length - firstLength;
    if (remaining > 0) {
      _storage.setRange(0, remaining, samples, firstLength);
    }
    _length += samples.length;
  }

  void removeFirstInto(Int16List target) {
    if (target.length > _length) {
      throw StateError('not enough buffered PCM samples');
    }
    final firstLength = target.length.clamp(0, _storage.length - _head);
    target.setRange(0, firstLength, _storage, _head);
    final remaining = target.length - firstLength;
    if (remaining > 0) {
      target.setRange(firstLength, target.length, _storage);
    }
    _head = (_head + target.length) % _storage.length;
    _length -= target.length;
    if (_length == 0) {
      _head = 0;
    }
  }

  void _ensureCapacity(int requiredCapacity) {
    if (_storage.length >= requiredCapacity) {
      return;
    }
    var newCapacity = _storage.isEmpty ? 2048 : _storage.length * 2;
    while (newCapacity < requiredCapacity) {
      newCapacity *= 2;
    }
    final replacement = Int16List(newCapacity);
    if (_length > 0) {
      final firstLength = _length.clamp(0, _storage.length - _head);
      replacement.setRange(0, firstLength, _storage, _head);
      final remaining = _length - firstLength;
      if (remaining > 0) {
        replacement.setRange(firstLength, _length, _storage);
      }
    }
    _storage = replacement;
    _head = 0;
  }
}
