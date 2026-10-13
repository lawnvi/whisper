@TestOn('windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/windows_system_theme.dart';

void main() {
  test('Windows says which taskbar it has', () {
    final light = windowsTaskbarIsLight();

    // Every Windows this app runs on has the setting; which way it is set
    // is up to the machine.
    expect(light, isNotNull);
    // ignore: avoid_print
    print('taskbar is light: $light');
  });
}
