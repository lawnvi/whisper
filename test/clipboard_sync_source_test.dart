import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clipboard watcher reads text through the text-only sync guard', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(source,
        contains("import 'package:whisper/helper/clipboard_sync.dart';"));
    expect(source, contains('final text = await readClipboardTextForSync();'));
    expect(source, contains('if (text == null ||'));
  });

  test('manual clipboard message send uses the text-only sync guard', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source,
        contains("import 'package:whisper/helper/clipboard_sync.dart';"));
    expect(
        source, contains('var str = await readClipboardTextForSync() ?? "";'));
  });
}
