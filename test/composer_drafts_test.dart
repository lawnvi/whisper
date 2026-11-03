import 'dart:io';

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

  test('a conversation comes back with its draft', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final restore = source.indexOf('ComposerDrafts.shared.of(device.uid)');
    final listen = source.indexOf('_textController.addListener');
    expect(restore, greaterThan(-1));
    expect(restore, lessThan(listen));
    final dispose = source.indexOf('void dispose()');
    final keep = source.indexOf('ComposerDrafts.shared.keep(', dispose);
    expect(keep, greaterThan(dispose));
    expect(keep, lessThan(source.indexOf('_textController.dispose()')));
  });
}
