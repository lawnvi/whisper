import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('conversation can reconnect to a remembered peer after app restart', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final canToggleConnection = RegExp(
      r'bool get _canToggleConnection \{[\s\S]*?\n  \}',
    ).firstMatch(source)!.group(0)!;

    expect(canToggleConnection, contains('device.host.isNotEmpty'));
  });

  test('remote input action requires the connected peer capability', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final shouldShowRemoteInputAction = RegExp(
      r'bool get _shouldShowRemoteInputAction \{[\s\S]*?\n  \}',
    ).firstMatch(source)!.group(0)!;

    expect(
      shouldShowRemoteInputAction,
      contains('socketManager.supportsRemoteInputFor(device.uid)'),
    );
  });

  test('client settings hide remote input for non desktop peers', () {
    final source = File('lib/page/settings.dart').readAsStringSync();

    expect(source, contains('bool get _canConfigureRemoteInput'));
    expect(source, contains("platform.contains('windows')"));
    expect(
      source,
      contains('WsSvrManager().supportsRemoteInputFor(device.uid)'),
    );
  });
}
