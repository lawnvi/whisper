import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_layout_editor.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_presentation.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  testWidgets('screen block exposes state and keyboard-equivalent movement',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var rect = const RemoteInputScreenRect(
      x: 100,
      y: 40,
      width: 1920,
      height: 1080,
    );
    var selected = true;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 260,
              height: 140,
              child: StatefulBuilder(
                builder: (context, setState) => RemoteInputScreenBlock(
                  title: 'Desk display',
                  resolution: '1920 x 1080',
                  roleLabel: 'Remote screen',
                  selectedLabel: 'Selected screen',
                  conflictLabel: 'Screen overlaps another edge',
                  selected: selected,
                  conflict: true,
                  local: false,
                  onActivate: () {},
                  onToggle: () => setState(() => selected = !selected),
                  onMove: (direction, coarse) {
                    setState(() {
                      rect = moveRemoteLayoutByKey(
                        rect,
                        direction: direction,
                        coarse: coarse,
                      );
                    });
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final block = find.byType(RemoteInputScreenBlock);
    expect(
      find.bySemanticsLabel(
        'Desk display, 1920 x 1080, Remote screen, Selected screen, '
        'Screen overlaps another edge',
      ),
      findsOneWidget,
    );
    expect(
        tester.getSemantics(block).hasFlag(SemanticsFlag.isSelected), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(rect.x, 110);
    expect(rect.y, 40);
    expect(rect.width, 1920);
    expect(rect.height, 1080);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(rect.x, 110);
    expect(rect.y, 90);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(selected, isFalse);
    semantics.dispose();
  });

  testWidgets('compact conflict icon does not cover the screen title',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 90,
              height: 58,
              child: RemoteInputScreenBlock(
                title: 'Desk display',
                resolution: '1920 x 1080',
                roleLabel: 'Remote screen',
                selectedLabel: 'Selected screen',
                conflictLabel: 'Conflict',
                selected: true,
                conflict: true,
                local: false,
              ),
            ),
          ),
        ),
      ),
    );

    final titleRect = tester.getRect(find.text('Desk display'));
    final warningRect =
        tester.getRect(find.byIcon(Icons.warning_amber_rounded));
    expect(titleRect.overlaps(warningRect), isFalse);
  });

  testWidgets(
      'layout editor supports save, escape, selected edges and text scale',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    RemoteInputLayoutData? saved;

    Widget host() => MaterialApp(
          theme: AppTheme.lightTheme,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
            ),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  saved = await Navigator.of(context).push(
                    MaterialPageRoute<RemoteInputLayoutData>(
                      builder: (_) => RemoteInputLayoutEditorScreen(
                        initialLayout: _layout(),
                        peerName: 'Desk PC',
                        remoteTopology: RemoteInputTopology.fallback(
                          platform: 'windows',
                          width: 900,
                          height: 600,
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('Open editor'),
              ),
            ),
          ),
        );

    await tester.pumpWidget(host());
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final rightEdge = find.byTooltip('Snap right');
    expect(rightEdge, findsOneWidget);
    expect(tester.getSize(rightEdge).height,
        greaterThanOrEqualTo(WhisperUi.minInteractiveSize));
    expect(
      tester.getSemantics(rightEdge).hasFlag(SemanticsFlag.isSelected),
      isTrue,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    expect(find.byType(RemoteInputLayoutEditorScreen), findsNothing);

    saved = null;
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.byType(RemoteInputLayoutEditorScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

RemoteInputLayoutData _layout() {
  return RemoteInputLayoutData(
    peerId: 'peer-a',
    peerName: 'Desk PC',
    x: 1000,
    y: 0,
    width: 900,
    height: 600,
    enabled: true,
    autoActivate: false,
    autoRole: RemoteInputAutoRole.source.name,
    layoutVersion: 1,
    layoutJson: '',
    edgeThresholdPx: 6,
    releaseHotkey: 'ctrl+alt+esc',
    updatedAt: 1,
  );
}
