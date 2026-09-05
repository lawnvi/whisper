import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/server_start_failure.dart';
import 'package:whisper/widget/device_connection_widgets.dart';
import 'package:whisper/widget/server_start_failure_dialog.dart';

Widget localized(Widget child, Locale locale) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  test(
    'classifies platform errno values without interpreting private error text',
    () {
      for (final code in [48, 98, 10048]) {
        expect(
          classifyServerStartFailure(
            SocketException('private', osError: OSError('', code)),
          ),
          ServerStartFailure.addressInUse,
        );
      }
      for (final code in [1, 13, 10013]) {
        expect(
          classifyServerStartFailure(OSError('', code)),
          ServerStartFailure.permissionDenied,
        );
      }
      expect(
        classifyServerStartFailure(StateError('address already in use')),
        ServerStartFailure.unavailable,
      );
    },
  );

  for (final language in ['zh', 'en', 'es']) {
    testWidgets('known devices show only the conversation hint in $language', (
      tester,
    ) async {
      await tester.pumpWidget(
        localized(
          DeviceConnectionWelcome(
            hasDevices: true,
            onPair: () {},
            onManualConnect: () {},
          ),
          Locale(language),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(DeviceConnectionWelcome)),
      )!;
      expect(find.text(l10n.selectConversationPlaceholder), findsOneWidget);
      expect(find.text(l10n.deviceConnectionGuide), findsNothing);
      expect(find.text(l10n.deviceDiscoveryHelp), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets(
      'welcome fits a narrow window and offers working actions in $language',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(380, 480));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var paired = false;
        var manual = false;
        await tester.pumpWidget(
          localized(
            DeviceConnectionWelcome(
              hasDevices: false,
              onPair: () => paired = true,
              onManualConnect: () => manual = true,
            ),
            Locale(language),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(FilledButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FilledButton));
        await tester.ensureVisible(find.byType(OutlinedButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(OutlinedButton));
        expect(paired && manual, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('loading known devices does not flash first-device setup', (
    tester,
  ) async {
    Widget welcome({required bool loading, required bool hasDevices}) =>
        localized(
          DeviceConnectionWelcome(
            isLoading: loading,
            hasDevices: hasDevices,
            onPair: () {},
            onManualConnect: () {},
          ),
          const Locale('zh'),
        );

    await tester.pumpWidget(welcome(loading: true, hasDevices: false));
    await tester.pumpAndSettle();
    expect(find.byType(Text), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);

    await tester.pumpWidget(welcome(loading: false, hasDevices: true));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(DeviceConnectionWelcome)),
    )!;
    expect(find.text(l10n.selectConversationPlaceholder), findsOneWidget);
    expect(find.text(l10n.connectFirstDevice), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('icon controls expose a label and an accessible tap action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    var tapped = false;
    await tester.pumpWidget(
      localized(
        DeviceToolbarButton(
          icon: Icons.add,
          label: '连接设备',
          onPressed: () => tapped = true,
        ),
        const Locale('zh'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.bySemanticsLabel('连接设备')),
      matchesSemantics(
        label: '连接设备',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );
    await tester.tap(find.bySemanticsLabel('连接设备'));
    expect(tapped, isTrue);
    semantics.dispose();
  });

  testWidgets(
    'server failure explains the cause and returns an explicit retry',
    (tester) async {
      ServerStartRecovery? result;
      await tester.pumpWidget(
        localized(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showServerStartFailureDialog(
                    context,
                    error: const SocketException(
                      'private path',
                      osError: OSError('', 48),
                    ),
                    port: 10002,
                  ),
              child: const Text('open'),
            ),
          ),
          const Locale('zh'),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('10002'), findsOneWidget);
      expect(find.textContaining('private path'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(result, ServerStartRecovery.retry);
    },
  );
}
