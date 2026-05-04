import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AudioPlatform.channelName);
  const format = AudioStreamFormat(
    codec: AudioCodecKind.opus,
    sampleRate: 48000,
    channels: 2,
    frameDurationMs: 20,
    bitRate: 128000,
  );

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

  test('startPlayback sends session id and audio format to the native layer',
      () async {
    final platform = AudioPlatform();

    await platform.startPlayback(sessionId: 'audio-1', format: format);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'startPlayback');
    expect(calls.single.arguments, <String, dynamic>{
      'sessionId': 'audio-1',
      'format': format.toJson(),
    });
  });

  test('writePcm sends little-endian PCM bytes to the native layer', () async {
    final platform = AudioPlatform();

    await platform.writePcm(
      sessionId: 'audio-1',
      pcm: Int16List.fromList(<int>[1, -1]),
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'writePcm');
    final arguments = calls.single.arguments as Map<Object?, Object?>;
    expect(arguments['sessionId'], 'audio-1');
    expect(arguments['pcm'], Uint8List.fromList(<int>[1, 0, 255, 255]));
  });

  test('stopPlayback sends session id to the native layer', () async {
    final platform = AudioPlatform();

    await platform.stopPlayback(sessionId: 'audio-1');

    expect(calls, hasLength(1));
    expect(calls.single.method, 'stopPlayback');
    expect(calls.single.arguments, <String, dynamic>{
      'sessionId': 'audio-1',
    });
  });

  test('startCapture sends session id and audio format to the native layer',
      () async {
    final platform = AudioPlatform();

    await platform.startCapture(sessionId: 'audio-1', format: format);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'startCapture');
    expect(calls.single.arguments, <String, dynamic>{
      'sessionId': 'audio-1',
      'format': format.toJson(),
    });
  });

  test('stopCapture sends session id to the native layer', () async {
    final platform = AudioPlatform();

    await platform.stopCapture(sessionId: 'audio-1');

    expect(calls, hasLength(1));
    expect(calls.single.method, 'stopCapture');
    expect(calls.single.arguments, <String, dynamic>{
      'sessionId': 'audio-1',
    });
  });

  test('native capture callbacks are emitted as PCM frames', () async {
    final platform = AudioPlatform();
    final frames = <PlatformPcmFrame>[];
    final subscription = platform.captureFrames.listen(frames.add);

    await platform.handleNativeMethodCall(
      MethodCall('onCapturePcm', <String, dynamic>{
        'sessionId': 'audio-1',
        'sequence': 7,
        'captureTimeMicros': 1234,
        'sampleRate': 44100,
        'channels': 6,
        'pcm': Uint8List.fromList(<int>[1, 0, 255, 255]),
      }),
    );

    expect(frames, hasLength(1));
    expect(frames.single.sessionId, 'audio-1');
    expect(frames.single.sequence, 7);
    expect(frames.single.captureTimeMicros, 1234);
    expect(frames.single.sampleRate, 44100);
    expect(frames.single.channels, 6);
    expect(frames.single.pcm, Int16List.fromList(<int>[1, -1]));
    await subscription.cancel();
  });

  test('native capture errors are emitted as error events', () async {
    final platform = AudioPlatform();
    final errors = <PlatformAudioError>[];
    final subscription = platform.captureErrors.listen(errors.add);

    await platform.handleNativeMethodCall(
      const MethodCall('onCaptureError', <String, dynamic>{
        'sessionId': 'audio-1',
        'message': 'no output device',
      }),
    );

    expect(errors, hasLength(1));
    expect(errors.single.sessionId, 'audio-1');
    expect(errors.single.message, 'no output device');
    await subscription.cancel();
  });
}
