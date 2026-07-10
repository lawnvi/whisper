import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_capture_source.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_diagnostics.dart';

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

  test('starts platform capture and encodes capture frames into audio packets',
      () async {
    final platform = AudioPlatform();
    final packets = <AudioPacketFrame>[];
    final pcm = Int16List.fromList(
      List<int>.generate(config.frameSize * config.channels, (index) => index),
    );
    final source = AudioCaptureSource(
      codec: PcmPassthroughAudioCodec(config),
      platform: platform,
      onPacket: packets.add,
    );

    await source.start(sessionId: 'audio-1', format: format);
    await platform.handleNativeMethodCall(
      MethodCall('onCapturePcm', <String, dynamic>{
        'sessionId': 'audio-1',
        'sequence': 9,
        'captureTimeMicros': 5678,
        'pcm': _pcmBytes(pcm),
      }),
    );

    expect(calls.first.method, 'startCapture');
    expect(packets, hasLength(1));
    expect(packets.single.sessionId, 'audio-1');
    expect(packets.single.sequence, 0);
    expect(packets.single.captureTimeMicros, 5678);
    expect(packets.single.payload.length, pcm.length * 2);
    await source.stop();
  });

  test('buffers variable native chunks into codec-sized packets', () async {
    final platform = AudioPlatform();
    final codec = _RecordingAudioCodec(config);
    final packets = <AudioPacketFrame>[];
    final source = AudioCaptureSource(
      codec: codec,
      platform: platform,
      onPacket: packets.add,
    );

    await source.start(sessionId: 'audio-1', format: format);
    await platform.handleNativeMethodCall(
      MethodCall('onCapturePcm', <String, dynamic>{
        'sessionId': 'audio-1',
        'sequence': 11,
        'captureTimeMicros': 1000,
        'pcm': _pcmBytes(Int16List(700)),
      }),
    );

    expect(packets, isEmpty);
    expect(codec.encodedLengths, isEmpty);

    await platform.handleNativeMethodCall(
      MethodCall('onCapturePcm', <String, dynamic>{
        'sessionId': 'audio-1',
        'sequence': 12,
        'captureTimeMicros': 2000,
        'pcm': _pcmBytes(Int16List(config.frameSize * config.channels - 700)),
      }),
    );

    expect(codec.encodedLengths, <int>[config.frameSize * config.channels]);
    expect(packets, hasLength(1));
    expect(packets.single.sequence, 0);
    expect(packets.single.captureTimeMicros, 1000);
    await source.stop();
  });

  test('converts multi-channel native PCM to the codec channel layout',
      () async {
    final platform = AudioPlatform();
    final codec = _RecordingAudioCodec(config);
    final source = AudioCaptureSource(
      codec: codec,
      platform: platform,
      onPacket: (_) {},
    );
    final frame = <int>[10, 20, 30, 40, 50, 60];
    final pcm = Int16List.fromList(
      List<int>.generate(
        config.frameSize * 6,
        (index) => frame[index % frame.length],
      ),
    );

    await source.start(sessionId: 'audio-1', format: format);
    await platform.handleNativeMethodCall(
      MethodCall('onCapturePcm', <String, dynamic>{
        'sessionId': 'audio-1',
        'sequence': 1,
        'captureTimeMicros': 1000,
        'sampleRate': 48000,
        'channels': 6,
        'pcm': _pcmBytes(pcm),
      }),
    );

    expect(codec.encodedLengths, <int>[config.frameSize * config.channels]);
    expect(codec.encodedPcm.single.take(6), <int>[10, 20, 10, 20, 10, 20]);
    await source.stop();
  });

  test('resamples native PCM to the codec sample rate before encoding',
      () async {
    final platform = AudioPlatform();
    final codec = _RecordingAudioCodec(config);
    final source = AudioCaptureSource(
      codec: codec,
      platform: platform,
      onPacket: (_) {},
    );

    await source.start(sessionId: 'audio-1', format: format);
    await platform.handleNativeMethodCall(
      MethodCall('onCapturePcm', <String, dynamic>{
        'sessionId': 'audio-1',
        'sequence': 1,
        'captureTimeMicros': 1000,
        'sampleRate': 24000,
        'channels': 2,
        'pcm': _pcmBytes(Int16List(config.frameSize * config.channels ~/ 2)),
      }),
    );

    expect(codec.encodedLengths, <int>[config.frameSize * config.channels]);
    await source.stop();
  });

  test('ignores capture frames for other sessions', () async {
    final platform = AudioPlatform();
    final packets = <AudioPacketFrame>[];
    final source = AudioCaptureSource(
      codec: PcmPassthroughAudioCodec(config),
      platform: platform,
      onPacket: packets.add,
    );

    await source.start(sessionId: 'audio-1', format: format);
    await platform.handleNativeMethodCall(
      MethodCall('onCapturePcm', <String, dynamic>{
        'sessionId': 'audio-2',
        'sequence': 1,
        'captureTimeMicros': 100,
        'pcm': Uint8List.fromList(<int>[1, 0]),
      }),
    );

    expect(packets, isEmpty);
    await source.stop();
  });

  test('stop cancels capture and calls the platform stop method', () async {
    final platform = AudioPlatform();
    final source = AudioCaptureSource(
      codec: PcmPassthroughAudioCodec(config),
      platform: platform,
      onPacket: (_) {},
    );

    await source.start(sessionId: 'audio-1', format: format);
    calls.clear();
    await source.stop();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'stopCapture');
    expect(calls.single.arguments, <String, dynamic>{
      'sessionId': 'audio-1',
    });
  });

  test('stop waits for an in-flight native start before forcing capture stop',
      () async {
    final startEntered = Completer<void>();
    final releaseStart = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      if (call.method == 'startCapture') {
        startEntered.complete();
        await releaseStart.future;
      }
      return null;
    });
    final source = AudioCaptureSource(
      codec: PcmPassthroughAudioCodec(config),
      platform: AudioPlatform(),
      onPacket: (_) {},
    );

    final starting = source.start(sessionId: 'audio-race', format: format);
    await startEntered.future;
    var stopCompleted = false;
    final stopping = source.stop().whenComplete(() => stopCompleted = true);
    await Future<void>.delayed(Duration.zero);

    expect(stopCompleted, isFalse);
    expect(calls.map((call) => call.method), <String>['startCapture']);

    releaseStart.complete();
    await starting;
    await stopping;

    expect(
      calls.map((call) => call.method),
      <String>['startCapture', 'stopCapture'],
    );
    expect(calls.last.arguments, <String, dynamic>{'sessionId': 'audio-race'});
  });

  test('stop still forces native cleanup when an in-flight start fails',
      () async {
    final startEntered = Completer<void>();
    final releaseStart = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      if (call.method == 'startCapture') {
        startEntered.complete();
        await releaseStart.future;
        throw PlatformException(code: 'audio-capture-start-failed');
      }
      return null;
    });
    final source = AudioCaptureSource(
      codec: PcmPassthroughAudioCodec(config),
      platform: AudioPlatform(),
      onPacket: (_) {},
    );

    final starting =
        source.start(sessionId: 'audio-failed-start', format: format);
    final startFailure =
        expectLater(starting, throwsA(isA<PlatformException>()));
    await startEntered.future;
    final stopping = source.stop();
    releaseStart.complete();

    await startFailure;
    await stopping;
    expect(
      calls.map((call) => call.method),
      <String>['startCapture', 'stopCapture'],
    );
  });

  test('logs native capture frames and encoded audio packets', () async {
    final platform = AudioPlatform();
    final logs = <String>[];
    final packets = <AudioPacketFrame>[];
    final source = AudioCaptureSource(
      codec: PcmPassthroughAudioCodec(config),
      platform: platform,
      onPacket: packets.add,
      diagnostics: AudioShareDiagnostics(sink: logs.add),
    );
    final pcm = Int16List(config.frameSize * config.channels);

    await source.start(sessionId: 'audio-1', format: format);
    await platform.handleNativeMethodCall(
      MethodCall('onCapturePcm', <String, dynamic>{
        'sessionId': 'audio-1',
        'sequence': 5,
        'captureTimeMicros': 1000,
        'pcm': _pcmBytes(pcm),
      }),
    );

    expect(
      logs,
      contains(
        allOf(
          contains('"kind":"captureFrame"'),
          contains('"sequence":5'),
          contains('"samples":${pcm.length}'),
        ),
      ),
    );
    expect(
      logs,
      contains(
        allOf(
          contains('"kind":"capturePacket"'),
          contains('"sequence":0'),
          contains('"bytes":${pcm.length * 2}'),
        ),
      ),
    );
    await source.stop();
  });
}

Uint8List _pcmBytes(Int16List pcm) {
  final bytes = Uint8List(pcm.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < pcm.length; i++) {
    data.setInt16(i * 2, pcm[i], Endian.little);
  }
  return bytes;
}

class _RecordingAudioCodec implements AudioCodec {
  _RecordingAudioCodec(this.config);

  @override
  final AudioCodecConfig config;

  final encodedLengths = <int>[];
  final encodedPcm = <Int16List>[];

  @override
  Uint8List encode(Int16List pcm) {
    encodedLengths.add(pcm.length);
    encodedPcm.add(Int16List.fromList(pcm));
    return Uint8List.fromList(<int>[pcm.length & 0xff]);
  }

  @override
  Int16List decode(Uint8List packet) {
    throw UnimplementedError();
  }

  @override
  void dispose() {}
}
