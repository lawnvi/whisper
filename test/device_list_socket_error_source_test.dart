import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device list awaits confirmation and localizes socket close errors', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final start = source.indexOf('void onError(String message)');
    final end = source.indexOf('void onNotice(String message)', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final section = source.substring(start, end);

    expect(section, contains('unawaited(_handleSocketError(message));'));
    expect(section, contains('if (!mounted) {'));
    expect(
      section.indexOf('if (!mounted) {'),
      lessThan(section.indexOf('AppLocalizations.of(context)')),
    );
    expect(section, contains('final confirmed = await app_dialogs.confirmAction('));
    expect(section, contains('await WsSvrManager().close();'));
    expect(section, contains('catch (error)'));
    expect(section, contains('if (mounted) {'));
    expect(
      section,
      contains(
        '_logDeviceListFailure(DeviceListOperationKind.socketDialog, error);',
      ),
    );
    expect(
      section,
      contains("showAppToast(l10n?.connectFailed ?? 'Connection Failed');"),
    );
    expect(section, isNot(contains('error.toString()')));
    expect(section, isNot(contains('showConfirmationDialog(')));
    expect(section, isNot(contains('isDestructive: true')));
  });
}
