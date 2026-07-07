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

  test('device list deduplicates incoming connection prompts by peer', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final onAuth = methodBody(
      source,
      'void onAuth(DeviceData? deviceData, bool asServer, String msg, var callback)',
      'void afterAuth(bool allow, DeviceData? deviceData)',
    );

    expect(
      source,
      contains("import 'package:whisper/state/connect_prompt_registry.dart';"),
    );
    expect(
        source, contains('final ConnectPromptRegistry _connectPromptRegistry'));
    expect(onAuth, contains('_connectPromptRegistry.register'));
    expect(onAuth, contains('showCupertinoDialog'));
    expect(onAuth, contains('_connectPromptRegistry.bindCloser'));
    expect(onAuth, contains('_connectPromptRegistry.latestCallbackFor'));
    expect(onAuth, isNot(contains('showConfirmationDialog(context')));
  });

  test('device list closes pending prompt when auth resolves elsewhere', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final afterAuth = methodBody(
      source,
      'void afterAuth(bool allow, DeviceData? deviceData)',
      'void onClose()',
    );

    expect(afterAuth, contains('_connectPromptRegistry.resolveAndClose'));
    expect(afterAuth, contains('deviceData.uid'));
  });
}
