import 'dart:convert';
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
          contains('"event":"audio_diagnostic"'),
          contains('"kind":"packetDelivered"'),
          contains('"sequence":1'),
          contains('"bytes":3'),
        ),
      ),
    );
    expect(logs.join(), isNot(contains(offer.sessionId)));
  });

  test('defines a dart-define flag for enabling audio traces outside debug',
      () {
    expect(AudioShareDiagnostics.traceEnabled, isFalse);
  });

  test('retains only the route and stable error type for transport events', () {
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
    for (final log in logs) {
      expect(log, isNot(contains('secret-token')));
      expect(log, isNot(contains('session=session-a')));
      expect(log, isNot(contains('peer.local')));
      expect(jsonDecode(log), containsPair('event', 'audio_diagnostic'));
    }
    expect(jsonDecode(logs[0]), containsPair('route', 'audio'));
    expect(jsonDecode(logs[2]), containsPair('errorType', 'state'));
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
          contains('"kind":"packetDropped"'),
          contains('"state":"missing"'),
          contains('"sequence":7'),
        ),
      ),
    );
    expect(logs.join(), isNot(contains('session=missing')));
  });

  test('decode diagnostics never stringify remote-controlled errors', () {
    final logs = <String>[];
    final diagnostics = AudioShareDiagnostics(sink: logs.add);
    const secret =
        'remote token=never-log-this /Users/alice/private.wav 192.0.2.44';

    diagnostics.packetDecodeFailed(
      bytes: 128,
      legacyError: StateError(secret),
      groupError: FormatException(secret),
    );

    expect(logs, hasLength(1));
    expect(logs.single, contains('"kind":"decodeFailed"'));
    expect(logs.single, contains('"bytes":128'));
    expect(logs.single, contains('"reason":"protocol"'));
    expect(logs.single, contains('"errorType":"state"'));
    expect(logs.single, isNot(contains(secret)));
    expect(logs.single, isNot(contains('/Users/alice')));
    expect(logs.single, isNot(contains('192.0.2.44')));
  });
}
