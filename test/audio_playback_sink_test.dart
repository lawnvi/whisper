import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_playback_sink.dart';
import 'package:whisper/audio/audio_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AudioPlatform.channelName);
  const config = AudioCodecConfig(
    sampleRate: 48000,
    channels: 2,
    frameDurationMs: 20,
    bitRate: 128000,
  );
  final format = config.toStreamFormat(codec: AudioCodecKind.pcmS16le);
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('decodes packet payload and writes PCM to the platform sink', () async {
    final codec = PcmPassthroughAudioCodec(config);
    final playback = AudioPlaybackSink(
      codec: codec,
      platform: AudioPlatform(),
    );
    await playback.start(sessionId: 'audio-1', format: format);
    calls.clear();

    final packet = AudioPacketFrame(
      sessionId: 'audio-1',
      sequence: 1,
      captureTimeMicros: 100,
      payload: codec.encode(Int16List.fromList(<int>[4, -4])),
    );

    await playback.handlePacket(packet);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'writePcm');
    final arguments = calls.single.arguments as Map<Object?, Object?>;
    expect(arguments['sessionId'], 'audio-1');
    expect(arguments['pcm'], Uint8List.fromList(<int>[4, 0, 252, 255]));
  });

  test('ignores packets for another session', () async {
    final playback = AudioPlaybackSink(
      codec: PcmPassthroughAudioCodec(config),
      platform: AudioPlatform(),
    );
    await playback.start(sessionId: 'audio-1', format: format);
    calls.clear();

    await playback.handlePacket(
      AudioPacketFrame(
        sessionId: 'audio-2',
        sequence: 1,
        captureTimeMicros: 100,
        payload: Uint8List.fromList(<int>[1, 0]),
      ),
    );

    expect(calls, isEmpty);
  });
}
