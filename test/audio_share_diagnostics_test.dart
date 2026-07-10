import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_diagnostics.dart';
import 'package:whisper/audio/audio_share_manager.dart';

void main() {
  const format = AudioStreamFormat(
    codec: AudioCodecKind.opus,
    sampleRate: 48000,
    channels: 2,
    frameDurationMs: 20,
    bitRate: 128000,
  );

  test('logs when audio packet bytes are delivered to a connected session', () {
    final logs = <String>[];
    final diagnostics = AudioShareDiagnostics(sink: logs.add);
    final manager = AudioShareManager(diagnostics: diagnostics);
    final offer = manager.createOffer(
      sourcePeerId: 'source',
      sinkPeerId: 'sink',
      format: format,
    );
    manager.acceptOffer(offer);

    manager.handlePacketBytes(
      AudioPacketFrame(
        sessionId: offer.sessionId,
        sequence: 1,
        captureTimeMicros: 100,
        payload: Uint8List.fromList(<int>[1, 2, 3]),
      ).encode(),
    );

    expect(
      logs,
      contains(
        allOf(
          contains('audio packet delivered'),
          contains('session=${offer.sessionId}'),
          contains('seq=1'),
          contains('payload=3'),
        ),
      ),
    );
  });

  test('defines a dart-define flag for enabling audio traces outside debug',
      () {
    expect(AudioShareDiagnostics.traceEnabled, isFalse);
  });

  test('redacts media capability query from every transport diagnostic', () {
    final logs = <String>[];
    final diagnostics = AudioShareDiagnostics(sink: logs.add);
    final uri = Uri.parse(
      'ws://peer.local:10002/audio?session=session-a&token=secret-token',
    );

    diagnostics.transportConnecting(uri);
    diagnostics.transportConnected(uri);
    diagnostics.transportConnectFailed(
      uri,
      StateError('failed to connect $uri'),
    );
    diagnostics.audioChannelError(StateError('socket failed for $uri'));

    expect(logs, hasLength(4));
    for (final log in logs.take(3)) {
      expect(log, contains('ws://peer.local:10002/audio'));
    }
    for (final log in logs) {
      expect(log, isNot(contains('secret-token')));
      expect(log, isNot(contains('session=session-a')));
      expect(log, isNot(contains('?')));
    }
  });

  test('logs when audio packet bytes are dropped for a missing session', () {
    final logs = <String>[];
    final diagnostics = AudioShareDiagnostics(sink: logs.add);
    final manager = AudioShareManager(diagnostics: diagnostics);

    manager.handlePacketBytes(
      AudioPacketFrame(
        sessionId: 'missing',
        sequence: 7,
        captureTimeMicros: 100,
        payload: Uint8List.fromList(<int>[1, 2, 3]),
      ).encode(),
    );

    expect(
      logs,
      contains(
        allOf(
          contains('audio packet dropped'),
          contains('session=missing'),
          contains('state=missing'),
          contains('seq=7'),
        ),
      ),
    );
  });
}
