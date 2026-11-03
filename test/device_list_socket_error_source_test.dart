import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_reading.dart';

void main() {
  test('device list awaits confirmation and localizes socket close errors', () {
    final source = deviceListSource();
    expect(
      memberSource(source, 'void onError(String message)'),
      contains('unawaited(_handleSocketError(message));'),
    );
    final section = memberSource(source, 'Future<void> _handleSocketError(');

    expect(section, contains('if (!mounted) {'));
    expect(
      section.indexOf('if (!mounted) {'),
      lessThan(section.indexOf('AppLocalizations.of(context)')),
    );
    expect(
      section,
      contains('final confirmed = await app_dialogs.confirmAction('),
    );
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
      matches(
        RegExp(
          r"showAppToast\(\s*l10n\?\.connectFailed \?\? 'Connection Failed',"
          r'\s*tone: AppToastTone\.error,\s*\);',
        ),
      ),
    );
    expect(section, isNot(contains('error.toString()')));
    expect(section, isNot(contains('showConfirmationDialog(')));
    expect(section, isNot(contains('isDestructive: true')));
  });
}
