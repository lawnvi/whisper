import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_fanout_transport.dart';
import 'package:whisper/audio/audio_protocol.dart';

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
}

class _FakeGroupTransport implements AudioGroupPacketTransport {
  _FakeGroupTransport({this.throwOnSend = false});

  final bool throwOnSend;
  final sent = <AudioGroupPacketFrame>[];
  bool closed = false;

  @override
  void send(AudioGroupPacketFrame packet) {
    if (throwOnSend) {
      throw StateError('sink failed');
    }
    if (!closed) {
      sent.add(packet);
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
