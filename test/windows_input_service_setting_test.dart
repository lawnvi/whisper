import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/app_update.dart';
import 'package:whisper/helper/windows_input_service.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/page/settings.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/windows_input_service_setting.dart';

const _presentation = SettingsPresentation(
  device: DeviceData(
    id: 0,
    uid: 'local-device',
    name: 'Studio PC',
    host: '192.168.1.5',
    port: 10002,
    platform: 'windows',
    isServer: true,
    online: true,
    clipboard: true,
    auth: false,
    lastTime: 0,
  ),
  saveDirectoryPath: r'C:\Users\tester\Downloads',
  version: '2.4.0',
  closeToTray: true,
  copyVerificationCode: true,
  listenAndroidNotifications: true,
  ignoreAndroidNotifications: false,
  autoConnect: true,
  launchAtStartup: false,
  androidBackgroundKeepAlive: true,
  audioSharePlaybackGain: 1.0,
  remoteInputScrollMultiplier: 1.0,
  themeMode: ThemeMode.system,
);

const _title = 'Keyboard and mouse on the lock screen';

class _NoUpdates implements AppUpdateManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const channel = MethodChannel('test/windows_input_service_setting');
  final calls = <String>[];
  late List<String> states;

  Future<WindowsInputServiceController> pumpSettings(
    WidgetTester tester,
  ) async {
    calls.clear();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method != 'getInputServiceState') return null;
      return states.length > 1 ? states.removeAt(0) : states.single;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = WindowsInputServiceController(
      channel: channel,
      supported: true,
      pollInterval: Duration.zero,
      pollAttempts: 3,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        locale: const Locale('en'),
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettingsScreen(
          presentationLoader: () async => _presentation,
          updateManager: _NoUpdates(),
          autoCheckForUpdates: false,
          windowsInputService: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(_title),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    calls.clear();
    return controller;
  }

  Finder row(String title) => find
      .ancestor(of: find.text(title), matching: find.byType(GestureDetector))
      .first;

  testWidgets('the row shows the service state as a value, not a control', (
    tester,
  ) async {
    states = <String>['notInstalled'];
    await pumpSettings(tester);

    final status = find.byType(WindowsLockScreenInputStatus);
    expect(
      find.descendant(of: status, matching: find.text('Not installed')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: status,
        matching: find.byIcon(Icons.arrow_forward_ios),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: status, matching: find.byType(ButtonStyleButton)),
      findsNothing,
    );
    expect(
      find.descendant(of: row(_title), matching: find.byType(CupertinoSwitch)),
      findsNothing,
    );
  });

  testWidgets('arrows centre on the row while switches stay by the title', (
    tester,
  ) async {
    states = <String>['running'];
    await pumpSettings(tester);

    // Two lines of text make the row taller than its accessory.
    final lockRow = row(_title);
    final arrow = find.descendant(
      of: lockRow,
      matching: find.byIcon(Icons.arrow_forward_ios),
    );
    expect(
      tester.getCenter(arrow).dy,
      moreOrLessEquals(tester.getCenter(lockRow).dy, epsilon: 1),
    );

    final startupRow = row('Launch at startup');
    final toggle = find.descendant(
      of: startupRow,
      matching: find.byType(CupertinoSwitch),
    );
    expect(
      tester.getCenter(toggle).dy,
      lessThan(tester.getCenter(startupRow).dy - 4),
    );
  });

  testWidgets('tapping the row confirms once, then installs', (tester) async {
    states = <String>['notInstalled', 'running'];
    final controller = await pumpSettings(tester);

    await tester.tap(find.text(_title));
    await tester.pumpAndSettle();
    // Says what is about to be installed before UAC asks.
    expect(find.textContaining('installs a system service'), findsOneWidget);
    expect(calls, isEmpty);

    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    expect(calls.first, 'installInputService');
    expect(controller.state, WindowsInputServiceState.running);
    expect(find.text('Running'), findsOneWidget);
  });

  testWidgets('a running service is only removed after confirmation', (
    tester,
  ) async {
    states = <String>['running', 'notInstalled'];
    final controller = await pumpSettings(tester);

    await tester.tap(find.text(_title));
    await tester.pumpAndSettle();
    expect(find.textContaining('After uninstalling'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(controller.state, WindowsInputServiceState.running);

    await tester.tap(find.text(_title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uninstall'));
    await tester.pumpAndSettle();

    expect(calls.first, 'uninstallInputService');
    expect(find.text('Not installed'), findsOneWidget);
  });

  for (final (state, value) in [
    ('stopped', 'Stopped'),
    ('outdated', 'Needs update'),
  ]) {
    testWidgets('a $state service is repaired by reinstalling over it', (
      tester,
    ) async {
      states = <String>[state, 'running'];
      await pumpSettings(tester);
      expect(find.text(value), findsOneWidget);

      await tester.tap(find.text(_title));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Repair'));
      await tester.pumpAndSettle();

      expect(calls.first, 'installInputService');
      expect(find.text('Running'), findsOneWidget);
    });
  }
}
