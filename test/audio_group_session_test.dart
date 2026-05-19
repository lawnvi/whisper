import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_group_session.dart';
import 'package:whisper/audio/audio_protocol.dart';

void main() {
  const format = AudioStreamFormat(
    codec: AudioCodecKind.opus,
    sampleRate: 48000,
    channels: 2,
    frameDurationMs: 20,
    bitRate: 128000,
  );

  group('AudioGroupSession', () {
    test('creates an offering group with per-sink channel roles', () {
      final session = AudioGroupSession.offering(
        groupId: 'group-1',
        streamId: 'stream-1',
        sourcePeerId: 'mac',
        format: format,
        sinks: const <String, AudioChannelRole>{
          'phone-left': AudioChannelRole.left,
          'phone-right': AudioChannelRole.right,
        },
      );

      expect(session.state, AudioGroupState.offering);
      expect(session.sinks, hasLength(2));
      expect(
        session.sinks['phone-left']?.channelRole,
        AudioChannelRole.left,
      );
      expect(
        session.sinks['phone-right']?.channelRole,
        AudioChannelRole.right,
      );
    });

    test('accepting one sink does not activate another sink', () {
      final session = AudioGroupSession.offering(
        groupId: 'group-1',
        streamId: 'stream-1',
        sourcePeerId: 'mac',
        format: format,
        sinks: const <String, AudioChannelRole>{
          'phone-left': AudioChannelRole.left,
          'phone-right': AudioChannelRole.right,
        },
      ).markSink(
        'phone-left',
        state: AudioGroupSinkState.accepted,
        sessionId: 'session-left',
      );

      expect(session.sinks['phone-left']?.state, AudioGroupSinkState.accepted);
      expect(session.sinks['phone-left']?.sessionId, 'session-left');
      expect(session.sinks['phone-right']?.state, AudioGroupSinkState.offered);
      expect(session.state, AudioGroupState.connecting);
    });

    test('stopping one active sink leaves a partial group', () {
      final active = AudioGroupSession.offering(
        groupId: 'group-1',
        streamId: 'stream-1',
        sourcePeerId: 'mac',
        format: format,
        sinks: const <String, AudioChannelRole>{
          'phone-left': AudioChannelRole.left,
          'phone-right': AudioChannelRole.right,
        },
      )
          .markSink(
            'phone-left',
            state: AudioGroupSinkState.active,
            sessionId: 'session-left',
          )
          .markSink(
            'phone-right',
            state: AudioGroupSinkState.active,
            sessionId: 'session-right',
          );

      final partial = active.markSink(
        'phone-left',
        state: AudioGroupSinkState.stopped,
      );

      expect(active.state, AudioGroupState.active);
      expect(partial.state, AudioGroupState.partial);
      expect(
          partial.activeSinks.map((sink) => sink.sinkPeerId), ['phone-right']);
      expect(partial.sinks['phone-left']?.state, AudioGroupSinkState.stopped);
    });

    test('all failed sinks fail the group with the last error', () {
      final failed = AudioGroupSession.offering(
        groupId: 'group-1',
        streamId: 'stream-1',
        sourcePeerId: 'mac',
        format: format,
        sinks: const <String, AudioChannelRole>{
          'phone-left': AudioChannelRole.left,
          'phone-right': AudioChannelRole.right,
        },
      )
          .markSink(
            'phone-left',
            state: AudioGroupSinkState.failed,
            lastError: 'left disconnected',
          )
          .markSink(
            'phone-right',
            state: AudioGroupSinkState.failed,
            lastError: 'right disconnected',
          );

      expect(failed.state, AudioGroupState.failed);
      expect(failed.lastError, 'right disconnected');
      expect(failed.isLive, isFalse);
    });
  });
}
