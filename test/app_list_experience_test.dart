import 'dart:async';
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
  AppSelectionWriter? selectionWriter,
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
      selectionWriter: selectionWriter ??
          ({required packages, required add, clear = false}) async {},
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

  testWidgets('loader failure is consumed and retry restores the list',
      (tester) async {
    var attempts = 0;
    tester.view
      ..physicalSize = const Size(390, 900)
      ..devicePixelRatio = 1;
    await tester.pumpWidget(
      _host(loader: () async {
        attempts += 1;
        if (attempts == 1) {
          throw StateError('no permission');
        }
        return const AppListPresentation(
          apps: <AppInfo>[_mail],
          selectedPackages: <String>{},
        );
      }),
    );
    await tester.pumpAndSettle();

    expect(find.text('Apps could not be loaded'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Mail'), findsOneWidget);
  });

  testWidgets('failed item write rolls back and reports localized feedback',
      (tester) async {
    final pending = Completer<void>();
    final calls = <({List<String> packages, bool add, bool clear})>[];
    tester.view
      ..physicalSize = const Size(760, 900)
      ..devicePixelRatio = 1;
    await tester.pumpWidget(
      _host(
        loader: () async => const AppListPresentation(
          apps: <AppInfo>[_mail, _messages],
          selectedPackages: <String>{},
        ),
        selectionWriter: ({required packages, required add, clear = false}) {
          calls.add(
              (packages: List<String>.of(packages), add: add, clear: clear));
          return pending.future;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mail'));
    await tester.pump();
    var mail = tester.widget<AppInteractiveTile>(
      find.widgetWithText(AppInteractiveTile, 'Mail'),
    );
    expect(mail.toggled, isTrue);
    expect(mail.enabled, isFalse);
    final selectAllButton = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .singleWhere((button) => button.tooltip == 'Select All');
    expect(
      selectAllButton.onPressed,
      isNull,
    );
    expect(calls.single.packages, <String>['com.example.mail']);
    expect(calls.single.add, isTrue);
    expect(calls.single.clear, isFalse);

    pending.completeError(StateError('disk full'));
    await tester.pumpAndSettle();
    mail = tester.widget<AppInteractiveTile>(
      find.widgetWithText(AppInteractiveTile, 'Mail'),
    );
    expect(mail.toggled, isFalse);
    expect(mail.enabled, isTrue);
    expect(find.text('Could not save the notification app selection'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'one busy boundary prevents reordering and persists exact intents',
      (tester) async {
    final firstWrite = Completer<void>();
    final calls = <({List<String> packages, bool add, bool clear})>[];
    final persisted = <String>{};
    tester.view
      ..physicalSize = const Size(760, 900)
      ..devicePixelRatio = 1;
    await tester.pumpWidget(
      _host(
        loader: () async => const AppListPresentation(
          apps: <AppInfo>[_mail, _messages],
          selectedPackages: <String>{},
        ),
        selectionWriter: (
            {required packages, required add, clear = false}) async {
          calls.add(
              (packages: List<String>.of(packages), add: add, clear: clear));
          if (calls.length == 1) {
            await firstWrite.future;
          }
          if (clear) {
            persisted.clear();
          } else if (add) {
            persisted.addAll(packages);
          } else {
            persisted.removeAll(packages);
          }
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mail'));
    await tester.tap(find.text('Messages'));
    expect(calls, hasLength(1));
    firstWrite.complete();
    await tester.pumpAndSettle();
    expect(persisted, <String>{'com.example.mail'});

    await tester.tap(find.byTooltip('Select All'));
    await tester.pumpAndSettle();
    expect(calls[1].packages,
        <String>['com.example.mail', 'com.example.messages']);
    expect(calls[1].add, isTrue);
    expect(calls[1].clear, isFalse);
    expect(persisted, <String>{'com.example.mail', 'com.example.messages'});

    await tester.tap(find.byTooltip('Deselect all'));
    await tester.pumpAndSettle();
    expect(calls[2].packages,
        <String>['com.example.mail', 'com.example.messages']);
    expect(calls[2].add, isFalse);
    expect(calls[2].clear, isTrue);
    expect(persisted, isEmpty);

    await tester.tap(find.text('Mail'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mail'));
    await tester.pumpAndSettle();
    expect(calls[3].packages, <String>['com.example.mail']);
    expect(calls[3].add, isTrue);
    expect(calls[3].clear, isFalse);
    expect(calls[4].packages, <String>['com.example.mail']);
    expect(calls[4].add, isFalse);
    expect(calls[4].clear, isFalse);
    expect(persisted, isEmpty);
    final selectedInUi = tester
        .widgetList<AppInteractiveTile>(find.byType(AppInteractiveTile))
        .where((tile) => tile.toggled == true)
        .map((tile) => tile.semanticLabel)
        .toSet();
    expect(selectedInUi, isEmpty);
  });

  testWidgets('disposing during a failed write does not leak an exception',
      (tester) async {
    final pending = Completer<void>();
    tester.view
      ..physicalSize = const Size(760, 900)
      ..devicePixelRatio = 1;
    await tester.pumpWidget(
      _host(
        loader: () async => const AppListPresentation(
          apps: <AppInfo>[_mail],
          selectedPackages: <String>{},
        ),
        selectionWriter: ({required packages, required add, clear = false}) =>
            pending.future,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mail'));
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(StateError('late failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
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
