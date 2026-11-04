import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_share_diagnostics.dart';

void main() {
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
