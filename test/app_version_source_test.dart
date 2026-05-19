import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pubspec declares the next app version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(pubspec, contains(RegExp(r'^version: 0\.0\.36$', multiLine: true)));
  });
}
