import 'dart:async';
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
      writePcm: (pcm, _) async {
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

  test('reports next packet delay separately from queued buffer depth',
      () async {
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => 1000,
      writePcm: (_, __) async {},
    );

    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 3000),
      Int16List.fromList(<int>[1, 10]),
    );
    scheduler.enqueue(
      packet(sequence: 2, targetPlaybackTimeMicros: 7000),
      Int16List.fromList(<int>[2, 20]),
    );

    final report = scheduler.report;

    expect(report.nextPacketDelayMicros, 2000);
    expect(report.nextPumpDelayMicros, 2000);
    expect(report.bufferDepthMicros, 6000);
  });

  test('writes packets ahead of target time for native playback buffering',
      () async {
    var now = 1000;
    final writes = <List<int>>[];
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => now,
      outputLeadMicros: 2000,
      writePcm: (pcm, _) async => writes.add(pcm.toList(growable: false)),
    );

    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 5000),
      Int16List.fromList(<int>[1, 10]),
    );

    expect(scheduler.report.nextPacketDelayMicros, 4000);
    expect(scheduler.report.nextPumpDelayMicros, 2000);

    await scheduler.pump();
    expect(writes, isEmpty);

    now = 3000;
    await scheduler.pump();
    expect(writes, <List<int>>[
      <int>[1, 10],
    ]);
  });

  test('passes local target playback time to the PCM writer', () async {
    var now = 109000;
    final writeTargets = <int>[];
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => now,
      writePcm: (pcm, targetPlaybackTimeMicros) async {
        writeTargets.add(targetPlaybackTimeMicros);
      },
    );
    scheduler.updateClockOffsetMicros(9000);

    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 100000),
      Int16List.fromList(<int>[1, 10]),
    );

    await scheduler.pump();

    expect(writeTargets, <int>[109000]);
  });

  test('drops late packets and reports late count', () async {
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => 5000,
      writePcm: (_, __) async {},
      lateToleranceMicros: 1000,
    );

    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 1000),
      Int16List.fromList(<int>[1, 10]),
    );

    expect(scheduler.report.latePacketCount, 1);
    expect(scheduler.report.queuedPacketCount, 0);
  });

  test('late packet count only reports the recent health window', () async {
    var now = 5000;
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => now,
      writePcm: (_, __) async {},
      lateToleranceMicros: 1000,
    );

    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 1000),
      Int16List.fromList(<int>[1, 10]),
    );

    expect(scheduler.report.latePacketCount, 1);

    now += 10000001;

    expect(scheduler.report.latePacketCount, 0);
  });

  test('rebases remote target time when source and sink clocks differ',
      () async {
    var now = 10000000;
    final writes = <List<int>>[];
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => now,
      writePcm: (pcm, _) async => writes.add(pcm.toList(growable: false)),
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

  test('uses measured source to sink clock offset for target playback time',
      () async {
    var now = 1109000;
    final writes = <List<int>>[];
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => now,
      writePcm: (pcm, _) async => writes.add(pcm.toList(growable: false)),
      startupBufferMicros: 0,
    );
    scheduler.updateClockOffsetMicros(100000);

    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 1010000),
      Int16List.fromList(<int>[1, 10]),
    );

    await scheduler.pump();
    expect(writes, isEmpty);

    now = 1110000;
    await scheduler.pump();
    expect(writes, <List<int>>[
      <int>[1, 10],
    ]);
  });

  test('holds packets until clock offset is available before playback',
      () async {
    var now = 1109000;
    final writeTargets = <int>[];
    final writes = <List<int>>[];
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => now,
      writePcm: (pcm, targetPlaybackTimeMicros) async {
        writeTargets.add(targetPlaybackTimeMicros);
        writes.add(pcm.toList(growable: false));
      },
      requireClockOffsetBeforePlayback: true,
    );

    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 1010000),
      Int16List.fromList(<int>[1, 10]),
    );

    await scheduler.pump();
    expect(writes, isEmpty);
    expect(scheduler.report.latePacketCount, 0);
    expect(scheduler.report.queuedPacketCount, 1);

    scheduler.updateClockOffsetMicros(100000);
    await scheduler.pump();
    expect(writes, isEmpty);

    now = 1110000;
    await scheduler.pump();

    expect(writeTargets, <int>[1110000]);
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
      writePcm: (pcm, _) async => leftWrites.add(pcm.toList(growable: false)),
    );
    final right = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.right,
      channels: 2,
      clockMicros: () => 1000,
      writePcm: (pcm, _) async => rightWrites.add(pcm.toList(growable: false)),
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
      writePcm: (pcm, _) async => writes.add(pcm.toList(growable: false)),
    );

    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 1000),
      Int16List.fromList(<int>[100, 900, 200, 800]),
    );
    await scheduler.pump();

    expect(writes.single, <int>[500, 500, 500, 500]);
  });

  test('bounds queued group audio and drops the oldest packets', () async {
    var now = 0;
    final writes = <int>[];
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => now,
      writePcm: (pcm, _) async => writes.add(pcm.first),
      lateToleranceMicros: 1000000,
      maxQueueItems: 3,
      maxQueueBytes: 12,
      maxBufferDuration: const Duration(milliseconds: 60),
    );
    for (var sequence = 1; sequence <= 5; sequence++) {
      scheduler.enqueue(
        packet(
          sequence: sequence,
          targetPlaybackTimeMicros: 1000 + (sequence - 1) * 20000,
        ),
        Int16List.fromList(<int>[sequence, sequence]),
      );
    }

    expect(scheduler.report.queuedPacketCount, 3);
    expect(scheduler.report.queuedBytes, lessThanOrEqualTo(12));
    expect(scheduler.report.droppedPacketCount, 2);

    now = 100000;
    await scheduler.pump();
    expect(writes, <int>[3, 4, 5]);
  });

  test('closing group scheduler clears queued writes after the active write',
      () async {
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    final writes = <int>[];
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => 100000,
      lateToleranceMicros: 1000000,
      writePcm: (pcm, _) async {
        writes.add(pcm.first);
        if (!firstWriteStarted.isCompleted) {
          firstWriteStarted.complete();
          await releaseFirstWrite.future;
        }
      },
    );
    for (var sequence = 1; sequence <= 3; sequence++) {
      scheduler.enqueue(
        packet(sequence: sequence, targetPlaybackTimeMicros: 100000),
        Int16List.fromList(<int>[sequence, sequence]),
      );
    }

    final pumping = scheduler.pump();
    await firstWriteStarted.future;
    scheduler.close();
    releaseFirstWrite.complete();
    await pumping;

    expect(writes, <int>[1]);
    expect(scheduler.report.queuedPacketCount, 0);
  });

  test('concurrent group pump requests keep one native write in flight',
      () async {
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    final writes = <int>[];
    var writesInFlight = 0;
    var maxWritesInFlight = 0;
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => 100000,
      lateToleranceMicros: 1000000,
      writePcm: (pcm, _) async {
        writesInFlight += 1;
        maxWritesInFlight = writesInFlight > maxWritesInFlight
            ? writesInFlight
            : maxWritesInFlight;
        writes.add(pcm.first);
        if (!firstWriteStarted.isCompleted) {
          firstWriteStarted.complete();
          await releaseFirstWrite.future;
        }
        writesInFlight -= 1;
      },
    );
    for (var sequence = 1; sequence <= 2; sequence++) {
      scheduler.enqueue(
        packet(sequence: sequence, targetPlaybackTimeMicros: 100000),
        Int16List.fromList(<int>[sequence, sequence]),
      );
    }

    final firstPump = scheduler.pump();
    await firstWriteStarted.future;
    final secondPump = scheduler.pump();
    await Future<void>.delayed(Duration.zero);

    expect(maxWritesInFlight, 1);
    releaseFirstWrite.complete();
    await Future.wait(<Future<void>>[firstPump, secondPump]);
    expect(writes, <int>[1, 2]);
    expect(maxWritesInFlight, 1);
  });

  test('group buffer hard caps include the active native write', () async {
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    final writes = <int>[];
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => 1000000,
      lateToleranceMicros: 10000000,
      maxQueueItems: 3,
      maxQueueBytes: 12,
      maxBufferDuration: const Duration(milliseconds: 60),
      writePcm: (pcm, _) async {
        writes.add(pcm.first);
        if (!firstWriteStarted.isCompleted) {
          firstWriteStarted.complete();
          await releaseFirstWrite.future;
        }
      },
    );
    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 100000),
      Int16List.fromList(<int>[1, 1]),
    );
    final pumping = scheduler.pump();
    await firstWriteStarted.future;
    for (var sequence = 2; sequence <= 8; sequence++) {
      scheduler.enqueue(
        packet(
          sequence: sequence,
          targetPlaybackTimeMicros: 100000 + (sequence - 1) * 20000,
        ),
        Int16List.fromList(<int>[sequence, sequence]),
      );
    }

    expect(scheduler.report.queuedPacketCount, lessThanOrEqualTo(3));
    expect(scheduler.report.queuedBytes, lessThanOrEqualTo(12));
    expect(scheduler.report.droppedPacketCount, 5);

    releaseFirstWrite.complete();
    await pumping;
    expect(writes, <int>[1, 7, 8]);
  });

  test('group duration cap includes the active frame', () async {
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    final writes = <int>[];
    final scheduler = AudioGroupPlaybackScheduler(
      channelRole: AudioChannelRole.stereo,
      channels: 2,
      clockMicros: () => 1000000,
      lateToleranceMicros: 10000000,
      maxQueueItems: 10,
      maxQueueBytes: 1024,
      maxBufferDuration: const Duration(milliseconds: 60),
      writePcm: (pcm, _) async {
        writes.add(pcm.first);
        if (!firstWriteStarted.isCompleted) {
          firstWriteStarted.complete();
          await releaseFirstWrite.future;
        }
      },
    );
    scheduler.enqueue(
      packet(sequence: 1, targetPlaybackTimeMicros: 100000),
      Int16List.fromList(<int>[1, 1]),
    );
    final pumping = scheduler.pump();
    await firstWriteStarted.future;
    for (var sequence = 2; sequence <= 5; sequence++) {
      scheduler.enqueue(
        packet(
          sequence: sequence,
          targetPlaybackTimeMicros: 100000 + (sequence - 1) * 20000,
        ),
        Int16List.fromList(<int>[sequence, sequence]),
      );
    }

    expect(scheduler.report.droppedPacketCount, 2);
    releaseFirstWrite.complete();
    await pumping;
    expect(writes, <int>[1, 4, 5]);
  });
}
