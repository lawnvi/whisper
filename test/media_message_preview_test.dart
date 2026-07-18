import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/context_menu_region.dart';
import 'package:whisper/widget/media_message_preview.dart';

void main() {
  test('classifies common media extensions', () {
    expect(mediaFileKindFor(name: 'photo.webp', path: ''), MediaFileKind.image);
    expect(mediaFileKindFor(name: 'photo.heic', path: ''), MediaFileKind.other);
    expect(mediaFileKindFor(name: 'clip.mp4', path: ''), MediaFileKind.video);
    expect(mediaFileKindFor(name: 'voice.m4a', path: ''), MediaFileKind.audio);
    expect(
      mediaFileKindFor(name: 'archive.zip', path: ''),
      MediaFileKind.other,
    );
    expect(
      mediaFileKindFor(name: 'untitled', path: '/tmp/recording.ogg'),
      MediaFileKind.audio,
    );
  });

  for (final kind in MediaFileKind.values.where(
    (kind) => kind != MediaFileKind.other,
  )) {
    testWidgets('${kind.name} transfer card stays within a narrow message', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 220,
                child: MediaMessagePreview(
                  kind: kind,
                  path: '',
                  name: 'A very long media filename that must not overflow.mp4',
                  status: '12.8 MB  68%',
                  contentAvailable: false,
                  progress: 0.68,
                  onCancel: () {},
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('12.8 MB  68%'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    });
  }

  testWidgets('completed audio uses a compact music attachment card', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: MediaMessagePreview(
              kind: MediaFileKind.audio,
              path: '/tmp/example.mp3',
              name: 'voice-note.mp3',
              status: '2.4 MB',
              contentAvailable: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('voice-note.mp3'), findsOneWidget);
    expect(find.text('0:00 / 0:00'), findsNothing);
    expect(find.text('2.4 MB'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('audio-message-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('audio-message-playback-icon')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('audio metadata combines file size and duration', () {
    expect(
      audioMessageMetaFor(
        status: '2.4 MB',
        duration: const Duration(seconds: 12),
      ),
      '2.4 MB · 0:12',
    );
    expect(
      audioMessageMetaFor(
        status: '',
        duration: const Duration(minutes: 1, seconds: 2),
      ),
      '1:02',
    );
  });

  testWidgets('audio card keeps playback action left of its details', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: 240,
              child: MediaMessagePreview(
                kind: MediaFileKind.audio,
                path: '/tmp/example.mp3',
                name: 'voice-note.mp3',
                status: '2.4 MB',
                contentAvailable: true,
              ),
            ),
          ),
        ),
      ),
    );

    final card = find.byKey(const ValueKey<String>('audio-message-card'));
    final action = find.byKey(const ValueKey<String>('audio-message-action'));
    final name = find.byKey(const ValueKey<String>('audio-message-name'));
    final meta = find.byKey(const ValueKey<String>('audio-message-meta'));
    expect(tester.getSize(card).height, 72);
    expect(tester.getTopLeft(action).dx, lessThan(tester.getTopLeft(name).dx));
    expect(tester.getTopLeft(name).dy, lessThan(tester.getTopLeft(meta).dy));
    expect(tester.takeException(), isNull);
  });

  test('portrait visual card follows its content without side gutters', () {
    final size = mediaPreviewSizeFor(maxWidth: 300, sourceAspectRatio: 9 / 20);
    expect(size.width, closeTo(180, 0.01));
    expect(size.height, closeTo(400, 0.01));
  });

  test('extreme visual ratios stay inside a readable bounded card', () {
    final veryTall = mediaPreviewSizeFor(
      maxWidth: 300,
      sourceAspectRatio: 1 / 30,
    );
    final veryWide = mediaPreviewSizeFor(maxWidth: 300, sourceAspectRatio: 30);
    expect(veryTall.width, closeTo(180, 0.01));
    expect(veryTall.height, closeTo(400, 0.01));
    expect(veryWide.width, closeTo(300, 0.01));
    expect(veryWide.height, closeTo(135, 0.01));
  });

  testWidgets('unavailable completed audio is a terminal media card', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: MediaMessagePreview(
              kind: MediaFileKind.audio,
              path: 'content://provider/audio/1',
              name: 'voice-note.m4a',
              status: '2.4 MB',
              contentAvailable: false,
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('audio-message-action')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('2.4 MB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile context menu uses a styled action sheet', (tester) async {
    var selected = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: ContextMenuRegion(
            items: [
              ContextMenuActionItem(
                label: '删除',
                icon: Icons.delete_outline_rounded,
                destructive: true,
                onSelected: () => selected = true,
              ),
            ],
            child: Container(
              key: const ValueKey('menu-target'),
              width: 120,
              height: 80,
              color: Colors.transparent,
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.byKey(const ValueKey('menu-target')));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
  });
}
