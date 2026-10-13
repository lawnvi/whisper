import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/widget/quick_send_chooser.dart';

void main() {
  const mac = QuickSendTarget(id: 'mac', name: 'Study iMac', platform: 'macos');
  const windows = QuickSendTarget(
    id: 'win',
    name: 'Laptop',
    platform: 'windows',
  );

  Future<Future<String?>> openSheet(
    WidgetTester tester, {
    required ValueNotifier<List<QuickSendTarget>> targets,
    List<QuickSendItem> items = const <QuickSendItem>[
      QuickSendItem.text('hello'),
    ],
  }) async {
    late Future<String?> result;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {
                  result = showQuickSendSheet(
                    context,
                    items: items,
                    targets: targets,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  bool sendEnabled(WidgetTester tester) {
    final button = tester.widget<TextButton>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('quick-send-confirm')),
        matching: find.byType(TextButton),
      ),
    );
    return button.onPressed != null;
  }

  testWidgets('a device that connects while the sheet is open is selected', (
    tester,
  ) async {
    final targets = ValueNotifier<List<QuickSendTarget>>(
      const <QuickSendTarget>[],
    );
    final result = await openSheet(tester, targets: targets);

    expect(find.text('还没有已连接的设备，连接后即可发送'), findsOneWidget);
    expect(sendEnabled(tester), isFalse);

    targets.value = const <QuickSendTarget>[mac];
    await tester.pumpAndSettle();

    expect(find.text('Study iMac'), findsOneWidget);
    expect(find.text('Mac'), findsOneWidget);
    expect(sendEnabled(tester), isTrue);

    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(await result, 'mac');
  });

  testWidgets('several devices wait for an explicit choice', (tester) async {
    final targets = ValueNotifier<List<QuickSendTarget>>(
      const <QuickSendTarget>[mac, windows],
    );
    final result = await openSheet(tester, targets: targets);

    expect(sendEnabled(tester), isFalse);
    await tester.tap(find.text('Laptop'));
    await tester.pumpAndSettle();
    expect(sendEnabled(tester), isTrue);

    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(await result, 'win');
  });

  testWidgets('a chosen device that disconnects clears the choice', (
    tester,
  ) async {
    final targets = ValueNotifier<List<QuickSendTarget>>(
      const <QuickSendTarget>[mac, windows],
    );
    final result = await openSheet(tester, targets: targets);

    await tester.tap(find.text('Laptop'));
    await tester.pumpAndSettle();
    targets.value = const <QuickSendTarget>[mac];
    await tester.pumpAndSettle();

    expect(find.text('Laptop'), findsNothing);
    // Only the remaining device is left, so it becomes the target.
    expect(sendEnabled(tester), isTrue);

    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('photos show as tiles and other files as rows', (tester) async {
    final targets = ValueNotifier<List<QuickSendTarget>>(
      const <QuickSendTarget>[mac],
    );
    await openSheet(
      tester,
      targets: targets,
      items: <QuickSendItem>[
        for (var index = 0; index < 9; index += 1)
          QuickSendItem.file(
            name: 'IMG_$index.jpg',
            source: '/nonexistent/IMG_$index.jpg',
          ),
        const QuickSendItem.file(
          name: 'clip',
          source: 'content://example/clip',
          mimeType: 'video/mp4',
          size: 2048,
        ),
        for (var index = 0; index < 5; index += 1)
          QuickSendItem.file(
            name: 'report-$index.pdf',
            source: '/nonexistent/report-$index.pdf',
            size: 1024,
          ),
      ],
    );

    expect(find.byKey(const ValueKey<String>('quick-send-media')), findsOne);
    expect(find.textContaining(RegExp(r'^\+\d+$')), findsOneWidget);
    expect(find.text('report-0.pdf'), findsOneWidget);
    expect(find.text('report-2.pdf'), findsOneWidget);
    expect(find.text('report-3.pdf'), findsNothing);
    expect(find.text('另有 2 个文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('media kind follows the mime type when the name has no extension', () {
    const video = QuickSendItem.file(
      name: 'clip',
      source: 'content://example/clip',
      mimeType: 'video/mp4',
    );
    const unknown = QuickSendItem.file(
      name: 'clip',
      source: 'content://example/clip',
    );
    expect(video.isVisualMedia, isTrue);
    expect(unknown.isVisualMedia, isFalse);
  });

  test('device list only offers connected, trusted devices', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final start = source.indexOf(
      'List<QuickSendTarget> _connectedQuickSendTargets()',
    );
    expect(start, greaterThanOrEqualTo(0));
    final body = source.substring(start, source.indexOf('\n  }\n', start));
    expect(body, contains('!socketManager.isConnectedTo(candidate.uid)'));
    expect(body, contains('_trustedDeviceIdentityHash(candidate.uid) == null'));
    expect(
      source,
      contains('_quickSendTargets.value = _connectedQuickSendTargets()'),
    );
    expect(source, contains('targets: _quickSendTargets'));
    expect(source, isNot(contains('androidSystemShareOffline')));
    expect(source, isNot(contains('RadioListTile')));
  });
}
