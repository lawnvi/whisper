@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/windows_shell_open.dart';

void main() {
  test('a file that is not there is reported as not opened', () {
    final missing = p.join(
      Directory.systemTemp.path,
      'whisper-no-such-file&echo,nothing&.txt',
    );

    expect(openWithWindowsShell(missing), isFalse);
  });

  test('an empty path is not handed to the shell', () {
    expect(openWithWindowsShell(''), isFalse);
  });
}
