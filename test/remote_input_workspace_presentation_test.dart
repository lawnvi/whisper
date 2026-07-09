import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_presentation.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  test('pane layout follows compact, medium, and expanded boundaries', () {
    expect(paneLayoutForWidth(0), RemoteInputWorkspacePaneLayout.compact);
    expect(paneLayoutForWidth(759.9), RemoteInputWorkspacePaneLayout.compact);
    expect(paneLayoutForWidth(760), RemoteInputWorkspacePaneLayout.medium);
    expect(paneLayoutForWidth(1099.9), RemoteInputWorkspacePaneLayout.medium);
    expect(paneLayoutForWidth(1100), RemoteInputWorkspacePaneLayout.expanded);
    expect(paneLayoutForWidth(2400), RemoteInputWorkspacePaneLayout.expanded);
  });

  test('keyboard movement uses 10 or 50 units without resizing', () {
    const original = RemoteInputScreenRect(
      x: 120,
      y: -30,
      width: 1920,
      height: 1080,
    );

    _expectRect(
      moveRemoteLayoutByKey(
        original,
        direction: RemoteInputEdge.left,
        coarse: false,
      ),
      const RemoteInputScreenRect(
        x: 110,
        y: -30,
        width: 1920,
        height: 1080,
      ),
    );
    _expectRect(
      moveRemoteLayoutByKey(
        original,
        direction: RemoteInputEdge.right,
        coarse: true,
      ),
      const RemoteInputScreenRect(
        x: 170,
        y: -30,
        width: 1920,
        height: 1080,
      ),
    );
    _expectRect(
      moveRemoteLayoutByKey(
        original,
        direction: RemoteInputEdge.top,
        coarse: false,
      ),
      const RemoteInputScreenRect(
        x: 120,
        y: -40,
        width: 1920,
        height: 1080,
      ),
    );
    _expectRect(
      moveRemoteLayoutByKey(
        original,
        direction: RemoteInputEdge.bottom,
        coarse: true,
      ),
      const RemoteInputScreenRect(
        x: 120,
        y: 20,
        width: 1920,
        height: 1080,
      ),
    );
  });

  testWidgets('adaptive workspace presents the right panes without overflow',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    Future<void> pumpAt(double width, {double textScale = 1}) async {
      tester.view.physicalSize = Size(width, 600);
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
            body: RemoteInputAdaptiveWorkspace(
              devicesPanelLabel: 'Devices',
              detailsPanelLabel: 'Details',
              closePanelLabel: 'Close',
              devicePanel: const ColoredBox(
                key: ValueKey<String>('fixture-devices'),
                color: Colors.red,
                child: Text('Devices content'),
              ),
              canvasPanel: const ColoredBox(
                key: ValueKey<String>('fixture-canvas'),
                color: Colors.green,
                child: Text('Canvas content'),
              ),
              detailsPanel: const ColoredBox(
                key: ValueKey<String>('fixture-details'),
                color: Colors.blue,
                child: Text('Details content'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await pumpAt(700);
    expect(
      find.byKey(RemoteInputAdaptiveWorkspace.canvasPanelKey),
      findsOneWidget,
    );
    expect(find.text('Devices content'), findsNothing);
    expect(find.text('Details content'), findsNothing);
    final devicesButton =
        find.byKey(RemoteInputAdaptiveWorkspace.openDevicesButtonKey);
    final detailsButton =
        find.byKey(RemoteInputAdaptiveWorkspace.openDetailsButtonKey);
    expect(devicesButton, findsOneWidget);
    expect(detailsButton, findsOneWidget);
    expect(tester.getSize(devicesButton).height,
        greaterThanOrEqualTo(WhisperUi.minInteractiveSize));
    expect(tester.getSize(detailsButton).height,
        greaterThanOrEqualTo(WhisperUi.minInteractiveSize));
    await tester.tap(devicesButton);
    await tester.pumpAndSettle();
    expect(find.text('Devices content'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Devices content'), findsNothing);

    await pumpAt(900);
    expect(find.text('Devices content'), findsOneWidget);
    expect(find.text('Canvas content'), findsOneWidget);
    expect(find.text('Details content'), findsNothing);
    expect(
      find.byKey(RemoteInputAdaptiveWorkspace.openDetailsButtonKey),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(RemoteInputAdaptiveWorkspace.openDetailsButtonKey),
    );
    await tester.pumpAndSettle();
    expect(find.text('Details content'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await pumpAt(1440);
    expect(find.text('Devices content'), findsOneWidget);
    expect(find.text('Canvas content'), findsOneWidget);
    expect(find.text('Details content'), findsOneWidget);
    expect(
      find.byKey(RemoteInputAdaptiveWorkspace.openDevicesButtonKey),
      findsNothing,
    );
    expect(
      find.byKey(RemoteInputAdaptiveWorkspace.openDetailsButtonKey),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    await pumpAt(320, textScale: 2);
    expect(
      find.byKey(RemoteInputAdaptiveWorkspace.openDevicesButtonKey),
      findsOneWidget,
    );
    expect(
      find.byKey(RemoteInputAdaptiveWorkspace.openDetailsButtonKey),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact bottom sheet follows live panel updates',
      (tester) async {
    String deviceState = 'Before update';
    late StateSetter setHostState;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: SizedBox(
            width: 700,
            child: StatefulBuilder(
              builder: (context, setState) {
                setHostState = setState;
                return RemoteInputAdaptiveWorkspace(
                  devicesPanelLabel: 'Devices',
                  detailsPanelLabel: 'Details',
                  closePanelLabel: 'Close',
                  devicePanel: Text(deviceState),
                  canvasPanel: const SizedBox.expand(),
                  detailsPanel: const Text('Details'),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(RemoteInputAdaptiveWorkspace.openDevicesButtonKey),
    );
    await tester.pumpAndSettle();
    expect(find.text('Before update'), findsOneWidget);

    setHostState(() => deviceState = 'After update');
    await tester.pumpAndSettle();
    expect(find.text('After update'), findsOneWidget);
    expect(find.text('Before update'), findsNothing);
  });
}

void _expectRect(RemoteInputScreenRect actual, RemoteInputScreenRect expected) {
  expect(actual.x, expected.x);
  expect(actual.y, expected.y);
  expect(actual.width, expected.width);
  expect(actual.height, expected.height);
}
