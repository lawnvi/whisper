import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release workflow builds signed DMG through the macOS package script',
      () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    expect(
      workflow,
      contains('script/build_and_run.sh package-macos'),
    );
    expect(
      workflow,
      contains('WHISPER_MACOS_CERTIFICATE_P12_BASE64'),
    );
    expect(
      workflow,
      contains('WHISPER_MACOS_REQUIRE_STABLE_SIGNING: "1"'),
    );
  });

  test('release DMG contains an Applications drop target', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    final packageScript = File('script/build_and_run.sh').readAsStringSync();

    expect(workflow, contains('script/build_and_run.sh package-macos'));
    expect(packageScript, contains(r'mkdir -p "$DMG_ROOT"'));
    expect(
      packageScript,
      contains(r'ln -s /Applications "$DMG_ROOT/Applications"'),
    );
    expect(packageScript, contains(r'-srcfolder "$DMG_ROOT"'));
    expect(
      packageScript,
      isNot(contains(
        '-srcfolder build/macos/Build/Products/Release/whisper.app',
      )),
    );
  });

  test('macOS package script can import a stable signing certificate', () {
    final script = File('script/build_and_run.sh').readAsStringSync();

    expect(script, contains('WHISPER_MACOS_CERTIFICATE_P12_BASE64'));
    expect(script, contains('WHISPER_MACOS_CERTIFICATE_PASSWORD'));
    expect(script, contains(r'security import "$tmpdir/cert.p12"'));
    expect(script, contains('security set-key-partition-list'));
    expect(script, contains('WHISPER_MACOS_REQUIRE_STABLE_SIGNING'));
  });
}
