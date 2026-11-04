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
}
