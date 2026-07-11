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

  test('device list duplicate-request branch restores coordinator state '
      'before returning', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final section = methodBody(
      source,
      'Future<void> _connectServerInternal(',
      'Future<void> _attemptAutoConnect()',
    );

    final branchStart = section.indexOf(
      'if (result.reason == ConnectionAttemptReason.duplicateRequest) {',
    );
    expect(branchStart, isNonNegative);
    final branchEnd = section.indexOf('return;', branchStart);
    expect(branchEnd, greaterThan(branchStart));
    final branch = section.substring(branchStart, branchEnd);

    // markConnecting 已在 _connectServerInternal 开头置位;去重返回前必须
    // 复位行状态,否则挡路的自动尝试以 cancelled/networkFailure 收场时
    // 没有任何路径清 connecting 态,设备行转圈永不复位。
    expect(branch, contains('markDisconnected'));
    expect(branch, contains('_pendingAutoConnectPeerId'));
    // 复位要先于轻提示。
    expect(
      branch.indexOf('markDisconnected'),
      lessThan(branch.indexOf('showAppToast')),
    );
  });

  test('conversation connect flow does not pre-mark connecting, so its '
      'duplicate-request branch needs no restore', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final section = methodBody(
      source,
      'Future<bool> _connectServer(',
      'Future<bool> _restoreConnectionIfNeeded()',
    );

    expect(
      section,
      contains('ConnectionAttemptReason.duplicateRequest'),
    );
    // conversation 的连接流程从不调用 markConnecting,轻提示分支
    // 不会遗留 connecting 状态;若未来引入 markConnecting,此断言
    // 会提醒同步补上去重分支的状态复位。
    expect(section, isNot(contains('markConnecting')));
  });
}
