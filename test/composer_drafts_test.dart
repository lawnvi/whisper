
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/page/conversation_drafts.dart';

void main() {
  test('what was written waits for that device, and only that device', () {
    final drafts = ComposerDrafts();
    drafts.keep('imac', const ComposerDraft(text: '还没写完'));
    expect(drafts.of('imac')?.text, '还没写完');
    expect(drafts.of('xiaomi'), isNull);
  });

  test('an emptied box leaves nothing behind', () {
    final drafts = ComposerDrafts();
    drafts.keep('imac', const ComposerDraft(text: '发出去了'));
    drafts.keep('imac', const ComposerDraft());
    expect(drafts.of('imac'), isNull);
  });

  test('a removed device takes its draft with it', () {
    final drafts = ComposerDrafts();
    drafts.keep('imac', const ComposerDraft(text: 'x'));
    drafts.forget('imac');
    expect(drafts.of('imac'), isNull);
  });

}
