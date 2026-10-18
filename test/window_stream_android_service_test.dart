import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/page/window_stream/android_service/android_service_controller.dart';
import 'package:whisper/page/window_stream/android_service/android_service_page.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  const agent = MethodChannel('com.vireen.whisper/window_stream_agent');
  const selfStart = MethodChannel(
    'com.vireen.whisper/window_stream_self_start',
  );

  void mock({required bool canSelfStart, Object? link}) {
    final binding = TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(agent, (
      call,
    ) async {
      return call.method == 'link' ? link : null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(selfStart, (
      call,
    ) async {
      return switch (call.method) {
        'available' => canSelfStart,
        'autoStart' => false,
        _ => false,
      };
    });
  }

  tearDown(() {
    final binding = TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(agent, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(selfStart, null);
  });

  Widget app(AndroidWindowServiceController controller) => MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: AppTheme.lightTheme,
    home: AndroidWindowServicePage(controller: controller),
  );

  testWidgets('no link, self-start on: shows the guided setup', (tester) async {
    mock(canSelfStart: true, link: null);
    final controller = AndroidWindowServiceController();
    await tester.pumpWidget(app(controller));
    await tester.pumpAndSettle();
    expect(find.text('窗口流转服务'), findsWidgets);
    expect(find.text('未设置'), findsOneWidget);
    // The three setup steps and the pairing field.
    expect(find.text('打开开发者选项'), findsOneWidget);
    expect(find.text('输入配对码'), findsOneWidget);
    expect(find.text('配对并开启'), findsOneWidget);
  });

  testWidgets('no link, self-start off: points at a computer', (tester) async {
    mock(canSelfStart: false, link: null);
    final controller = AndroidWindowServiceController();
    await tester.pumpWidget(app(controller));
    await tester.pumpAndSettle();
    expect(find.text('未设置'), findsOneWidget);
    // No pairing UI; a hint to use a computer once instead.
    expect(find.text('配对并开启'), findsNothing);
    expect(find.textContaining('电脑'), findsWidgets);
  });
}
