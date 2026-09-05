import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/glass_bottom_sheet.dart';
import 'package:whisper/widget/glass_dialog.dart';
import 'package:whisper/widget/glass_settings_slider.dart';

void main() {
  testWidgets('glass dialog uses blur with a fade and scale entrance', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showWhisperDialog<void>(
                context,
                builder: (dialogContext) => WhisperGlassDialog(
                  title: const Text('Glass'),
                  content: const Text('Content'),
                  actions: <Widget>[
                    WhisperDialogButton(
                      label: 'Close',
                      prominent: true,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                  ],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.byType(FadeTransition), findsWidgets);
    expect(find.byType(ScaleTransition), findsWidgets);

    await tester.pumpAndSettle();
    expect(find.byType(WhisperGlassDialog), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.tap(find.widgetWithText(WhisperDialogButton, 'Close'));
    await tester.pumpAndSettle();
    expect(find.byType(WhisperGlassDialog), findsNothing);
  });

  testWidgets('dialog actions keep the Apple equal-width split layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showWhisperDialog<void>(
                context,
                builder: (dialogContext) => WhisperGlassDialog(
                  title: const Text('Delete item?'),
                  content: const Text('This cannot be undone.'),
                  actions: <Widget>[
                    WhisperDialogButton(
                      key: const ValueKey<String>('cancel-action'),
                      label: 'Cancel',
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                    WhisperDialogButton(
                      key: const ValueKey<String>('confirm-action'),
                      label: 'Delete',
                      destructive: true,
                      prominent: true,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                  ],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final cancelRect = tester.getRect(
      find.byKey(const ValueKey<String>('cancel-action')),
    );
    final confirmRect = tester.getRect(
      find.byKey(const ValueKey<String>('confirm-action')),
    );
    final contentRect = tester.getRect(find.text('This cannot be undone.'));
    expect(cancelRect.width, closeTo(confirmRect.width, 0.01));
    expect(cancelRect.top, confirmRect.top);
    expect(cancelRect.top - contentRect.bottom, greaterThanOrEqualTo(18));
    expect(find.byType(WhisperDialogActionBar), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);

    final button = tester.widget<TextButton>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('confirm-action')),
        matching: find.byType(TextButton),
      ),
    );
    expect(
      button.style!.backgroundColor!.resolve(<WidgetState>{}),
      Colors.transparent,
    );
    for (final state in <WidgetState>{
      WidgetState.hovered,
      WidgetState.focused,
      WidgetState.pressed,
    }) {
      expect(
        button.style!.overlayColor!.resolve(<WidgetState>{state}),
        Colors.transparent,
      );
      expect(
        button.style!.backgroundColor!.resolve(<WidgetState>{state})!.a,
        greaterThan(0),
      );
    }
    final shape = button.style!.shape!.resolve(<WidgetState>{});
    expect(shape, isA<RoundedRectangleBorder>());
    expect((shape! as RoundedRectangleBorder).borderRadius, BorderRadius.zero);
    final visualButtonRect = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('confirm-action')),
        matching: find.byType(TextButton),
      ),
    );
    expect(visualButtonRect.width, closeTo(confirmRect.width, 0.01));
    expect(visualButtonRect.height, closeTo(52, 0.01));
  });

  testWidgets('Apple action sheet keeps grouped rows and separate cancel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.macOS),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showWhisperGlassBottomSheet<void>(
                context,
                builder: (sheetContext) => WhisperGlassActionSheet(
                  title: const Text('Choose Theme'),
                  actions: <Widget>[
                    WhisperGlassActionSheetAction(
                      label: 'Follow System',
                      onPressed: () {},
                    ),
                    WhisperGlassActionSheetAction(
                      key: const ValueKey<String>('light-action'),
                      label: 'Light',
                      onPressed: () {},
                    ),
                    WhisperGlassActionSheetAction(
                      label: 'Dark',
                      onPressed: () {},
                    ),
                  ],
                  cancelButton: WhisperGlassActionSheetAction(
                    label: 'Cancel',
                    destructive: true,
                    onPressed: () => Navigator.of(sheetContext).pop(),
                  ),
                ),
              ),
              child: const Text('Theme'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Theme'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.byType(SlideTransition), findsWidgets);
    expect(find.byType(FadeTransition), findsWidgets);

    await tester.pumpAndSettle();
    const mainKey = ValueKey<String>('whisper-glass-action-sheet-main');
    const cancelKey = ValueKey<String>('whisper-glass-action-sheet-cancel');
    expect(find.byKey(mainKey), findsOneWidget);
    expect(find.byKey(cancelKey), findsOneWidget);
    expect(find.byType(WhisperGlassSurface), findsNWidgets(2));
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    final mainRect = tester.getRect(find.byKey(mainKey));
    final cancelRect = tester.getRect(find.byKey(cancelKey));
    expect(mainRect.width, closeTo(840, 0.01));
    expect(cancelRect.width, closeTo(mainRect.width, 0.01));
    expect(cancelRect.left, closeTo(mainRect.left, 0.01));
    expect(cancelRect.top - mainRect.bottom, closeTo(8, 0.01));
    expect(cancelRect.bottom, closeTo(792, 0.01));
    final cancelActionRect = tester.getRect(
      find.widgetWithText(WhisperGlassActionSheetAction, 'Cancel'),
    );
    expect(cancelActionRect.width, closeTo(cancelRect.width, 0.01));
    expect(
      tester.getCenter(find.text('Cancel')).dx,
      closeTo(cancelRect.center.dx, 0.01),
    );

    final lightButton = tester.widget<TextButton>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('light-action')),
        matching: find.byType(TextButton),
      ),
    );
    expect(
      lightButton.style!.backgroundColor!.resolve(<WidgetState>{
        WidgetState.hovered,
      })!.a,
      greaterThan(0),
    );
    final shape = lightButton.style!.shape!.resolve(<WidgetState>{});
    expect(shape, isA<RoundedRectangleBorder>());
    expect((shape! as RoundedRectangleBorder).borderRadius, BorderRadius.zero);
    final lightRect = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('light-action')),
        matching: find.byType(TextButton),
      ),
    );
    expect(lightRect.width, closeTo(mainRect.width, 0.01));
    expect(lightRect.height, closeTo(57, 0.01));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(mainKey), findsNothing);
  });

  testWidgets('glass bottom sheet slides up and only rounds its top edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.macOS),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showWhisperGlassBottomSheet<void>(
                context,
                builder: (sheetContext) => WhisperGlassBottomSheet(
                  title: const Text('Choose an option'),
                  content: WhisperGlassSelectionMenu(
                    children: <Widget>[
                      WhisperGlassSelectionTile(
                        label: 'Selected',
                        selected: true,
                        onPressed: () {},
                      ),
                      WhisperGlassSelectionTile(
                        label: 'Other',
                        selected: false,
                        onPressed: () {},
                      ),
                    ],
                  ),
                  actions: <Widget>[
                    WhisperDialogButton(
                      label: 'Done',
                      prominent: true,
                      onPressed: () => Navigator.of(sheetContext).pop(),
                    ),
                  ],
                ),
              ),
              child: const Text('Open sheet'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open sheet'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.byType(SlideTransition), findsWidgets);
    expect(find.byType(FadeTransition), findsWidgets);

    await tester.pumpAndSettle();
    expect(find.byType(WhisperGlassBottomSheet), findsOneWidget);
    expect(find.byType(WhisperGlassSelectionMenu), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    final selectionButton = tester.widget<TextButton>(
      find
          .descendant(
            of: find.widgetWithText(WhisperGlassSelectionTile, 'Other'),
            matching: find.byType(TextButton),
          )
          .first,
    );
    expect(
      selectionButton.style!.overlayColor!.resolve(<WidgetState>{
        WidgetState.hovered,
      }),
      Colors.transparent,
    );
    final surfaceFinder = find.descendant(
      of: find.byType(WhisperGlassBottomSheet),
      matching: find.byType(WhisperGlassSurface),
    );
    final surface = tester.widget<WhisperGlassSurface>(surfaceFinder);
    expect(
      surface.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(28)),
    );
    expect(tester.getSize(surfaceFinder).width, 720);
    expect(tester.getTopLeft(surfaceFinder).dx, 240);
    expect(tester.getBottomRight(surfaceFinder).dy, 800);
    expect(
      tester.getSize(find.byType(WhisperDialogActionBar)).width,
      closeTo(720, 0.01),
    );

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(WhisperGlassBottomSheet), findsNothing);
  });

  testWidgets('mobile glass bottom sheet stays edge to edge', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.iOS),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showWhisperGlassBottomSheet<void>(
                context,
                builder: (sheetContext) => WhisperGlassBottomSheet(
                  title: const Text('Mobile sheet'),
                  content: const Text('Content'),
                  actions: <Widget>[
                    WhisperDialogButton(
                      label: 'Done',
                      onPressed: () => Navigator.of(sheetContext).pop(),
                    ),
                  ],
                ),
              ),
              child: const Text('Open mobile sheet'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open mobile sheet'));
    await tester.pumpAndSettle();

    final surfaceFinder = find.descendant(
      of: find.byType(WhisperGlassBottomSheet),
      matching: find.byType(WhisperGlassSurface),
    );
    expect(tester.getSize(surfaceFinder).width, 390);
    expect(tester.getTopLeft(surfaceFinder).dx, 0);
  });

  testWidgets('settings slider updates the displayed value', (tester) async {
    var value = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => WhisperSettingsSlider(
              value: value,
              min: 0.5,
              max: 3,
              divisions: 25,
              valueLabel: '${value.toStringAsFixed(1)}×',
              minLabel: '0.5×',
              maxLabel: '3.0×',
              onChanged: (next) => setState(() => value = next),
              onChangeEnd: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('1.0×'), findsWidgets);

    tester.widget<Slider>(find.byType(Slider)).onChanged!(2);
    await tester.pump();

    expect(find.text('2.0×'), findsOneWidget);
  });
}
