import 'dart:async';
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

  test('applies playback gain and clips PCM samples', () async {
    final codec = PcmPassthroughAudioCodec(config);
    final playback = AudioPlaybackSink(
      codec: codec,
      platform: AudioPlatform(),
      playbackGain: 2.0,
    );
    await playback.start(sessionId: 'audio-1', format: format);
    calls.clear();

    final packet = AudioPacketFrame(
      sessionId: 'audio-1',
      sequence: 1,
      captureTimeMicros: 100,
      payload: codec.encode(
        Int16List.fromList(<int>[1000, -1000, 20000, -20000]),
      ),
    );

    await playback.handlePacket(packet);

    final arguments = calls.single.arguments as Map<Object?, Object?>;
    expect(
      arguments['pcm'],
      Uint8List.fromList(<int>[
        208, 7, // 2000
        48, 248, // -2000
        255, 127, // 32767
        0, 128, // -32768
      ]),
    );
  });

  test('updates playback gain for an active sink', () async {
    final codec = PcmPassthroughAudioCodec(config);
    final playback = AudioPlaybackSink(
      codec: codec,
      platform: AudioPlatform(),
    );
    await playback.start(sessionId: 'audio-1', format: format);
    playback.updatePlaybackGain(2.0);
    calls.clear();

    await playback.handlePacket(
      AudioPacketFrame(
        sessionId: 'audio-1',
        sequence: 1,
        captureTimeMicros: 100,
        payload: codec.encode(Int16List.fromList(<int>[1000])),
      ),
    );

    final arguments = calls.single.arguments as Map<Object?, Object?>;
    expect(arguments['pcm'], Uint8List.fromList(<int>[208, 7]));
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

  test('slow native writes stay serialized and drop oldest buffered audio',
      () async {
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    final writtenSamples = <int>[];
    var writesInFlight = 0;
    var maxWritesInFlight = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      if (call.method != 'writePcm') {
        return null;
      }
      writesInFlight += 1;
      if (writesInFlight > maxWritesInFlight) {
        maxWritesInFlight = writesInFlight;
      }
      final arguments = call.arguments as Map<Object?, Object?>;
      final bytes = arguments['pcm']! as Uint8List;
      writtenSamples
          .add(ByteData.sublistView(bytes).getInt16(0, Endian.little));
      if (!firstWriteStarted.isCompleted) {
        firstWriteStarted.complete();
        await releaseFirstWrite.future;
      }
      writesInFlight -= 1;
      return null;
    });
    final codec = PcmPassthroughAudioCodec(config);
    final playback = AudioPlaybackSink(
      codec: codec,
      platform: AudioPlatform(),
      maxBufferedItems: 3,
      maxBufferedBytes: 6,
      maxBufferedDuration: const Duration(milliseconds: 60),
    );
    await playback.start(sessionId: 'audio-1', format: format);

    AudioPacketFrame packet(int sequence) => AudioPacketFrame(
          sessionId: 'audio-1',
          sequence: sequence,
          captureTimeMicros: sequence * 20000,
          payload: codec.encode(Int16List.fromList(<int>[sequence])),
        );

    playback.enqueuePacket(packet(1));
    await firstWriteStarted.future;
    for (var sequence = 2; sequence <= 8; sequence++) {
      playback.enqueuePacket(packet(sequence));
    }

    expect(playback.bufferedItems, lessThanOrEqualTo(3));
    expect(playback.bufferedBytes, lessThanOrEqualTo(6));
    expect(
      playback.bufferedDuration,
      lessThanOrEqualTo(const Duration(milliseconds: 60)),
    );
    expect(playback.droppedPackets, 5);
    expect(maxWritesInFlight, 1);

    releaseFirstWrite.complete();
    await playback.waitForIdle();

    expect(writtenSamples, <int>[1, 7, 8]);
    expect(maxWritesInFlight, 1);
  });

  test('stop clears queued audio without waiting for a stuck native write',
      () async {
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    var writeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      if (call.method == 'writePcm') {
        writeCalls += 1;
        writeStarted.complete();
        await releaseWrite.future;
      }
      return null;
    });
    final codec = PcmPassthroughAudioCodec(config);
    final playback = AudioPlaybackSink(
      codec: codec,
      platform: AudioPlatform(),
      maxBufferedItems: 3,
    );
    await playback.start(sessionId: 'audio-1', format: format);
    AudioPacketFrame packet(int sequence) => AudioPacketFrame(
          sessionId: 'audio-1',
          sequence: sequence,
          captureTimeMicros: sequence,
          payload: codec.encode(Int16List.fromList(<int>[sequence])),
        );

    playback.enqueuePacket(packet(1));
    await writeStarted.future;
    playback.enqueuePacket(packet(2));
    playback.enqueuePacket(packet(3));

    await playback.stop().timeout(const Duration(milliseconds: 100));

    expect(playback.bufferedItems, 0);
    expect(calls.map((call) => call.method), contains('stopPlayback'));
    releaseWrite.complete();
    await Future<void>.delayed(Duration.zero);
    expect(writeCalls, 1);
  });

  test('a playback sink is single-use after stop', () async {
    final playback = AudioPlaybackSink(
      codec: PcmPassthroughAudioCodec(config),
      platform: AudioPlatform(),
    );
    await playback.start(sessionId: 'audio-1', format: format);
    await playback.stop();

    await expectLater(
      playback.start(sessionId: 'audio-2', format: format),
      throwsStateError,
    );
  });
}
