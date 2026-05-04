import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';

void main() {
  const format = AudioStreamFormat(
    codec: AudioCodecKind.opus,
    sampleRate: 48000,
    channels: 2,
    frameDurationMs: 20,
    bitRate: 128000,
  );

  test('creates an offer and stores it as an offering session', () {
    final manager = AudioShareManager();

    final offer = manager.createOffer(
      sourcePeerId: 'peer-a',
      sinkPeerId: 'peer-b',
      format: format,
    );

    final session = manager.session(offer.sessionId);
    expect(offer.action, AudioControlAction.offer);
    expect(offer.path, '/audio');
    expect(session?.state, AudioShareSessionState.offering);
    expect(session?.format, format);
  });

  test('accepts an offer and stores it as a connected session', () {
    final manager = AudioShareManager();
    final offer = manager.createOffer(
      sourcePeerId: 'peer-a',
      sinkPeerId: 'peer-b',
      format: format,
    );

    final accept = manager.acceptOffer(offer);

    final session = manager.session(offer.sessionId);
    expect(accept.action, AudioControlAction.accept);
    expect(accept.sessionId, offer.sessionId);
    expect(session?.state, AudioShareSessionState.connected);
  });

  test('routes packet bytes to the packet handler for connected sessions', () {
    final received = <AudioPacketFrame>[];
    final manager = AudioShareManager(onPacket: received.add);
    final offer = manager.createOffer(
      sourcePeerId: 'peer-a',
      sinkPeerId: 'peer-b',
      format: format,
    );
    manager.acceptOffer(offer);
    final packet = AudioPacketFrame(
      sessionId: offer.sessionId,
      sequence: 1,
      captureTimeMicros: 100,
      payload: Uint8List.fromList(<int>[7, 8, 9]),
    );

    manager.handlePacketBytes(packet.encode());

    expect(received, hasLength(1));
    expect(received.single.sequence, 1);
    expect(received.single.payload, <int>[7, 8, 9]);
  });

  test('drops packet bytes for unknown or stopped sessions', () {
    final received = <AudioPacketFrame>[];
    final manager = AudioShareManager(onPacket: received.add);
    final packet = AudioPacketFrame(
      sessionId: 'missing',
      sequence: 1,
      captureTimeMicros: 100,
      payload: Uint8List.fromList(<int>[7, 8, 9]),
    );

    manager.handlePacketBytes(packet.encode());

    expect(received, isEmpty);
  });

  test('marks sessions connected when an accept control message arrives', () {
    final manager = AudioShareManager();
    final offer = manager.createOffer(
      sourcePeerId: 'peer-a',
      sinkPeerId: 'peer-b',
      format: format,
    );

    manager.handleControlMessage(
      AudioControlMessage(
        action: AudioControlAction.accept,
        sessionId: offer.sessionId,
        sourcePeerId: 'peer-a',
        sinkPeerId: 'peer-b',
        format: format,
        path: '/audio',
      ),
    );

    expect(
      manager.session(offer.sessionId)?.state,
      AudioShareSessionState.connected,
    );
  });

  test('marks sessions stopped when a stop control message arrives', () {
    final manager = AudioShareManager();
    final offer = manager.createOffer(
      sourcePeerId: 'peer-a',
      sinkPeerId: 'peer-b',
      format: format,
    );
    manager.acceptOffer(offer);

    manager.handleControlMessage(
      AudioControlMessage(
        action: AudioControlAction.stop,
        sessionId: offer.sessionId,
        sourcePeerId: 'peer-a',
        sinkPeerId: 'peer-b',
      ),
    );

    expect(
      manager.session(offer.sessionId)?.state,
      AudioShareSessionState.stopped,
    );
  });
}
