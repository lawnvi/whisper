import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_fanout_transport.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

void main() {
  AudioGroupPacketFrame packet(int sequence) {
    return AudioGroupPacketFrame(
      groupId: 'group-1',
      streamId: 'stream-1',
      sessionId: 'session-1',
      sourcePeerId: 'mac',
      sequence: sequence,
      captureTimeMicros: sequence * 20000,
      targetPlaybackTimeMicros: sequence * 20000 + 160000,
      durationMicros: 20000,
      channelMask: AudioChannelMask.stereo,
      payload: Uint8List.fromList(<int>[sequence]),
    );
  }

  test('sends one group packet to every attached sink transport', () {
    final failures = <String, Object>{};
    final left = _FakeGroupTransport();
    final right = _FakeGroupTransport();
    final fanout = AudioFanoutTransport(
      onSinkFailure: (sinkPeerId, error) {
        failures[sinkPeerId] = error;
      },
    )
      ..attach('phone-left', left)
      ..attach('phone-right', right);

    fanout.send(packet(1));

    expect(left.sent.map((item) => item.sequence), <int>[1]);
    expect(right.sent.map((item) => item.sequence), <int>[1]);
    expect(failures, isEmpty);
  });

  test('failed sink does not prevent delivery to remaining sinks', () {
    final failures = <String, Object>{};
    final broken = _FakeGroupTransport(throwOnSend: true);
    final healthy = _FakeGroupTransport();
    final fanout = AudioFanoutTransport(
      onSinkFailure: (sinkPeerId, error) {
        failures[sinkPeerId] = error;
      },
    )
      ..attach('phone-broken', broken)
      ..attach('phone-healthy', healthy);

    fanout.send(packet(2));
    fanout.send(packet(3));

    expect(healthy.sent.map((item) => item.sequence), <int>[2, 3]);
    expect(failures.keys, contains('phone-broken'));
    expect(broken.sent, isEmpty);
  });

  test('detached sink no longer receives packets', () {
    final sink = _FakeGroupTransport();
    final fanout = AudioFanoutTransport(
      onSinkFailure: (_, __) {},
    )..attach('phone', sink);

    fanout.send(packet(1));
    fanout.detach('phone');
    fanout.send(packet(2));

    expect(sink.sent.map((item) => item.sequence), <int>[1]);
  });

  test('closeAll closes every attached sink', () async {
    final left = _FakeGroupTransport();
    final right = _FakeGroupTransport();
    final fanout = AudioFanoutTransport(
      onSinkFailure: (_, __) {},
    )
      ..attach('phone-left', left)
      ..attach('phone-right', right);

    await fanout.closeAll();
    fanout.send(packet(1));

    expect(left.closed, isTrue);
    expect(right.closed, isTrue);
    expect(left.sent, isEmpty);
    expect(right.sent, isEmpty);
  });

  test('legacy synchronous sink failure detaches the broken sink', () {
    final failures = <Object>[];
    final fanout = AudioFanoutTransport(
      onSinkFailure: (_, error) => failures.add(error),
    )..attach(
        'broken',
        AudioGroupPacketByteTransport(
          sendBytes: (_) => throw StateError('legacy sink failed'),
        ),
      );

    fanout.send(packet(1));

    expect(fanout.sinkPeerIds, isEmpty);
    expect(failures.single, isA<StateError>());
  });

  test('queued writer failure detaches but drop-oldest backpressure does not',
      () async {
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    var shouldFailWriter = false;
    final failures = <Object>[];
    final bytes = PacketByteTransport.audio(
      addStream: (stream) async {
        await stream.single;
        if (!firstWriteStarted.isCompleted) {
          firstWriteStarted.complete();
          await releaseFirstWrite.future;
        }
        if (shouldFailWriter) {
          throw StateError('queued writer failed');
        }
      },
      closeSink: () async {},
      maxItems: 2,
      maxBytes: 1024 * 1024,
    );
    final fanout = AudioFanoutTransport(
      onSinkFailure: (_, error) => failures.add(error),
    )..attach('queued', AudioGroupPacketByteTransport.withTransport(bytes));

    fanout.send(packet(1));
    await firstWriteStarted.future;
    fanout.send(packet(2));
    fanout.send(packet(3));
    expect(fanout.sinkPeerIds, contains('queued'));
    expect(failures, isEmpty);

    shouldFailWriter = true;
    releaseFirstWrite.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(fanout.sinkPeerIds, isEmpty);
    expect(failures.single, isA<StateError>());
  });
}

class _FakeGroupTransport implements AudioGroupPacketTransport {
  _FakeGroupTransport({this.throwOnSend = false});

  final bool throwOnSend;
  final sent = <AudioGroupPacketFrame>[];
  bool closed = false;

  @override
  Future<PacketSendResult> send(AudioGroupPacketFrame packet) {
    if (throwOnSend) {
      throw StateError('sink failed');
    }
    if (!closed) {
      sent.add(packet);
    }
    return Future<PacketSendResult>.value(
      closed ? PacketSendResult.closed : PacketSendResult.sent,
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
