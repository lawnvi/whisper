import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_protocol.dart';

void main() {
  group('AudioCodecConfig', () {
    test('derives Opus stream format and frame size', () {
      const config = AudioCodecConfig(
        sampleRate: 48000,
        channels: 2,
        frameDurationMs: 20,
        bitRate: 128000,
      );

      expect(config.frameSize, 960);
      expect(
        config.toStreamFormat(),
        const AudioStreamFormat(
          codec: AudioCodecKind.opus,
          sampleRate: 48000,
          channels: 2,
          frameDurationMs: 20,
          bitRate: 128000,
        ),
      );
    });
  });

  group('PcmPassthroughAudioCodec', () {
    test('encodes and decodes signed 16-bit PCM frames without loss', () {
      final codec = PcmPassthroughAudioCodec(
        const AudioCodecConfig(
          sampleRate: 48000,
          channels: 2,
          frameDurationMs: 20,
          bitRate: 128000,
        ),
      );
      final pcm = Int16List.fromList(<int>[0, 1, -1, 32767, -32768]);

      final encoded = codec.encode(pcm);
      final decoded = codec.decode(encoded);

      expect(decoded, pcm);
      codec.dispose();
    });

    test('rejects odd byte counts when decoding PCM packets', () {
      final codec = PcmPassthroughAudioCodec(
        const AudioCodecConfig(
          sampleRate: 48000,
          channels: 2,
          frameDurationMs: 20,
          bitRate: 128000,
        ),
      );

      expect(
        () => codec.decode(Uint8List.fromList(<int>[1, 2, 3])),
        throwsA(isA<FormatException>()),
      );
      codec.dispose();
    });
  });
}
