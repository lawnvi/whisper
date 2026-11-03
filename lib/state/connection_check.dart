import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/state/connection_diagnostic.dart';

enum ConnectionCheckStep { network, address, service, session }

enum ConnectionCheckState {
  /// Not reached yet, or there is no point once an earlier step failed.
  waiting,
  checking,
  passed,
  failed,

  /// Nothing wrong, it is simply not the case: not connected right now.
  idle,
}

/// What the check has found so far.
@immutable
class ConnectionCheckReport {
  const ConnectionCheckReport({
    required this.states,
    this.problem,
    this.reach,
    this.connected = false,
    this.finished = false,
  });

  final Map<ConnectionCheckStep, ConnectionCheckState> states;

  /// Why it cannot connect. Null when connected: what is working is not a
  /// problem, even if one of the steps could not be confirmed from here.
  final ConnectionDiagnosticStage? problem;

  /// How long reaching its port took.
  final Duration? reach;
  final bool connected, finished;

  /// Connected, yet its port cannot be reached from here: the other device made
  /// the connection, and this one could not make it again.
  bool get oneWay =>
      connected &&
      states[ConnectionCheckStep.service] == ConnectionCheckState.failed;
}

/// What the check needs from outside.
class ConnectionProbe {
  const ConnectionProbe({required this.localAddress, required this.reach});

  factory ConnectionProbe.live() => ConnectionProbe(
    localAddress: getLocalIpAddress,
    reach: (host, port) async {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 3),
      );
      socket.destroy();
    },
  );

  final Future<String> Function() localAddress;

  /// Opens a connection to the port and closes it again. It says nothing on the
  /// wire, so the other device does not notice.
  final Future<void> Function(String host, int port) reach;
}

/// Which diagnosis fits a failure to reach the port.
ConnectionDiagnosticStage connectionStageOf(Object error) {
  if (error is TimeoutException) return ConnectionDiagnosticStage.firewall;
  if (error is SocketException) {
    return switch (error.osError?.errorCode) {
      61 || 111 || 10061 => ConnectionDiagnosticStage.service,
      // Dart's own timeout comes without an error from the system.
      null || 60 || 110 || 10060 => ConnectionDiagnosticStage.firewall,
      _ => ConnectionDiagnosticStage.wifi,
    };
  }
  return ConnectionDiagnosticStage.service;
}

/// Looks at one device, step by step, and says after each step.
Stream<ConnectionCheckReport> checkConnection({
  required String host,
  required int port,
  required bool Function() connected,
  required ConnectionProbe probe,
}) async* {
  final states = {
    for (final step in ConnectionCheckStep.values)
      step: ConnectionCheckState.waiting,
  };
  ConnectionCheckReport report({
    ConnectionDiagnosticStage? problem,
    Duration? reach,
    bool finished = false,
  }) {
    final on = connected();
    return ConnectionCheckReport(
      states: Map.unmodifiable(states),
      problem: on ? null : problem,
      reach: reach,
      connected: on,
      finished: finished,
    );
  }

  void session() {
    states[ConnectionCheckStep.session] = connected()
        ? ConnectionCheckState.passed
        : ConnectionCheckState.idle;
  }

  states[ConnectionCheckStep.network] = ConnectionCheckState.checking;
  yield report();
  final local = await probe.localAddress();
  if (local.isEmpty || local == '127.0.0.1') {
    states[ConnectionCheckStep.network] = ConnectionCheckState.failed;
    session();
    yield report(problem: ConnectionDiagnosticStage.wifi, finished: true);
    return;
  }
  states[ConnectionCheckStep.network] = ConnectionCheckState.passed;

  states[ConnectionCheckStep.address] = ConnectionCheckState.checking;
  yield report();
  if (host.trim().isEmpty || port < 1 || port > 65535) {
    states[ConnectionCheckStep.address] = ConnectionCheckState.failed;
    session();
    yield report(problem: ConnectionDiagnosticStage.address, finished: true);
    return;
  }
  states[ConnectionCheckStep.address] = ConnectionCheckState.passed;

  states[ConnectionCheckStep.service] = ConnectionCheckState.checking;
  yield report();
  final watch = Stopwatch()..start();
  ConnectionDiagnosticStage? problem;
  Duration? reach;
  try {
    await probe.reach(host, port);
    reach = watch.elapsed;
    states[ConnectionCheckStep.service] = ConnectionCheckState.passed;
  } on Object catch (error) {
    problem = connectionStageOf(error);
    states[ConnectionCheckStep.service] = ConnectionCheckState.failed;
  }
  session();
  yield report(problem: problem, reach: reach, finished: true);
}
