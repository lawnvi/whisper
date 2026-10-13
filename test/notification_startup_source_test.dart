import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('start-up does not hand Windows to the notification plugin', () {
    final helper = File('lib/helper/notification.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    // The plugin throws on Windows unless it is given Windows settings, and
    // the app is only started after this call returns.
    expect(
      main.indexOf('await notificationHelper.initialize();'),
      inInclusiveRange(0, main.indexOf('runApp(MyApp());')),
    );
    final initialize = helper.substring(
      helper.indexOf('Future<void> initialize() async {'),
      helper.indexOf('Future<void> requestIOSPermissions() async {'),
    );
    expect(
      initialize.indexOf('if (!supportNotification()) {\n      return;'),
      inInclusiveRange(
        0,
        initialize.indexOf('_notificationsPlugin.initialize('),
      ),
    );
    expect(initialize, isNot(contains('windows:')));

    final supported = helper.substring(
      helper.indexOf('bool supportNotification() {'),
      helper.indexOf('String pkg2name('),
    );
    expect(supported, isNot(contains('isWindows')));
  });
}
