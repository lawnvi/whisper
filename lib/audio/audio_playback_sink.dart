import 'dart:typed_data';

import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';

class AudioPlaybackSink {
  AudioPlaybackSink({
    required AudioCodec codec,
    required AudioPlatform platform,
    double playbackGain = 1.0,
  })  : _codec = codec,
        _platform = platform,
        _playbackGain = normalizePlaybackGain(playbackGain);

  static double normalizePlaybackGain(double gain) {
    if (!gain.isFinite) {
      return 1.0;
    }
    return gain.clamp(1.0, 3.0).toDouble();
  }

  final AudioCodec _codec;
  final AudioPlatform _platform;
  double _playbackGain;
  String _sessionId = '';

  Future<void> start({
    required String sessionId,
    required AudioStreamFormat format,
  }) async {
    _sessionId = sessionId;
    await _platform.startPlayback(
      sessionId: sessionId,
      format: format,
    );
  }

  Future<void> handlePacket(AudioPacketFrame packet) async {
    if (packet.sessionId != _sessionId) {
      return;
    }
    final pcm = _codec.decode(packet.payload);
    await _platform.writePcm(
      sessionId: packet.sessionId,
      pcm: _applyPlaybackGain(pcm),
    );
  }

  void updatePlaybackGain(double gain) {
    _playbackGain = normalizePlaybackGain(gain);
  }

  Future<void> stop() async {
    final sessionId = _sessionId;
    _sessionId = '';
    if (sessionId.isNotEmpty) {
      await _platform.stopPlayback(sessionId: sessionId);
    }
    _codec.dispose();
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
