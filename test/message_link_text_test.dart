import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/message_link_text.dart';

void main() {
  test('does not linkify unsupported schemes or embedded domains', () {
    final segments = parseMessageLinks(
      'ftp://example.com userwww.example.com javascript:alert(1)',
    );

    expect(segments, hasLength(1));
    expect(segments.single.isLink, isFalse);
  });

  // Trimming recounted the whole link for each trailing `)`: a peer's text of
  // a million of them froze the main isolate (every connection) for minutes,
  // again each time the conversation opened.
  test('trailing brackets are trimmed in linear time', () {
    final links = parseMessageLinks(
      'see https://a.example/x_(y)). and http://b.example/${')' * 300000}',
    ).where((segment) => segment.isLink).map((segment) => segment.text);
    expect(links, ['https://a.example/x_(y)', 'http://b.example/']);
    final watch = Stopwatch()..start();
    parseMessageLinks('http://a${')' * 1000000}');
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });
}
