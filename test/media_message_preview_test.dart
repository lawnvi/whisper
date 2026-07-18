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

  testWidgets('completed audio uses a compact voice message bubble', (
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
      find.byKey(const ValueKey<String>('voice-message-bubble')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('voice-message-glyph')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  test('voice message bubble grows with duration and stays bounded', () {
    expect(
      voiceMessageBubbleWidthFor(const Duration(seconds: 1)),
      closeTo(100, 0.01),
    );
    expect(
      voiceMessageBubbleWidthFor(const Duration(seconds: 30)),
      greaterThan(170),
    );
    expect(
      voiceMessageBubbleWidthFor(const Duration(minutes: 5)),
      closeTo(228, 0.01),
    );
  });

  testWidgets('outgoing voice content stays grouped by the trailing edge', (
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
                status: '3"',
                contentAvailable: true,
              ),
            ),
          ),
        ),
      ),
    );

    final bubble = find.byKey(const ValueKey<String>('voice-message-bubble'));
    final label = find.byKey(const ValueKey<String>('voice-message-label'));
    final glyph = find.byKey(const ValueKey<String>('voice-message-glyph'));
    expect(tester.getSize(bubble).height, 64);
    expect(tester.getTopLeft(label).dx, lessThan(tester.getTopLeft(glyph).dx));
    expect(
      tester.getTopLeft(glyph).dx - tester.getTopRight(label).dx,
      closeTo(10, 0.01),
    );
    expect(tester.takeException(), isNull);
  });

  test('voice message bubble tail follows the message direction', () {
    const rect = Rect.fromLTWH(0, 0, 160, 48);
    const incomingBorder = VoiceMessageBubbleBorder(incoming: true);
    const outgoingBorder = VoiceMessageBubbleBorder(incoming: false);
    final incoming = incomingBorder.getOuterPath(rect);
    final outgoing = outgoingBorder.getOuterPath(rect);
    expect(incoming.contains(const Offset(1, 22)), isTrue);
    expect(outgoing.contains(const Offset(159, 22)), isTrue);
    final incomingPadding = incomingBorder.dimensions.resolve(
      TextDirection.ltr,
    );
    final outgoingPadding = outgoingBorder.dimensions.resolve(
      TextDirection.ltr,
    );
    expect(incomingPadding.left, greaterThan(incomingPadding.right));
    expect(outgoingPadding.right, greaterThan(outgoingPadding.left));
  });

  testWidgets('incoming voice message points from the leading edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: MediaMessagePreview(
                kind: MediaFileKind.audio,
                path: '/tmp/example.mp3',
                name: 'voice-note.mp3',
                status: '2.4 MB',
                contentAvailable: true,
                incoming: true,
              ),
            ),
          ),
        ),
      ),
    );

    final glyph = find.byKey(const ValueKey<String>('voice-message-glyph'));
    final label = find.byKey(const ValueKey<String>('voice-message-label'));
    expect(tester.getTopLeft(glyph).dx, lessThan(tester.getTopLeft(label).dx));
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
      find.byKey(const ValueKey<String>('voice-message-glyph')),
      findsOneWidget,
    );
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
