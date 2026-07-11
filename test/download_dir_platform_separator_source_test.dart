import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('downloadDir joins the default whisper folder with the platform '
      'separator', () {
    final source = File('lib/helper/file.dart').readAsStringSync();
    expect(source, contains("p.join(dir.path, 'whisper')"));
    expect(
      source,
      isNot(contains('{dir.path}/whisper')),
      reason: 'Windows 下 getDownloadsDirectory 返回反斜杠路径,'
          '硬拼 "/whisper" 会产生正反斜杠混用的目录',
    );
  });
}
