import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_group_playback_scheduler.dart';
import 'package:whisper/audio/audio_protocol.dart';

void main() {
  AudioGroupPacketFrame packet({
    required int sequence,
    required int targetPlaybackTimeMicros,
  }) {
    return AudioGroupPacketFrame(
      groupId: 'group-1',
      streamId: 'stream-1',
      sessionId: 'session-1',
      sourcePeerId: 'mac',
      sequence: sequence,
      captureTimeMicros: sequence * 20000,
      targetPlaybackTimeMicros: targetPlaybackTimeMicros,
      durationMicros: 20000,
      channelMask: AudioChannelMask.stereo,
      payload: Uint8List(0),
    );
  }

  test('buffers packets by target playback time', () async {
    var now = 0;
    final writes = <List<int>>[];
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => now,
      writePcm: (pcm) async {
        writes.add(pcm.toList(growable: false));
      },
    );

    scheduler.enqueue(
      packet(sequence: 2, targetPlaybackTimeMicros: 2000),
      Int16List.fromList(<int>[2, 20]),
    );
    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 1000),
      Int16List.fromList(<int>[1, 10]),
    );

    await scheduler.pump();
    expect(writes, isEmpty);

    now = 1000;
    await scheduler.pump();
    expect(writes, <List<int>>[
      <int>[1, 10],
    ]);

    now = 2000;
    await scheduler.pump();
    expect(writes, <List<int>>[
      <int>[1, 10],
      <int>[2, 20],
    ]);
  });

  test('drops late packets and reports late count', () async {
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => 5000,
      writePcm: (_) async {},
      lateToleranceMicros: 1000,
    );

    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 1000),
      Int16List.fromList(<int>[1, 10]),
    );

    expect(scheduler.report.latePacketCount, 1);
    expect(scheduler.report.queuedPacketCount, 0);
  });

  test('rebases remote target time when source and sink clocks differ',
      () async {
    var now = 10000000;
    final writes = <List<int>>[];
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => now,
      writePcm: (pcm) async => writes.add(pcm.toList(growable: false)),
      startupBufferMicros: 20000,
    );

    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 1000),
      Int16List.fromList(<int>[1, 10]),
    );

    expect(scheduler.report.latePacketCount, 0);
    expect(scheduler.report.queuedPacketCount, 1);

    await scheduler.pump();
    expect(writes, isEmpty);

    now += 20000;
    await scheduler.pump();
    expect(writes, <List<int>>[
      <int>[1, 10],
    ]);
  });

  test('left and right channel roles isolate the intended channel', () async {
    final leftWrites = <List<int>>[];
    final rightWrites = <List<int>>[];
    final left = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.left,
      channels: 2,
      clockMicros: () => 1000,
      writePcm: (pcm) async => leftWrites.add(pcm.toList(growable: false)),
    );
    final right = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.right,
      channels: 2,
      clockMicros: () => 1000,
      writePcm: (pcm) async => rightWrites.add(pcm.toList(growable: false)),
    );

    final frame = packet(sequence: 1, targetPlaybackTimeMicros: 1000);
    final pcm = Int16List.fromList(<int>[100, 900, 200, 800]);

    left.enqueue(frame, pcm);
    right.enqueue(frame, pcm);
    await left.pump();
    await right.pump();

    expect(leftWrites.single, <int>[100, 100, 200, 200]);
    expect(rightWrites.single, <int>[900, 900, 800, 800]);
  });

  test('mono role averages stereo channels', () async {
    final writes = <List<int>>[];
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.mono,
      channels: 2,
      clockMicros: () => 1000,
      writePcm: (pcm) async => writes.add(pcm.toList(growable: false)),
    );

    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 1000),
      Int16List.fromList(<int>[100, 900, 200, 800]),
    );
    await scheduler.pump();

    expect(writes.single, <int>[500, 500, 500, 500]);
  });
}
