import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_interactive_tile.dart';

void main() {
  testWidgets('meets target, semantics, and keyboard activation requirements',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var activations = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 280,
              child: AppInteractiveTile(
                semanticLabel: 'Nearby Mac',
                selected: true,
                onActivate: () => activations += 1,
                leading: const Icon(Icons.computer),
                title: const Text('MacBook'),
                subtitle: const Text('Connected'),
                trailing: const Icon(Icons.chevron_right),
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(AppInteractiveTile)).height,
      greaterThanOrEqualTo(WhisperUi.minInteractiveSize),
    );
    expect(
      tester.getSemantics(find.byType(AppInteractiveTile)),
      matchesSemantics(
        label: 'Nearby Mac',
        hasEnabledState: true,
        isEnabled: true,
        hasSelectedState: true,
        isSelected: true,
        isButton: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(activations, 2);

    semantics.dispose();
  });

  testWidgets('disabled tile stays focus-visible and cannot activate',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var activations = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: AppInteractiveTile(
            semanticLabel: 'Unavailable device',
            enabled: false,
            onActivate: () => activations += 1,
            title: const Text('Unavailable'),
          ),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final focusDecoration = tester.widget<AnimatedContainer>(
      find.byKey(AppInteractiveTile.focusIndicatorKey),
    );
    final boxDecoration = focusDecoration.decoration! as BoxDecoration;
    final border = boxDecoration.border! as Border;
    expect(border.top.width, 2);
    expect(border.top.color, AppTheme.darkTheme.colorScheme.primary);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.tap(find.byType(AppInteractiveTile));
    expect(activations, 0);
    expect(
      tester.getSemantics(find.byType(AppInteractiveTile)),
      matchesSemantics(
        label: 'Unavailable device',
        hasEnabledState: true,
        hasSelectedState: true,
        isButton: true,
        isFocusable: true,
        isFocused: true,
        hasFocusAction: true,
      ),
    );

    semantics.dispose();
  });
}
