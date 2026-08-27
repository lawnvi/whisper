import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/message_link_text.dart';

void main() {
  test('parses secure web links without surrounding punctuation', () {
    final segments = parseMessageLinks(
      '文档：https://example.com/a_(b)。备用 www.example.org/test?x=1。',
    );

    expect(segments.map((segment) => segment.text), <String>[
      '文档：',
      'https://example.com/a_(b)',
      '。备用 ',
      'www.example.org/test?x=1',
      '。',
    ]);
    expect(
      segments.where((segment) => segment.isLink).map((segment) {
        return segment.uri.toString();
      }),
      <String>['https://example.com/a_(b)', 'https://www.example.org/test?x=1'],
    );
  });

  test('does not linkify unsupported schemes or embedded domains', () {
    final segments = parseMessageLinks(
      'ftp://example.com userwww.example.com javascript:alert(1)',
    );

    expect(segments, hasLength(1));
    expect(segments.single.isLink, isFalse);
  });

  test('stops highlighting when adjacent Chinese text begins', () {
    final segments = parseMessageLinks(
      '地址 https://github.com/看看怎么样，再看 https://github.com谢谢',
    );

    expect(segments.map((segment) => segment.text), <String>[
      '地址 ',
      'https://github.com/',
      '看看怎么样，再看 ',
      'https://github.com',
      '谢谢',
    ]);
    expect(
      segments.where((segment) => segment.isLink).map((segment) => segment.uri),
      <Uri>[Uri.parse('https://github.com/'), Uri.parse('https://github.com')],
    );
  });

  testWidgets('opens a tapped link while keeping the text selectable', (
    tester,
  ) async {
    Uri? opened;
    var parentTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            onTap: () => parentTaps++,
            child: MessageLinkText(
              text: 'https://example.com',
              style: const TextStyle(color: Colors.black),
              linkStyle: const TextStyle(color: Colors.blue),
              onOpen: (uri) async => opened = uri,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(SelectableText));
    await tester.pump();

    expect(opened, Uri.parse('https://example.com'));
    expect(parentTaps, 0);
  });

  testWidgets('disables link taps while message selection is active', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageLinkText(
            text: 'https://example.com',
            style: const TextStyle(color: Colors.black),
            linkStyle: const TextStyle(color: Colors.blue),
            linksEnabled: false,
            onOpen: (_) async {},
          ),
        ),
      ),
    );

    final selectable = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    final span = selectable.textSpan!.children!.single as TextSpan;
    expect(span.recognizer, isNull);
  });
}
