import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/remote_input/remote_input_workspace_presentation.dart';
import 'package:whisper/widget/app_empty_state.dart';

void main() {
  testWidgets('device target and inspect action have independent semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var toggles = 0;
    var inspections = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: RemoteInputDevicePanel(
              title: 'Control targets',
              emptyTitle: 'No targets',
              emptyBody: 'Connect a desktop first.',
              inspectTooltip: 'Inspect device',
              items: <RemoteInputDeviceTargetItem>[
                RemoteInputDeviceTargetItem(
                  id: 'peer-a',
                  name: 'A desktop with a long localized display name',
                  status: 'Connected and ready',
                  selected: true,
                  focused: false,
                  onToggle: () => toggles += 1,
                  onInspect: () => inspections += 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final toggle = find.bySemanticsLabel(
      'A desktop with a long localized display name, Connected and ready',
    );
    final inspect = find.byTooltip('Inspect device');
    expect(toggle, findsOneWidget);
    expect(inspect, findsOneWidget);
    expect(
        tester.getSemantics(toggle).hasFlag(SemanticsFlag.isToggled), isTrue);
    expect(tester.getSize(toggle).height,
        greaterThanOrEqualTo(WhisperUi.minInteractiveSize));
    expect(tester.getSize(inspect), const Size.square(44));

    await tester.tap(toggle);
    await tester.tap(inspect);
    expect(toggles, 1);
    expect(inspections, 1);
    semantics.dispose();
  });

  testWidgets('real workspace panels adapt across required viewports',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    Future<void> pumpAt(
      Size size, {
      double textScale = 1,
    }) async {
      tester.view.physicalSize = size;
      await tester.pumpWidget(_workspaceFixture(textScale: textScale));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size @ $textScale');
    }

    await pumpAt(const Size(720, 600), textScale: 2);
    await tester.tap(
      find.byKey(RemoteInputAdaptiveWorkspace.openDetailsButtonKey),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RemoteInputWorkspaceDetailsPanel), findsOneWidget);
    await tester.scrollUntilVisible(
      _addressFinder,
      80,
      scrollable: find.descendant(
        of: find.byType(RemoteInputWorkspaceDetailsPanel),
        matching: find.byType(Scrollable),
      ),
    );
    expect(_addressFinder, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await pumpAt(const Size(900, 700));
    await tester.tap(
      find.byKey(RemoteInputAdaptiveWorkspace.openDetailsButtonKey),
    );
    await tester.pumpAndSettle();
    expect(_addressFinder, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await pumpAt(const Size(1440, 900));
    expect(_addressFinder, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty canvas is explicit and warning copy meets text contrast',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 500,
            child: RemoteInputWorkspaceCanvasPanel(
              title: 'Screen arrangement',
              hasConflict: true,
              conflictLabel: 'Edge overlap',
              empty: true,
              emptyTitle: 'No control targets',
              emptyBody: 'Select a device to arrange its screens.',
              child: const ColoredBox(
                key: ValueKey<String>('unexpected-canvas'),
                color: Colors.red,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(AppEmptyState), findsOneWidget);
    expect(
        find.byKey(const ValueKey<String>('unexpected-canvas')), findsNothing);
    final warning = tester.widget<Text>(find.text('Edge overlap'));
    expect(
      _contrast(
        warning.style!.color!,
        AppTheme.lightTheme.extension<WhisperPalette>()!.surfaceCanvas,
      ),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets('status bar grows for wrapped two hundred percent text',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
          ),
          child: child!,
        ),
        home: const Scaffold(
          bottomNavigationBar: SizedBox(
            width: 320,
            child: RemoteInputWorkspaceStatusBar(
              status:
                  'The keyboard and mouse workspace is waiting for a remote desktop to accept the request',
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(RemoteInputWorkspaceStatusBar)).height,
      greaterThan(46),
    );
    expect(tester.takeException(), isNull);
  });
}

const _scopedIpv6 = '[fe80::f2de:f1ff:fe3f:307e%en0]:53317';

final _addressFinder = find.byWidgetPredicate(
  (widget) => widget is SelectableText && widget.data == _scopedIpv6,
);

Widget _workspaceFixture({required double textScale}) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: Scaffold(
      body: Column(
        children: const <Widget>[
          Expanded(
            child: RemoteInputAdaptiveWorkspace(
              devicesPanelLabel: 'Devices',
              detailsPanelLabel: 'Details',
              openDevicesPanelLabel: 'Open devices panel',
              openDetailsPanelLabel: 'Open details panel',
              closePanelLabel: 'Close panel',
              devicePanel: RemoteInputDevicePanel(
                title: 'Control targets',
                emptyTitle: 'No targets',
                emptyBody: 'Connect a desktop first.',
                inspectTooltip: 'Inspect device',
                items: <RemoteInputDeviceTargetItem>[
                  RemoteInputDeviceTargetItem(
                    id: 'peer-a',
                    name:
                        'A desktop with a very long localized device name for layout testing',
                    status:
                        'Connected and ready for keyboard and mouse control',
                    selected: true,
                    focused: true,
                    onToggle: _noop,
                    onInspect: _noop,
                  ),
                ],
              ),
              canvasPanel: RemoteInputWorkspaceCanvasPanel(
                title: 'Screen arrangement',
                hasConflict: false,
                conflictLabel: 'Edge overlap',
                empty: false,
                emptyTitle: 'No control targets',
                emptyBody: 'Select a target.',
                child: Stack(
                  children: <Widget>[
                    RemoteInputPositionedScreenBlock(
                      visualRect: Rect.fromLTWH(80, 60, 260, 150),
                      title: 'Desk display with a long name',
                      resolution: '3840 x 2160',
                      roleLabel: 'Remote screen',
                      selectedLabel: 'Selected screen',
                      conflictLabel: 'Conflict',
                      selected: true,
                      conflict: false,
                      local: false,
                      onActivate: _noop,
                    ),
                  ],
                ),
              ),
              detailsPanel: RemoteInputWorkspaceDetailsPanel(
                title: 'Device details',
                emptyTitle: 'No target selected',
                emptyBody: 'Choose a target to inspect it.',
                deviceName:
                    'A desktop with a very long localized device name for layout testing',
                address: _scopedIpv6,
                details: <RemoteInputWorkspaceDetail>[
                  RemoteInputWorkspaceDetail(
                    label: 'Screen arrangement',
                    value:
                        'Right of the primary display with a long descriptive value',
                  ),
                  RemoteInputWorkspaceDetail(
                    label: 'Connection state',
                    value: 'Connected and waiting for approval',
                  ),
                ],
                actionLabel: 'Remove from workspace',
                actionIcon: Icons.visibility_off_rounded,
                onAction: _noop,
              ),
            ),
          ),
          RemoteInputWorkspaceStatusBar(
            status:
                'The keyboard and mouse workspace is waiting for a remote desktop to accept the request',
          ),
        ],
      ),
    ),
  );
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
