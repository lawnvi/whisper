import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/glass_bottom_sheet.dart';
import 'package:whisper/widget/glass_dialog.dart';

const _backdropKey = ValueKey<String>('whisper-modal-backdrop');

void main() {
  for (final brightness in Brightness.values) {
    for (final kind in ['dialog', 'glass sheet', 'material sheet']) {
      testWidgets('$kind has a full-window frosted barrier in $brightness', (
        tester,
      ) async {
        var backgroundTaps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => backgroundTaps++,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
        final context = tester.element(find.byType(Scaffold));
        final result = _showModal(context, kind);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        final entering = tester.widget<BackdropFilter>(
          find.byKey(_backdropKey),
        );
        expect(
          entering.filter,
          isNot(ImageFilter.blur(sigmaX: 2, sigmaY: 2)),
        );
        await tester.pumpAndSettle();

        final backdrop = find.byKey(_backdropKey);
        expect(
          tester.getRect(backdrop),
          tester.getRect(find.byType(Navigator)),
        );
        expect(
          tester.widget<BackdropFilter>(backdrop).filter,
          ImageFilter.blur(sigmaX: 2, sigmaY: 2),
        );
        expect(
          find.ancestor(of: find.text('Modal content'), matching: backdrop),
          findsNothing,
        );

        await tester.tapAt(const Offset(8, 8));
        await tester.pumpAndSettle();
        expect(await result, isNull);
        expect(backgroundTaps, 0);
        expect(backdrop, findsNothing);
      });
    }
  }

  testWidgets('a required dialog keeps its frosted barrier on outside taps', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    final context = tester.element(find.byType(Scaffold));
    final result = showWhisperDialog<bool>(
      context,
      barrierDismissible: false,
      builder: (context) => const WhisperGlassDialog(content: Text('Required')),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byKey(_backdropKey), findsOneWidget);
    expect(find.text('Required'), findsOneWidget);
    Navigator.of(context).pop(true);
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(find.byKey(_backdropKey), findsNothing);
  });

  testWidgets('high contrast and reduced motion retain an accessible barrier', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(highContrast: true, disableAnimations: true),
          child: child!,
        ),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    final context = tester.element(find.byType(Scaffold));
    final result = _showModal(context, 'dialog');
    await tester.pumpAndSettle();
    expect(find.text('Modal content'), findsOneWidget);
    expect(find.byKey(_backdropKey), findsNothing);
    expect(
      ModalRoute.of(
        tester.element(find.text('Modal content')),
      )!.transitionDuration,
      Duration.zero,
    );
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('material sheets still support dragging down to dismiss', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    final result = _showModal(
      tester.element(find.byType(Scaffold)),
      'material sheet',
    );
    await tester.pumpAndSettle();
    await tester.drag(find.text('Modal content'), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(find.byKey(_backdropKey), findsNothing);
  });
}

Future<String?> _showModal(BuildContext context, String kind) {
  switch (kind) {
    case 'glass sheet':
      return showWhisperGlassBottomSheet<String>(
        context,
        builder: (_) => const WhisperGlassBottomSheet(
          title: Text('Sheet'),
          content: Text('Modal content'),
        ),
      );
    case 'material sheet':
      return showWhisperModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (_) => const SizedBox(
          height: 200,
          child: Center(child: Text('Modal content')),
        ),
      );
    default:
      return showWhisperDialog<String>(
        context,
        builder: (_) =>
            const WhisperGlassDialog(content: Text('Modal content')),
      );
  }
}
