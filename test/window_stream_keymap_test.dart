import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../script/gen_wsn_keymap.dart';

void main() {
  test('wsn_keymap.h matches the generator', () {
    final current = File(wsnKeymapHeaderPath).readAsStringSync();
    expect(
      current,
      buildWsnKeymapHeader(),
      reason: 'run `dart run script/gen_wsn_keymap.dart`',
    );
    expect(current, contains('DO NOT EDIT'));
  });
}
