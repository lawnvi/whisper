import 'dart:async';
import 'dart:typed_data';

import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';

typedef AudioPacketSink = void Function(AudioPacketFrame packet);

class AudioCaptureSource {
  AudioCaptureSource({
    required AudioCodec codec,
    required AudioPlatform platform,
    required AudioPacketSink onPacket,
  })  : _codec = codec,
        _platform = platform,
        _onPacket = onPacket;

  final AudioCodec _codec;
  final AudioPlatform _platform;
  final AudioPacketSink _onPacket;
  StreamSubscription<PlatformPcmFrame>? _subscription;
  final List<int> _pendingPcm = <int>[];
  String _sessionId = '';
  int _nextPacketSequence = 0;
  int _pendingCaptureTimeMicros = 0;

  Future<void> start({
    required String sessionId,
    required AudioStreamFormat format,
  }) async {
    await _subscription?.cancel();
    _sessionId = sessionId;
    _pendingPcm.clear();
    _nextPacketSequence = 0;
    _pendingCaptureTimeMicros = 0;
    _subscription = _platform.captureFrames.listen(_handleFrame);
    await _platform.startCapture(sessionId: sessionId, format: format);
  }

  Future<void> stop() async {
    final sessionId = _sessionId;
    _sessionId = '';
    await _subscription?.cancel();
    _subscription = null;
    _pendingPcm.clear();
    _pendingCaptureTimeMicros = 0;
    if (sessionId.isNotEmpty) {
      await _platform.stopCapture(sessionId: sessionId);
    }
    _codec.dispose();
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

    final convertedPcm = _convertToCodecFormat(frame);
    if (convertedPcm.isEmpty) {
      return;
    }
    if (_pendingPcm.isEmpty) {
      _pendingCaptureTimeMicros = frame.captureTimeMicros;
    }
    _pendingPcm.addAll(convertedPcm);

    while (_pendingPcm.length >= samplesPerPacket) {
      final packetPcm = Int16List.fromList(
        _pendingPcm.sublist(0, samplesPerPacket),
      );
      _pendingPcm.removeRange(0, samplesPerPacket);
      _onPacket(
        AudioPacketFrame(
          sessionId: frame.sessionId,
          sequence: _nextPacketSequence++,
          captureTimeMicros: _pendingCaptureTimeMicros,
          payload: _codec.encode(packetPcm),
        ),
      );
      _pendingCaptureTimeMicros = _pendingPcm.isEmpty
          ? 0
          : _pendingCaptureTimeMicros + _codec.config.frameDurationMs * 1000;
    }
  }

  Int16List _convertToCodecFormat(PlatformPcmFrame frame) {
    final sourceChannels = frame.channels <= 0 ? 1 : frame.channels;
    final targetChannels =
        _codec.config.channels <= 0 ? sourceChannels : _codec.config.channels;
    final sourceRate =
        frame.sampleRate <= 0 ? _codec.config.sampleRate : frame.sampleRate;
    final targetRate =
        _codec.config.sampleRate <= 0 ? sourceRate : _codec.config.sampleRate;
    final sourceFrameCount = frame.pcm.length ~/ sourceChannels;
    if (sourceFrameCount <= 0 || targetChannels <= 0) {
      return Int16List(0);
    }

    final targetFrameCount = sourceRate == targetRate
        ? sourceFrameCount
        : (sourceFrameCount * targetRate / sourceRate).round();
    if (targetFrameCount <= 0) {
      return Int16List(0);
    }

    final output = Int16List(targetFrameCount * targetChannels);
    for (var targetFrame = 0; targetFrame < targetFrameCount; targetFrame++) {
      final sourcePosition = sourceRate == targetRate
          ? targetFrame.toDouble()
          : targetFrame * sourceRate / targetRate;
      final sourceFrameA =
          sourcePosition.floor().clamp(0, sourceFrameCount - 1);
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
    final sourceChannel =
        sourceChannels == 1 ? 0 : targetChannel.clamp(0, sourceChannels - 1);
    return pcm[frame * sourceChannels + sourceChannel];
  }

  int _lerpInt16(int a, int b, double fraction) {
    final value = a + (b - a) * fraction;
    return value.round().clamp(-32768, 32767);
  }
}
