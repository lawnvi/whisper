import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/connection_check.dart';
import 'package:whisper/state/connection_diagnostic.dart';

ConnectionProbe _probe({String local = '192.168.1.5', Object? error}) =>
    ConnectionProbe(
      localAddress: () async => local,
      reach: (_, _) async {
        if (error != null) throw error;
      },
    );

Future<ConnectionCheckReport> _run(
  ConnectionProbe probe, {
  bool connected = false,
  String host = '192.168.1.9',
  int port = 10002,
}) => checkConnection(
  host: host,
  port: port,
  connected: () => connected,
  probe: probe,
).last;

SocketException _os(int code) =>
    SocketException('x', osError: OSError('x', code));

void main() {
  test('a connected device that answers is simply fine', () async {
    final report = await _run(_probe(), connected: true);
    expect(report.finished, isTrue);
    expect(report.connected, isTrue);
    expect(report.problem, isNull);
    expect(report.oneWay, isFalse);
    expect(report.reach, isNotNull);
    for (final state in report.states.values) {
      expect(state, ConnectionCheckState.passed);
    }
  });

  test('a connected device is never told its service is down', () async {
    final report = await _run(_probe(error: _os(61)), connected: true);
    expect(report.problem, isNull);
    expect(report.oneWay, isTrue);
    expect(
      report.states[ConnectionCheckStep.session],
      ConnectionCheckState.passed,
    );
  });

  test('not connected, but reachable: nothing is wrong', () async {
    final report = await _run(_probe());
    expect(report.problem, isNull);
    expect(
      report.states[ConnectionCheckStep.service],
      ConnectionCheckState.passed,
    );
    expect(
      report.states[ConnectionCheckStep.session],
      ConnectionCheckState.idle,
    );
  });

  test('no network here stops at the first step', () async {
    final report = await _run(_probe(local: '127.0.0.1'));
    expect(report.problem, ConnectionDiagnosticStage.wifi);
    expect(
      report.states[ConnectionCheckStep.network],
      ConnectionCheckState.failed,
    );
    expect(
      report.states[ConnectionCheckStep.service],
      ConnectionCheckState.waiting,
    );
  });

  test('a device with no usable address', () async {
    expect(
      (await _run(_probe(), host: '')).problem,
      ConnectionDiagnosticStage.address,
    );
    expect(
      (await _run(_probe(), port: 0)).problem,
      ConnectionDiagnosticStage.address,
    );
  });

  test('why the port could not be reached', () async {
    for (final code in [61, 111, 10061]) {
      expect(connectionStageOf(_os(code)), ConnectionDiagnosticStage.service);
    }
    for (final code in [60, 110, 10060]) {
      expect(connectionStageOf(_os(code)), ConnectionDiagnosticStage.firewall);
    }
    expect(
      connectionStageOf(const SocketException('timed out')),
      ConnectionDiagnosticStage.firewall,
    );
    expect(
      connectionStageOf(TimeoutException('x')),
      ConnectionDiagnosticStage.firewall,
    );
    expect(connectionStageOf(_os(65)), ConnectionDiagnosticStage.wifi);
  });

  test('it says how far along it is after each step', () async {
    final reports = await checkConnection(
      host: '192.168.1.9',
      port: 10002,
      connected: () => false,
      probe: _probe(),
    ).toList();
    expect(
      reports.first.states[ConnectionCheckStep.network],
      ConnectionCheckState.checking,
    );
    expect(reports.where((r) => r.finished), hasLength(1));
    expect(reports.last.finished, isTrue);
  });
}
