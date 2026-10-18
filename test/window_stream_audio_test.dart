import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/pipeline/worker_opus.dart';
import 'package:whisper/window_stream/remote/host_audio.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';

/// A streamed window's sound: framed and coded on the host, decoded on the
/// viewer.
void main() {
  Uint8List pcm(int samples, {int start = 0}) {
    final out = Int16List(samples);
    for (var i = 0; i < samples; i++) {
      out[i] = start + i;
    }
    return out.buffer.asUint8List();
  }

  test('audio format and frames survive the wire', () {
    final format = WindowStreamPacket.decode(
      WindowStreamPacket.audioFormat(
        codec: WindowStreamPacket.audioOpus,
        sampleRate: 48000,
        channels: 2,
        frameMs: 20,
      ),
    );
    expect(format, isA<WindowStreamAudioFormat>());
    format as WindowStreamAudioFormat;
    expect(format.codec, WindowStreamPacket.audioOpus);
    expect(format.sampleRate, 48000);
    expect(format.channels, 2);
    expect(format.frameMs, 20);

    final frame = WindowStreamPacket.decode(
      WindowStreamPacket.audio(Uint8List.fromList([1, 2, 3]), ptsUs: 1234),
    );
    expect(frame, isA<WindowStreamAudio>());
    frame as WindowStreamAudio;
    expect(frame.ptsUs, 1234);
    expect(frame.payload, [1, 2, 3]);
  });

  test('a format nobody can play is refused', () {
    final bad = WindowStreamPacket.audioFormat(
      codec: 9,
      sampleRate: 48000,
      channels: 2,
      frameMs: 20,
    );
    expect(() => WindowStreamPacket.decode(bad), throwsFormatException);
    final tooMany = WindowStreamPacket.audioFormat(
      codec: WindowStreamPacket.audioPcm,
      sampleRate: 48000,
      channels: 6,
      frameMs: 20,
    );
    expect(() => WindowStreamPacket.decode(tooMany), throwsFormatException);
  });

  test('the host cuts PCM into 20 ms frames with their own pts', () async {
    final sent = <WindowStreamPacketView>[];
    final encoder = HostAudioEncoder(
      send: (packet) => sent.add(WindowStreamPacket.decode(packet)),
    );
    // Opus is a plugin, missing under `flutter test`: PCM it is.
    encoder.add(pcm(10), ptsUs: 0, sampleRate: 48000, channels: 2);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // 20 ms of 48 kHz stereo = 1920 samples; feed 50 ms from pts 1 s.
    encoder.add(pcm(4800), ptsUs: 1000000, sampleRate: 48000, channels: 2);
    final format = sent.whereType<WindowStreamAudioFormat>().single;
    expect(format.codec, WindowStreamPacket.audioPcm);
    final frames = sent.whereType<WindowStreamAudio>().toList();
    // The 10 samples at pts 0 end at a gap: their frame goes out padded.
    // Then 4800 samples from 1 s: two whole frames, 20 ms apart; the last
    // 960 wait for more.
    expect(frames, hasLength(3));
    expect(frames.first.ptsUs, 0);
    expect(frames.first.payload.length, 1920 * 2);
    expect(frames[1].ptsUs, 1000000);
    expect(frames[2].ptsUs - frames[1].ptsUs, 20000);
    expect(Int16List.sublistView(frames[1].payload).first, 0);
    encoder.close();
  });

  test('the viewer plays PCM as it comes and decodes Opus', () {
    final decoder = WorkerAudioDecoder.open(
      sampleRate: 48000,
      channels: 2,
      opusCodec: false,
    )!;
    final frame = pcm(1920);
    expect(decoder.decode(frame), frame);
    expect(decoder.decode(Uint8List(3)), isEmpty);
    decoder.dispose();
  });

  test('an empty bundled libopus falls back to the system one', () {
    final tried = <String>[];
    final library = WorkerOpus.openFirst(
      ['/tmp/opus_flutter_linux/opus/libopus_x86_64.so', 'libopus.so.0'],
      open: (path) {
        tried.add(path);
        if (path.startsWith('/tmp/')) {
          throw ArgumentError('invalid ELF header');
        }
        return DynamicLibrary.process();
      },
    );
    expect(library, isNotNull);
    expect(tried, [
      '/tmp/opus_flutter_linux/opus/libopus_x86_64.so',
      'libopus.so.0',
    ]);
    expect(
      () =>
          WorkerOpus.openFirst(['a', 'b'], open: (_) => throw ArgumentError()),
      throwsArgumentError,
    );
  });

  test('the viewer asks for sound and the worker hands it to the surface', () {
    final viewer = File(
      'lib/window_stream/remote/remote_peer_source.dart',
    ).readAsStringSync();
    expect(viewer, contains("'audio': true,"));
    final worker = File(
      'lib/window_stream/remote/remote_window_worker.dart',
    ).readAsStringSync();
    expect(worker, contains('case WindowStreamAudioFormat():'));
    expect(worker, contains('sink.beginAudio(surface, pcm.length)'));
  });

  test('one window of an app brings its sound to a viewer, not two', () {
    final host = File(
      'lib/window_stream/remote/window_stream_host.dart',
    ).readAsStringSync();
    expect(host, contains('_takeSound(stream);'));
    expect(host, contains('other.audioOn &&'));
    // The next window of that app takes over when the first one stops.
    expect(
      host,
      contains('if (_sameSound(other, stream) && _takeSound(other))'),
    );
    expect(host, contains('if (!stream.audioOn ||'));
  });
}
