import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';

class AudioPlaybackSink {
  AudioPlaybackSink({
    required AudioCodec codec,
    required AudioPlatform platform,
  })  : _codec = codec,
        _platform = platform;

  final AudioCodec _codec;
  final AudioPlatform _platform;
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
      pcm: pcm,
    );
  }

  Future<void> stop() async {
    final sessionId = _sessionId;
    _sessionId = '';
    if (sessionId.isNotEmpty) {
      await _platform.stopPlayback(sessionId: sessionId);
    }
    _codec.dispose();
  }
}
