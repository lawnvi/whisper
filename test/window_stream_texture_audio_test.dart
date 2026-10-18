import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/pipeline/texture_surface.dart';

/// What reached the native side over the frames channel.
class _Sent {
  _Sent(ByteData data)
    : id = data.getInt64(0, Endian.little),
      pts = data.getInt64(8, Endian.little),
      flags = data.getInt32(16, Endian.little),
      payload = Uint8List.sublistView(data, TextureFrameSink.headerBytes);

  final int id;
  final int pts;
  final int flags;
  final Uint8List payload;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sent = <_Sent>[];

  setUp(() {
    sent.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('com.vireen.whisper/window_stream_frames', (
          message,
        ) async {
          sent.add(_Sent(message!));
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('com.vireen.whisper/window_stream_frames', null);
  });

  test('the window sound goes to the native player, never to video', () async {
    final sink = TextureFrameSink();
    sink.configureAudio(7, sampleRate: 48000, channels: 2);
    // 10 ms of a 48 kHz stereo tone, in two writes as the worker makes them.
    final pcm = Uint8List(1920);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = i & 0xff;
    }
    final audio = sink.beginAudio(7, pcm.length);
    audio.write(Uint8List.sublistView(pcm, 0, 1000));
    audio.write(Uint8List.sublistView(pcm, 1000));
    audio.commit(ptsUs: 123456, config: false, key: false);
    final video = sink.beginVideo(7, 4)
      ..write(Uint8List.fromList([0, 0, 0, 1]));
    video.commit(ptsUs: 99, config: false, key: true);
    await Future<void>.delayed(Duration.zero);

    expect(sent, hasLength(3));
    final format = sent[0];
    expect([format.id, format.flags], [7, TextureFrameSink.flagAudioFormat]);
    final formatData = ByteData.sublistView(format.payload);
    expect(formatData.getInt32(0, Endian.little), 48000);
    expect(formatData.getInt32(4, Endian.little), 2);

    final chunk = sent[1];
    expect([chunk.id, chunk.pts, chunk.flags], [7, 123456, 16]);
    expect(chunk.payload, pcm);

    final frame = sent[2];
    expect(frame.flags, TextureFrameSink.flagKey);
    expect(frame.flags & (16 | 32), 0);
  });
}
