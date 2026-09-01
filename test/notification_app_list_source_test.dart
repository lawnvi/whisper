import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notification app picker includes known SMS packages from system apps',
      () {
    final source = File('lib/page/appList.dart').readAsStringSync();

    expect(source, contains('isVerificationCodeNotificationPackage'));
    expect(
      RegExp(
        r'InstalledApps\.getInstalledApps\([\s\S]*?excludeSystemApps:\s*false',
      ).hasMatch(source),
      isTrue,
    );
  });

  test('notification app picker keeps switch state in parent list state', () {
    final source = File('lib/page/appList.dart').readAsStringSync();

    expect(source, contains('final bool isChecked;'));
    expect(source, contains('value: isChecked'));
    expect(source, contains('Map<String, bool>.of(checkedApps)'));
    expect(source, contains('_updateAppChecked(app.packageName, value)'));
    expect(source, contains('Future<void> _commitSelection('));
    expect(source, contains('checkedApps = previousSelection;'));
    expect(source, contains('bool _isSaving = false;'));
    expect(source, isNot(contains('ValueNotifier<bool>')));
  });

  test('notification app picker avoids loading icons for every system app', () {
    final source = File('lib/page/appList.dart').readAsStringSync();

    expect(source, contains('Future<List<AppInfo>> _loadVisibleApps()'));
    expect(
      RegExp(
        r'InstalledApps\.getInstalledApps\([\s\S]*?excludeSystemApps:\s*false,[\s\S]*?withIcon:\s*false,',
      ).hasMatch(source),
      isTrue,
    );
    expect(source, contains('InstalledApps.getAppInfo(packageName)'));
    expect(
      RegExp(
        r'InstalledApps\.getInstalledApps\([\s\S]*?excludeSystemApps:\s*false,[\s\S]*?withIcon:\s*true,',
      ).hasMatch(source),
      isFalse,
    );
    expect(source, contains('AnimatedSwitcher('));
    expect(source, contains('final AppListLoader? loader;'));
    expect(source, contains('Widget _buildStatus('));
  });
}
