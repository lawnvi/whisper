import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/adaptive_device_shell.dart';

void main() {
  testWidgets('720 width shows one panel and a back action for detail',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var backs = 0;
    await _pumpShell(
      tester,
      width: 720,
      detail: const ColoredBox(
        key: ValueKey<String>('conversation'),
        color: Colors.blue,
      ),
      onBack: () => backs += 1,
    );

    expect(find.byKey(AdaptiveDeviceShell.workbenchPaneKey), findsNothing);
    expect(find.byKey(AdaptiveDeviceShell.detailPaneKey), findsOneWidget);
    final back = find.byKey(AdaptiveDeviceShell.backButtonKey);
    expect(back, findsOneWidget);
    expect(
      tester.getSize(back).height,
      greaterThanOrEqualTo(WhisperUi.minInteractiveSize),
    );
    expect(
      tester.getSemantics(back),
      matchesSemantics(
        label: 'Back to devices',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    await tester.tap(back);
    expect(backs, 1);
    semantics.dispose();
  });

  testWidgets('720 width shows workbench when no detail is selected',
      (tester) async {
    await _pumpShell(tester, width: 720);

    expect(find.byKey(AdaptiveDeviceShell.workbenchPaneKey), findsOneWidget);
    expect(find.byKey(AdaptiveDeviceShell.detailPaneKey), findsNothing);
    expect(find.byKey(AdaptiveDeviceShell.backButtonKey), findsNothing);
  });

  testWidgets('900 and 1280 widths keep both panes at specified widths',
      (tester) async {
    await _pumpShell(
      tester,
      width: 900,
      detail: const ColoredBox(color: Colors.blue),
    );
    final mediumWidth =
        tester.getSize(find.byKey(AdaptiveDeviceShell.workbenchPaneKey)).width;
    expect(mediumWidth, inInclusiveRange(288, 312));
    expect(find.byKey(AdaptiveDeviceShell.detailPaneKey), findsOneWidget);

    await _pumpShell(
      tester,
      width: 1280,
      detail: const ColoredBox(color: Colors.blue),
    );
    expect(
      tester.getSize(find.byKey(AdaptiveDeviceShell.workbenchPaneKey)).width,
      340,
    );
    expect(find.byKey(AdaptiveDeviceShell.detailPaneKey), findsOneWidget);
  });

  testWidgets('resizing with two-times text scale does not overflow',
      (tester) async {
    for (final width in <double>[720, 900, 1280, 760, 759]) {
      await _pumpShell(
        tester,
        width: width,
        height: 640,
        textScale: 2,
        detail: const ColoredBox(color: Colors.blue),
        backLabel: 'Back to nearby devices and recent conversations',
      );
      expect(tester.takeException(), isNull, reason: 'width $width');
    }
  });
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required double width,
  double height = 800,
  double textScale = 1,
  Widget? detail,
  String backLabel = 'Back to devices',
  VoidCallback? onBack,
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: AdaptiveDeviceShell(
          workbench: const ColoredBox(color: Colors.red),
          detail: detail,
          emptyDetail: const ColoredBox(color: Colors.grey),
          backLabel: backLabel,
          onBack: onBack ?? () {},
        ),
      ),
    ),
  );
  await tester.pump();
}
