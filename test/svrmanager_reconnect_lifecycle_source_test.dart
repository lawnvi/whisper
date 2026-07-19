import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String methodBody(String source, String start, String next) {
    final startIndex = source.indexOf(start);
    expect(startIndex, isNonNegative, reason: 'Missing method $start');
    final endIndex = source.indexOf(next, startIndex);
    expect(endIndex, isNonNegative, reason: 'Missing next method $next');
    return source.substring(startIndex, endIndex);
  }

  test('peer removal settles reconnect stability for every disconnect cause',
      () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final section = methodBody(
      source,
      'Future<void> _afterPeerRemoved(',
      'Map<String, Set<String>> _preservedControlSessionsForPeer(',
    );

    // 稳定复位结算绑定会话生命周期:不论断因都要结算,
    // 不得只在 network/watchdog 门控的 scheduleReconnect 分支里发生。
    final settleIndex = section.indexOf('sessionClosed()');
    expect(settleIndex, isNonNegative);
    final causeGateIndex =
        section.indexOf('cause == PeerDisconnectCause.network');
    expect(causeGateIndex, greaterThan(settleIndex));
  });

  test('reconnect attempt reports the result reason to the controller', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final section = methodBody(
      source,
      'FutureOr<ConnectionAttemptStatus> _runReconnectAttempt(',
      'void _recordAuthenticatedReconnect(',
    );

    // 让控制器能区分可短延迟重试的 duplicateRequest 与真正终态拒绝。
    expect(section, contains('reportResultReason(result.reason)'));
  });

  test('manual preempt scan and cancellation share one automatic-attempt '
      'predicate', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final section = methodBody(
      source,
      'Future<ConnectionAttemptResult> _preemptAutomaticAttemptsThenConnect(',
      'Future<ConnectionAttemptResult> _connectToServer(',
    );

    expect('_isAutomaticAttempt'.allMatches(section).length, 2);
    expect(section, isNot(contains('pending.request.isAutomatic')));
  });
}
