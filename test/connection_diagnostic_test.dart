import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/connection_diagnostic.dart';
import 'package:whisper/state/peer_endpoint.dart';

ConnectionAttemptRequest _request() => ConnectionAttemptRequest(
      requestId: 'diagnostic-test',
      endpoint: PeerEndpoint(host: '192.168.1.20', port: 10002),
      mode: ConnectionAttemptMode.interactive,
    );

void main() {
  test('maps typed failures to actionable diagnostic stages', () {
    expect(
      ConnectionDiagnostic.fromReason(
        ConnectionAttemptReason.networkUnavailable,
      ).stage,
      ConnectionDiagnosticStage.wifi,
    );
    expect(
      ConnectionDiagnostic.fromReason(
        ConnectionAttemptReason.invalidEndpoint,
      ).stage,
      ConnectionDiagnosticStage.address,
    );
    expect(
      ConnectionDiagnostic.fromReason(
        ConnectionAttemptReason.connectionRefused,
      ).stage,
      ConnectionDiagnosticStage.service,
    );
    expect(
      ConnectionDiagnostic.fromReason(
        ConnectionAttemptReason.connectionTimedOut,
      ).stage,
      ConnectionDiagnosticStage.firewall,
    );
    expect(
      ConnectionDiagnostic.fromReason(
        ConnectionAttemptReason.identityMismatch,
      ).stage,
      ConnectionDiagnosticStage.identity,
    );
  });

  test('classifies platform refusal and timeout errors before diagnosis', () {
    final manager = WsSvrManager.forTesting();
    final refused = manager.debugClassifyConnectionException(
      _request(),
      const SocketException('refused', osError: OSError('refused', 61)),
    );
    final timedOut = manager.debugClassifyConnectionException(
      _request(),
      TimeoutException('timed out'),
    );

    expect(refused.reason, ConnectionAttemptReason.connectionRefused);
    expect(timedOut.reason, ConnectionAttemptReason.connectionTimedOut);
  });
}
