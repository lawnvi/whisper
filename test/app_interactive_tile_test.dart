import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_interactive_tile.dart';

void main() {
  testWidgets('reserves a 44 by 44 target without parent width constraints',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const Scaffold(
          body: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AppInteractiveTile(
                semanticLabel: 'Compact action',
                onActivate: _noop,
                title: SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byType(AppInteractiveTile));
    expect(size.width, greaterThanOrEqualTo(WhisperUi.minInteractiveSize));
    expect(size.height, greaterThanOrEqualTo(WhisperUi.minInteractiveSize));
  });

  testWidgets('exposes an optional toggled semantic state', (tester) async {
    final semantics = tester.ensureSemantics();

    Widget host(bool? toggled) => MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: AppInteractiveTile(
              semanticLabel: 'Clipboard sync',
              toggled: toggled,
              onActivate: _noop,
              title: const Text('Clipboard sync'),
            ),
          ),
        );

    await tester.pumpWidget(host(true));
    var node = tester.getSemantics(find.byType(AppInteractiveTile));
    expect(node.hasFlag(SemanticsFlag.hasToggledState), isTrue);
    expect(node.hasFlag(SemanticsFlag.isToggled), isTrue);

    await tester.pumpWidget(host(null));
    node = tester.getSemantics(find.byType(AppInteractiveTile));
    expect(node.hasFlag(SemanticsFlag.hasToggledState), isFalse);
    expect(node.hasFlag(SemanticsFlag.isToggled), isFalse);

    semantics.dispose();
  });

  testWidgets('selected boundary keeps three-to-one rendered contrast',
      (tester) async {
    for (final theme in <ThemeData>[
      AppTheme.lightTheme,
      AppTheme.darkTheme,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 240,
                child: AppInteractiveTile(
                  semanticLabel: 'Selected device',
                  selected: true,
                  onActivate: _noop,
                  title: Text('Selected device'),
                ),
              ),
            ),
          ),
        ),
      );

      final surface = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byType(AppInteractiveTile),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final decoration = surface.decoration! as BoxDecoration;
      final background = Color.alphaBlend(
        decoration.color!,
        theme.colorScheme.surface,
      );
      final border = decoration.border! as Border;
      final renderedBoundary = Color.alphaBlend(border.top.color, background);

      expect(
        _contrast(renderedBoundary, background),
        greaterThanOrEqualTo(3),
        reason: theme.brightness.name,
      );
    }
  });

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
            selected: true,
            enabled: false,
            onActivate: () => activations += 1,
            title: const Text('Unavailable'),
          ),
        ),
      ),
    );

    final sizeBeforeFocus = tester.getSize(find.byType(AppInteractiveTile));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final focusRect = tester.getRect(
      find.byKey(AppInteractiveTile.focusIndicatorKey),
    );
    final visualRect = tester.getRect(
      find.byKey(AppInteractiveTile.visualSurfaceKey),
    );
    expect(
      visualRect,
      Rect.fromLTRB(
        focusRect.left + 4,
        focusRect.top + 4,
        focusRect.right - 4,
        focusRect.bottom - 4,
      ),
    );
    const paintedFocusStrokeWidth = 2.0;
    expect(
      visualRect.left - (focusRect.left + paintedFocusStrokeWidth),
      2,
      reason: 'the rendered surface must leave a 2 px gap after the focus ring',
    );
    expect(tester.getSize(find.byType(AppInteractiveTile)), sizeBeforeFocus);

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
        isSelected: true,
        isButton: true,
        isFocusable: true,
        isFocused: true,
        hasFocusAction: true,
      ),
    );

    semantics.dispose();
  });
}

void _noop() {}

double _contrast(Color foreground, Color background) {
  final lighter = foreground.computeLuminance() > background.computeLuminance()
      ? foreground.computeLuminance()
      : background.computeLuminance();
  final darker = foreground.computeLuminance() > background.computeLuminance()
      ? background.computeLuminance()
      : foreground.computeLuminance();
  return (lighter + 0.05) / (darker + 0.05);
}
