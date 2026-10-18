import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/wire_input_policy.dart';

void main() {
  test('the registry tells whether a session is still known', () {
    final registry = WireControlSessionRegistry();
    const session = '0b8e3a5c-6f1d-4c2e-9a7b-1d2e3f4a5b6c';
    expect(
      registry.knows(namespace: 'window-stream', sessionId: session),
      isFalse,
    );
    final result = registry.validateAndRemember(
      namespace: 'window-stream',
      sessionId: session,
      sourcePeerId: 'viewer',
      sinkPeerId: 'host',
      authenticatedPeerId: 'viewer',
      localPeerId: 'host',
      isInitialOffer: true,
      isIncoming: true,
    );
    expect(result.isAccepted, isTrue);
    expect(
      registry.knows(namespace: 'window-stream', sessionId: session),
      isTrue,
    );
    registry.forget(namespace: 'window-stream', sessionId: session);
    expect(
      registry.knows(namespace: 'window-stream', sessionId: session),
      isFalse,
    );
  });

  test('a late stop for an ended stream keeps the connection', () {
    // Both ends end a stream at once when the host's window goes away; the
    // second stop must not count as a protocol violation.
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final rule = RegExp(
      r'if \(control\.isTerminal &&\s*!control\.isInitial &&\s*'
      r'!_wireControlSessions\.knows\(',
    );
    expect(rule.hasMatch(source), isTrue);
  });
}
