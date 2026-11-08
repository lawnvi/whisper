// Films the floating paste island through a whole paste, frame by frame, to
// judge its motion: `WHISPER_RENDER_OUT=<dir> flutter test
// test/manual/render_paste_island_motion.dart`, then put the frames together
// with ffmpeg (about 31 frames a second).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/paste_island/paste_island_app.dart';
import 'package:whisper/new_ui/shell/shell_island.dart';
import 'package:whisper/remote_input/remote_clipboard_paste_watch.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/island_center.dart';

import '../support/golden_support.dart';

void main() {
  setUpAll(loadGoldenFonts);

  testWidgets('a paste on the floating island, filmed', (tester) async {
    final out = Platform.environment['WHISPER_RENDER_OUT'];
    tester.view.physicalSize = const Size(460, 230);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = IslandListSource();
    final center = IslandCenter(sources: [source]);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: RepaintBoundary(
          key: const ValueKey('shot'),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFB9D7FF), Color(0xFFF2C9EC)],
              ),
            ),
            child: Stack(
              children: [
                ShellIsland(
                  center: center,
                  windowWidth: 460,
                  controlsLeft: 460,
                  titleRight: 0,
                  buttonsLeft: 920,
                  buttonsBottom: 0,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    var frame = 0;
    Future<void> shot() async {
      if (out == null) return;
      final boundary =
          tester.renderObject(find.byKey(const ValueKey('shot')))
              as RenderRepaintBoundary;
      final image = await tester.runAsync(
        () => boundary.toImage(pixelRatio: 2),
      );
      final bytes = await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.png),
      );
      final name = 'f${frame.toString().padLeft(4, '0')}.png';
      File('$out/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    var tick = 0;
    Future<void> film(int ms) async {
      for (var t = 0; t < ms; t += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        if ((tick++).isEven) {
          await shot();
          frame++;
        }
      }
    }

    IslandActivity paste({
      required int id,
      required String name,
      required int total,
      required RemoteClipboardPasteStage stage,
      double progress = 0,
      int? seconds,
      bool queued = false,
      String folder = '',
    }) => IslandActivity(
      id: 'paste:$id',
      kind: IslandKind.copy,
      status: switch (stage) {
        RemoteClipboardPasteStage.receiving => IslandStatus.live,
        RemoteClipboardPasteStage.placed ||
        RemoteClipboardPasteStage.ready => IslandStatus.waiting,
        RemoteClipboardPasteStage.pasted => IslandStatus.done,
        RemoteClipboardPasteStage.failed => IslandStatus.failed,
        RemoteClipboardPasteStage.canceled => IslandStatus.ended,
      },
      since: DateTime(2026, 1, 1, 0, 0, id),
      urgent: true,
      presenter: PasteIslandPresenter(
        paste: RemoteClipboardPasteState(
          id: id,
          peerId: 'p',
          names: [name],
          totalBytes: total,
          receivedBytes: (total * progress).round(),
          stage: stage,
          secondsLeft: seconds,
          folder: folder,
          queued: queued,
        ),
        device: '小新',
        onCancel: () {},
      ),
    );

    const big = 624000000, small = 180000000;
    // Comes, and its files come four times a second.
    source.put(
      paste(
        id: 1,
        name: '设计稿-终版.zip',
        total: big,
        stage: RemoteClipboardPasteStage.receiving,
        progress: .06,
        seconds: 24,
      ),
    );
    await film(900);
    for (var i = 1; i <= 8; i++) {
      source.put(
        paste(
          id: 1,
          name: '设计稿-终版.zip',
          total: big,
          stage: RemoteClipboardPasteStage.receiving,
          progress: .06 + i * .035,
          seconds: 24 - i,
        ),
      );
      await film(250);
    }
    // Another paste while it comes: it waits its turn.
    source.put(
      paste(
        id: 2,
        name: '会议录音.m4a',
        total: small,
        stage: RemoteClipboardPasteStage.receiving,
        queued: true,
      ),
    );
    await film(800);
    // The first is in: put in its folder; the second starts.
    source.put(
      paste(
        id: 1,
        name: '设计稿-终版.zip',
        total: big,
        stage: RemoteClipboardPasteStage.placed,
        progress: 1,
        folder: '桌面',
      ),
    );
    source.put(
      paste(
        id: 2,
        name: '会议录音.m4a',
        total: small,
        stage: RemoteClipboardPasteStage.receiving,
        progress: .08,
        seconds: 6,
      ),
    );
    await film(1000);
    center.collapse();
    await film(800);
    center.tap();
    await film(900);
    source.remove('paste:1');
    await film(800);
    source.put(
      paste(
        id: 2,
        name: '会议录音.m4a',
        total: small,
        stage: RemoteClipboardPasteStage.pasted,
        progress: 1,
      ),
    );
    await film(1400);
    source.remove('paste:2');
    await film(900);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 12));
  });
}
