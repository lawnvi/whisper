@TestOn('windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/windows_shell_open.dart';

void main() {
  test('an empty path is not handed to the shell', () {
    expect(openWithWindowsShell(''), isFalse);
  });
}
