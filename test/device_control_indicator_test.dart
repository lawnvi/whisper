import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/computer_control_icon.dart';
import 'package:whisper/widget/device_connection_widgets.dart';

Widget tile({
  VoidCallback? onStop,
  VoidCallback? onSelect,
  bool connecting = false,
}) => DesktopDeviceSessionTile(
  name: 'My Android phone',
  identity: 'Android · 123456',
  statusLabel: 'Connected',
  preview: 'Latest message',
  time: '14:30',
  avatar: const CircleAvatar(radius: 24, child: Icon(Icons.phone_android)),
  statusColor: Colors.blue,
  selected: true,
  trusted: true,
  onTap: onSelect ?? () {},
  onStopControl: onStop,
  controlConnecting: connecting,
);

Widget app(
  Widget child, {
  String language = 'en',
  bool dark = false,
  double textScale = 1,
}) => MaterialApp(
  locale: Locale(language),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, children: [child]),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'control is visible on its device and stop does not select the row',
    (tester) async {
      var stops = 0;
      var selections = 0;
      await tester.pumpWidget(
        app(tile(onStop: () => stops++, onSelect: () => selections++)),
      );
      expect(find.text('Controlling'), findsOneWidget);
      expect(find.text('Latest message'), findsNothing);
      expect(find.byType(ComputerControlIcon), findsOneWidget);
      final stop = find.byTooltip(
        'This computer is controlled by My Android phone\nStop control',
      );
      expect(tester.getSize(stop).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(stop).height, greaterThanOrEqualTo(48));
      await tester.tap(stop);
      expect(stops, 1);
      expect(selections, 0);
      await tester.tap(find.text('My Android phone'));
      expect(selections, 1);

      await tester.pumpWidget(app(tile()));
      expect(find.byType(ComputerControlIcon), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Controlling'), findsNothing);
      expect(find.text('Latest message'), findsOneWidget);
    },
  );

  testWidgets(
    'control action has a full accessible label and keyboard activation',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var stops = 0;
      await tester.pumpWidget(app(tile(onStop: () => stops++)));
      final label = find.bySemanticsLabel(
        'This computer is controlled by My Android phone\nStop control',
      );
      expect(label, findsOneWidget);
      expect(
        tester.getSemantics(label),
        matchesSemantics(
          label:
              'This computer is controlled by My Android phone\nStop control',
          isButton: true,
          hasTapAction: true,
          hasFocusAction: true,
          isEnabled: true,
          hasEnabledState: true,
          isFocusable: true,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(stops, 1);
      semantics.dispose();
    },
  );

  for (final language in ['zh', 'en', 'es']) {
    for (final dark in [false, true]) {
      testWidgets(
        'control states fit the sidebar in $language / dark=$dark / large text',
        (tester) async {
          for (final connecting in [true, false]) {
            await tester.pumpWidget(
              app(
                tile(onStop: () {}, connecting: connecting),
                language: language,
                dark: dark,
                textScale: 2,
              ),
            );
            final l10n = AppLocalizations.of(
              tester.element(find.byType(DesktopDeviceSessionTile)),
            )!;
            expect(
              find.text(
                connecting
                    ? l10n.mobileControlPreparing
                    : l10n.mobileControlActive,
              ),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
            final button = tester.getRect(find.byType(IconButton));
            expect(button.right, lessThanOrEqualTo(320));
          }
        },
      );
    }
  }
}
