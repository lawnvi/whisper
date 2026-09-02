import 'dart:typed_data';

import 'package:opus_codec/opus_codec.dart' as opus_loader;
import 'package:opus_codec_dart/opus_codec_dart.dart' as opus;
import 'package:whisper/audio/audio_protocol.dart';

class AudioCodecConfig {
  const AudioCodecConfig({
    required this.sampleRate,
    required this.channels,
    required this.frameDurationMs,
    required this.bitRate,
  });

  final int sampleRate;
  final int channels;
  final int frameDurationMs;
  final int bitRate;

  factory AudioCodecConfig.fromStreamFormat(AudioStreamFormat format) {
    return AudioCodecConfig(
      sampleRate: format.sampleRate,
      channels: format.channels,
      frameDurationMs: format.frameDurationMs,
      bitRate: format.bitRate,
    );
  }

  int get frameSize => sampleRate * frameDurationMs ~/ 1000;

  AudioStreamFormat toStreamFormat({
    AudioCodecKind codec = AudioCodecKind.opus,
  }) {
    return AudioStreamFormat(
      codec: codec,
      sampleRate: sampleRate,
      channels: channels,
      frameDurationMs: frameDurationMs,
      bitRate: bitRate,
    );
  }
}

abstract class AudioCodec {
  AudioCodecConfig get config;

  Uint8List encode(Int16List pcm);

  Int16List decode(Uint8List packet);

  void dispose();
}

class PcmPassthroughAudioCodec implements AudioCodec {
  PcmPassthroughAudioCodec(this.config);

  @override
  final AudioCodecConfig config;

  @override
  Uint8List encode(Int16List pcm) {
    final bytes = Uint8List(pcm.length * 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < pcm.length; i++) {
      data.setInt16(i * 2, pcm[i], Endian.little);
    }
    return bytes;
  }

  @override
  Int16List decode(Uint8List packet) {
    if (packet.length.isOdd) {
      throw const FormatException('PCM packet byte length must be even');
    }
    final data = ByteData.sublistView(packet);
    final pcm = Int16List(packet.length ~/ 2);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = data.getInt16(i * 2, Endian.little);
    }
    return pcm;
  }

  @override
  void dispose() {}
}

class OpusAudioCodec implements AudioCodec {
  OpusAudioCodec._({
    required this.config,
    required opus.BufferedOpusEncoder encoder,
    required opus.SimpleOpusDecoder decoder,
  }) : _encoder = encoder,
       _encoderInput = encoder.inputBuffer,
       _decoder = decoder;

  static Future<OpusAudioCodec> create(AudioCodecConfig config) async {
    await _ensureInitialized();
    return OpusAudioCodec._(
      config: config,
      encoder: opus.BufferedOpusEncoder(
        sampleRate: config.sampleRate,
        channels: config.channels,
        application: opus.Application.audio,
        maxInputBufferSizeBytes:
            opus.bytesPerInt16Sample *
            opus.maxSamplesPerPacket(config.sampleRate, config.channels),
      ),
      decoder: opus.SimpleOpusDecoder(
        sampleRate: config.sampleRate,
        channels: config.channels,
      ),
    );
  }

  static Future<void> _ensureInitialized() {
    return _initialization ??= opus_loader.load().then(opus.initOpus);
  }

  static Future<void>? _initialization;

  final opus.BufferedOpusEncoder _encoder;
  final Uint8List _encoderInput;
  final opus.SimpleOpusDecoder _decoder;

  @override
  final AudioCodecConfig config;

  @override
  Uint8List encode(Int16List pcm) {
    final bytes = pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);
    if (bytes.length > _encoderInput.length) {
      throw ArgumentError.value(
        bytes.length,
        'pcm.lengthInBytes',
        'exceeds ${_encoderInput.length}',
      );
    }
    _encoderInput.setRange(0, bytes.length, bytes);
    _encoder.inputBufferIndex = bytes.length;
    return _encoder.encode();
  }

  @override
  Int16List decode(Uint8List packet) {
    return _decoder.decode(input: packet);
  }

  @override
  void dispose() {
    _encoder.destroy();
    _decoder.destroy();
  }
}
