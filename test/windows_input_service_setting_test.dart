// What the Windows service row does when it is pressed. How the row looks is in
// new_settings_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/windows_input_service.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/windows_input_service_setting.dart';

void main() {
  const channel = MethodChannel('test/windows_input_service_setting');
  final calls = <String>[];
  late List<String> states;
  late bool elevated;

  Future<WindowsInputServiceController> pump(
    WidgetTester tester, {
    bool elevatedAllowed = false,
  }) async {
    elevated = elevatedAllowed;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'getElevatedInputAllowed') return elevated;
      if (call.method != 'getInputServiceState') return null;
      return states.length > 1 ? states.removeAt(0) : states.single;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final controller = WindowsInputServiceController(
      channel: channel,
      supported: true,
      pollInterval: Duration.zero,
      pollAttempts: 3,
    );
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => changeWindowsLockScreenInput(
                    context,
                    controller: controller,
                  ),
                  child: const Text('service'),
                ),
                TextButton(
                  onPressed: () => changeWindowsElevatedInput(
                    context,
                    !controller.elevatedAllowed,
                    controller: controller,
                  ),
                  child: const Text('uac'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    calls.clear();
    return controller;
  }

  Future<void> press(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  testWidgets('installing says what it does, then installs', (tester) async {
    states = <String>['notInstalled', 'running'];
    final controller = await pump(tester);

    await press(tester, 'service');
    expect(find.textContaining('installs a system service'), findsOneWidget);
    expect(calls, isEmpty);

    await press(tester, 'Install');
    expect(calls.first, 'installInputService');
    expect(controller.state, WindowsInputServiceState.running);
  });

  testWidgets('a running service is only removed after confirmation', (
    tester,
  ) async {
    states = <String>['running', 'notInstalled'];
    final controller = await pump(tester);

    await press(tester, 'service');
    expect(find.textContaining('After uninstalling'), findsOneWidget);
    await press(tester, 'Cancel');
    expect(calls, isEmpty);
    expect(controller.state, WindowsInputServiceState.running);

    await press(tester, 'service');
    await press(tester, 'Uninstall');
    expect(calls.first, 'uninstallInputService');
    expect(controller.state, WindowsInputServiceState.notInstalled);
  });

  for (final state in ['stopped', 'outdated']) {
    testWidgets('a $state service is repaired by reinstalling over it', (
      tester,
    ) async {
      states = <String>[state, 'running'];
      final controller = await pump(tester);

      await press(tester, 'service');
      await press(tester, 'Repair');
      expect(calls.first, 'installInputService');
      expect(controller.state, WindowsInputServiceState.running);
    });
  }

  testWidgets('UAC control is off unless the service runs', (tester) async {
    states = <String>['stopped'];
    final controller = await pump(tester, elevatedAllowed: true);
    expect(controller.elevatedAllowed, isFalse);
  });

  testWidgets('turning UAC control on warns before anything runs', (
    tester,
  ) async {
    states = <String>['running'];
    final controller = await pump(tester);

    await press(tester, 'uac');
    expect(find.textContaining('get past UAC'), findsOneWidget);
    expect(calls, isEmpty);

    elevated = true;
    await press(tester, 'Turn on');
    // It never installs or removes the service.
    expect(calls.first, 'enableElevatedInput');
    expect(calls, isNot(contains('uninstallInputService')));
    expect(controller.elevatedAllowed, isTrue);
  });

  testWidgets('declining the UAC warning changes nothing', (tester) async {
    states = <String>['running'];
    final controller = await pump(tester);

    await press(tester, 'uac');
    await press(tester, 'Cancel');
    expect(calls, isEmpty);
    expect(controller.elevatedAllowed, isFalse);
  });

  testWidgets('uninstalling also switches UAC control off', (tester) async {
    states = <String>['running', 'notInstalled'];
    final controller = await pump(tester, elevatedAllowed: true);
    expect(controller.elevatedAllowed, isTrue);

    await press(tester, 'service');
    expect(find.textContaining('lock screen and UAC prompts'), findsOneWidget);
    await press(tester, 'Uninstall');
    expect(calls.first, 'uninstallInputService');
    expect(calls, isNot(contains('disableElevatedInput')));
    expect(controller.elevatedAllowed, isFalse);
  });
}
