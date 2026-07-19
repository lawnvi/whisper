import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_dialogs.dart';

void main() {
  testWidgets('invalid input shows an inline error and keeps dialog open',
      (tester) async {
    await _pumpHost(tester);
    final context = tester.element(find.byType(Scaffold));

    showValidatedInputDialog(
      context,
      title: 'Connect',
      description: 'Enter a host',
      fields: <InputDialogField>[
        InputDialogField(
          initialValue: '',
          label: 'Host',
          validator: (value) => value.isEmpty ? 'Host is required' : null,
        ),
      ],
      confirmButtonText: 'Connect',
      cancelButtonText: 'Cancel',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Connect'));
    await tester.pump();

    expect(find.text('Host is required'), findsOneWidget);
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
  });

  testWidgets('valid Enter returns trimmed values', (tester) async {
    await _pumpHost(tester);
    final context = tester.element(find.byType(Scaffold));

    final result = showValidatedInputDialog(
      context,
      title: 'Rename',
      fields: <InputDialogField>[
        InputDialogField(
          initialValue: 'Old name',
          label: 'Nickname',
          validator: (value) => value.isEmpty ? 'Required' : null,
        ),
      ],
      confirmButtonText: 'Save',
      cancelButtonText: 'Cancel',
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(CupertinoTextField), '  Desk Mac  ');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(await result, <String>['Desk Mac']);
  });

  testWidgets('Escape cancels validated input with null', (tester) async {
    await _pumpHost(tester);
    final context = tester.element(find.byType(Scaffold));

    final result = showValidatedInputDialog(
      context,
      title: 'Rename',
      fields: const <InputDialogField>[
        InputDialogField(initialValue: 'Desk', label: 'Nickname'),
      ],
      confirmButtonText: 'Save',
      cancelButtonText: 'Cancel',
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(await result, isNull);
  });

  testWidgets('destructive confirmation retains the original Cupertino colors',
      (tester) async {
    await _pumpHost(tester, theme: AppTheme.lightTheme);
    final context = tester.element(find.byType(Scaffold));

    final result = confirmAction(
      context,
      title: 'Delete device?',
      description: 'Local history will also be deleted.',
      confirmButtonText: 'Delete',
      cancelButtonText: 'Cancel',
      isDestructive: true,
    );
    await tester.pumpAndSettle();

    final confirmText = tester.widget<Text>(
      find.descendant(
        of: find.widgetWithText(CupertinoDialogAction, 'Delete'),
        matching: find.text('Delete'),
      ),
    );
    final cancelFinder = find.widgetWithText(CupertinoDialogAction, 'Cancel');
    final cancelText = tester.widget<Text>(
      find.descendant(of: cancelFinder, matching: find.text('Cancel')),
    );
    expect(confirmText.style?.color, Colors.red);
    expect(cancelText.style?.color, Colors.red);
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);

    await tester.tap(cancelFinder);
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });
}

Future<void> _pumpHost(
  WidgetTester tester, {
  ThemeData? theme,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: const Scaffold(body: SizedBox.expand()),
    ),
  );
}
