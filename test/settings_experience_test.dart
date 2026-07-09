import 'dart:io';
import 'dart:ui' show SemanticsFlag;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/page/settings.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_interactive_tile.dart';

const _device = DeviceData(
  id: 0,
  uid: 'local-device',
  name: 'Studio Mac',
  host: '192.168.1.5',
  port: 10002,
  platform: 'macos',
  isServer: true,
  online: true,
  clipboard: true,
  auth: false,
  lastTime: 0,
);

const _presentation = SettingsPresentation(
  device: _device,
  saveDirectoryPath:
      '/Users/tester/Documents/Whisper received files/Project archive',
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

Widget _host({Locale locale = const Locale('en'), double textScale = 1}) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    locale: locale,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: SettingsScreen(
      presentationLoader: () async => _presentation,
      changeDirectory: () async => '/tmp/Whisper',
      openDirectory: (_) async {},
      updateNickname: (_) async {},
      updateServerPort: (_) async {},
    ),
  );
}

Future<void> _pumpAt(
  WidgetTester tester, {
  required double width,
  double textScale = 1,
  Locale locale = const Locale('en'),
}) async {
  tester.view
    ..physicalSize = Size(width, 900)
    ..devicePixelRatio = 1;
  await tester.pumpWidget(_host(locale: locale, textScale: textScale));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearAllTestValues();
  });

  testWidgets('uses a centered 760 px settings column with section subtitles',
      (tester) async {
    await _pumpAt(tester, width: 1440);

    final list = find.byType(ListView).first;
    expect(tester.getSize(list).width, WhisperUi.settingsMaxWidth);
    expect(
      tester
          .widget<ConstrainedBox>(find
              .ancestor(
                of: list,
                matching: find.byType(ConstrainedBox),
              )
              .first)
          .constraints
          .maxWidth,
      WhisperUi.settingsMaxWidth,
    );
    expect(find.text('Device and appearance'), findsOneWidget);
    expect(
      find.text('Name, theme, and how this device appears nearby'),
      findsOneWidget,
    );
    expect(find.byType(AppInteractiveTile), findsWidgets);

    for (final tile in find.byType(AppInteractiveTile).evaluate()) {
      expect(tester.getSize(find.byWidget(tile.widget)).height,
          greaterThanOrEqualTo(56));
    }
  });

  testWidgets('settings remain usable at supported widths and 200 percent text',
      (tester) async {
    for (final width in <double>[390, 760, 1440]) {
      await _pumpAt(tester, width: width, textScale: 2);
      expect(tester.takeException(), isNull, reason: 'width $width');
      expect(
        tester.getSize(find.byType(ListView).first).width,
        lessThanOrEqualTo(WhisperUi.settingsMaxWidth),
      );
    }
  });

  testWidgets('section titles and subtitles follow all supported locales',
      (tester) async {
    const expectations = <(Locale, String, String)>[
      (Locale('zh'), '设备与外观', '名称、主题和本机在附近设备上的显示方式'),
      (
        Locale('en'),
        'Device and appearance',
        'Name, theme, and how this device appears nearby',
      ),
      (
        Locale('es'),
        'Dispositivo y apariencia',
        'Nombre, tema y visibilidad de este dispositivo en la red cercana',
      ),
    ];

    for (final entry in expectations) {
      await _pumpAt(tester, width: 760, locale: entry.$1);
      expect(find.text(entry.$2), findsOneWidget);
      expect(find.text(entry.$3), findsOneWidget);
    }
  });

  testWidgets('save directory exposes selectable text and two explicit actions',
      (tester) async {
    await _pumpAt(tester, width: 760);
    await tester.scrollUntilVisible(
      find.text('Language and files'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data == _presentation.saveDirectoryPath,
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Change save directory'), findsOneWidget);
    expect(find.byTooltip('Open save directory'), findsOneWidget);

    final changeButton =
        tester.getSize(find.byTooltip('Change save directory'));
    final openButton = tester.getSize(find.byTooltip('Open save directory'));
    expect(changeButton.shortestSide,
        greaterThanOrEqualTo(WhisperUi.minInteractiveSize));
    expect(openButton.shortestSide,
        greaterThanOrEqualTo(WhisperUi.minInteractiveSize));
  });

  testWidgets('switch row owns one merged toggled semantic action',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpAt(tester, width: 760);

    final tile = find.widgetWithText(
        AppInteractiveTile, 'Auto-connect mutually trusted devices');
    final node = tester.getSemantics(tile);
    expect(node.label, 'Auto-connect mutually trusted devices');
    expect(node.hasFlag(SemanticsFlag.hasToggledState), isTrue);
    expect(node.hasFlag(SemanticsFlag.isToggled), isTrue);
    expect(
      find.ancestor(
        of: find.descendant(of: tile, matching: find.byType(CupertinoSwitch)),
        matching: find.byType(ExcludeFocus),
      ),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    semantics.dispose();
  });

  testWidgets('nickname and port validation stays inline and accepts limits',
      (tester) async {
    await _pumpAt(tester, width: 760);

    await tester.tap(find.text('Nickname'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '');
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(find.text('Enter a nickname'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), '${'a' * 64}\u{1F680}');
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(
        find.text('Nickname must be 64 characters or fewer'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Server Port'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '1000');
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(find.text('Enter a port from 1001 to 65535'), findsWidgets);
  });

  test('settings source has no legacy fallbacks, long press, or custom font',
      () {
    final source = File('lib/page/settings.dart').readAsStringSync();

    expect(source, isNot(contains('onLongPress')));
    expect(source, isNot(contains('SF Pro Display')));
    expect(source, isNot(contains('Save directory')));
    expect(source, isNot(contains('_settingsSectionText')));
    expect(
      RegExp(r'AppLocalizations[^;\n]*\?\?').hasMatch(source),
      isFalse,
    );
    expect(source, contains('confirmAction('));
    expect(source, contains('isDestructive: true'));
    expect(source, contains('showValidatedInputDialog('));
  });
}
