import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release DMG contains an Applications drop target', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    final packageStep = RegExp(
      r'- name: Package DMG[\s\S]*?(?=\n      - name: Upload macOS)',
    ).firstMatch(workflow)!.group(0)!;

    expect(packageStep, contains('mkdir -p dmg-root'));
    expect(packageStep, contains('ln -s /Applications dmg-root/Applications'));
    expect(packageStep, contains('-srcfolder dmg-root'));
    expect(
      packageStep,
      isNot(contains(
        '-srcfolder build/macos/Build/Products/Release/whisper.app',
      )),
    );
  });
}
