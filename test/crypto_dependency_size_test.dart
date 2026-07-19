import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release dependencies keep only the production native AEAD backend', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    expect(pubspec, isNot(contains('cryptography_flutter:')));
    expect(pubspec, contains('sodium:'));
    expect(main, contains('SodiumInit.init()'));
  });
}
