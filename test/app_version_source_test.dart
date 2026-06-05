import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pubspec declares a semantic app version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?$',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(version, isNotNull);
  });

  test('release workflow checks tag version against pubspec', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    expect(workflow, contains('Verify release tag matches pubspec version'));
    expect(workflow, contains('pubspec.yaml'));
    expect(workflow, contains('GITHUB_REF_NAME'));
  });
}
