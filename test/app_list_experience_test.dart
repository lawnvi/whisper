import 'dart:ui' show SemanticsFlag;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:installed_apps/app_category.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/platform_type.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/page/appList.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_empty_state.dart';
import 'package:whisper/widget/app_interactive_tile.dart';

const _mail = AppInfo(
  name: 'Mail',
  icon: null,
  packageName: 'com.example.mail',
  versionName: '1.0',
  versionCode: 1,
  platformType: PlatformType.nativeOrOthers,
  installedTimestamp: 0,
  isSystemApp: false,
  isLaunchableApp: true,
  category: AppCategory.productivity,
);

const _messages = AppInfo(
  name: 'Messages',
  icon: null,
  packageName: 'com.example.messages',
  versionName: '1.0',
  versionCode: 1,
  platformType: PlatformType.nativeOrOthers,
  installedTimestamp: 0,
  isSystemApp: true,
  isLaunchableApp: true,
  category: AppCategory.social,
);

Widget _host({
  required AppListLoader loader,
  Locale locale = const Locale('en'),
  double textScale = 1,
}) {
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
    home: AppListScreen(
      loader: loader,
      selectionWriter: (
          {required packages, required add, clear = false}) async {},
    ),
  );
}

Future<void> _pumpAt(
  WidgetTester tester, {
  required double width,
  double textScale = 1,
  required AppListPresentation presentation,
}) async {
  tester.view
    ..physicalSize = Size(width, 900)
    ..devicePixelRatio = 1;
  await tester.pumpWidget(
    _host(loader: () async => presentation, textScale: textScale),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearAllTestValues();
  });

  testWidgets('loaded empty list uses the localized empty state',
      (tester) async {
    await _pumpAt(
      tester,
      width: 390,
      presentation: const AppListPresentation(
        apps: <AppInfo>[],
        selectedPackages: <String>{},
      ),
    );

    expect(find.byType(AppEmptyState), findsOneWidget);
    expect(find.text('No apps available'), findsOneWidget);
    expect(find.text('No notification apps are available on this device.'),
        findsOneWidget);
  });

  testWidgets('no-result state clears back to the full app list',
      (tester) async {
    await _pumpAt(
      tester,
      width: 760,
      presentation: const AppListPresentation(
        apps: <AppInfo>[_mail, _messages],
        selectedPackages: <String>{'com.example.messages'},
      ),
    );

    expect(find.text('Search apps'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'calendar');
    await tester.pump();

    expect(find.byType(AppEmptyState), findsOneWidget);
    expect(find.text('No apps found'), findsOneWidget);
    await tester.tap(find.text('Clear app search'));
    await tester.pump();

    expect(find.text('Mail'), findsOneWidget);
    expect(find.text('Messages'), findsOneWidget);
    expect(find.byType(AppEmptyState), findsNothing);
  });

  testWidgets('search placeholder follows the current locale', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 900)
      ..devicePixelRatio = 1;
    await tester.pumpWidget(
      _host(
        locale: const Locale('es'),
        loader: () async => const AppListPresentation(
          apps: <AppInfo>[_mail],
          selectedPackages: <String>{},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Buscar aplicaciones'), findsOneWidget);
  });

  testWidgets('select all ignores stale package selections', (tester) async {
    var added = false;
    tester.view
      ..physicalSize = const Size(760, 900)
      ..devicePixelRatio = 1;
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
        home: AppListScreen(
          loader: () async => const AppListPresentation(
            apps: <AppInfo>[_mail, _messages],
            selectedPackages: <String>{
              'com.example.messages',
              'com.example.uninstalled',
            },
          ),
          selectionWriter: (
              {required packages, required add, clear = false}) async {
            added = add;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Select All'));
    await tester.pump();

    expect(added, isTrue);
    final tiles = tester
        .widgetList<AppInteractiveTile>(find.byType(AppInteractiveTile))
        .toList(growable: false);
    expect(tiles.every((tile) => tile.toggled == true), isTrue);
  });

  testWidgets(
      'app row merges name package and switch state into one focus target',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpAt(
      tester,
      width: 760,
      presentation: const AppListPresentation(
        apps: <AppInfo>[_messages],
        selectedPackages: <String>{'com.example.messages'},
      ),
    );

    final tile = find.byType(AppInteractiveTile);
    expect(tile, findsOneWidget);
    final node = tester.getSemantics(tile);
    expect(node.label, contains('Messages'));
    expect(node.label, contains('com.example.messages'));
    expect(node.hasFlag(SemanticsFlag.hasToggledState), isTrue);
    expect(node.hasFlag(SemanticsFlag.isToggled), isTrue);
    expect(
      find.ancestor(
        of: find.descendant(of: tile, matching: find.byType(CupertinoSwitch)),
        matching: find.byType(ExcludeFocus),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ExcludeFocus>(find.descendant(
            of: tile,
            matching: find.byType(ExcludeFocus),
          ))
          .excluding,
      isTrue,
    );
    semantics.dispose();
  });

  testWidgets('app list remains overflow-free across supported widths',
      (tester) async {
    for (final width in <double>[390, 760, 1440]) {
      await _pumpAt(
        tester,
        width: width,
        textScale: 2,
        presentation: const AppListPresentation(
          apps: <AppInfo>[_mail, _messages],
          selectedPackages: <String>{},
        ),
      );
      expect(tester.takeException(), isNull, reason: 'width $width');
      expect(
        tester.getSize(find.byType(AppInteractiveTile).first).height,
        greaterThanOrEqualTo(56),
      );
    }
  });
}
