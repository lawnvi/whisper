import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release workflow builds signed DMG through the macOS package script',
      () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    expect(
      workflow,
      contains('script/build_and_run.sh package-macos-x64'),
    );
    expect(workflow, contains(r'whisper-${PACKAGE_VERSION}-macos.dmg'));
    expect(
      workflow,
      contains('WHISPER_MACOS_CERTIFICATE_P12_BASE64'),
    );
    expect(
      workflow,
      contains('WHISPER_MACOS_REQUIRE_STABLE_SIGNING: "1"'),
    );
  });

  test('release workflow disables experimental Flutter Swift Package Manager',
      () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    final disableSpm =
        workflow.indexOf('flutter config --no-enable-swift-package-manager');
    final installDependencies = workflow.indexOf('name: Install dependencies');

    expect(disableSpm, isNot(-1));
    expect(installDependencies, isNot(-1));
    expect(disableSpm, lessThan(installDependencies));
  });

  test('release DMG contains an Applications drop target', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    final packageScript = File('script/build_and_run.sh').readAsStringSync();

    expect(workflow, contains('script/build_and_run.sh package-macos-x64'));
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

  test('release DMG applies a compact Finder install window layout', () {
    final packageScript = File('script/build_and_run.sh').readAsStringSync();

    expect(packageScript, contains('DMG_WINDOW_BOUNDS="{160, 120, 720, 440}"'));
    expect(packageScript, contains('DMG_ICON_SIZE=112'));
    expect(packageScript, contains('DMG_APP_BUNDLE_NAME="Whisper.app"'));
    expect(packageScript, contains('DMG_APP_ICON_POSITION="{180, 170}"'));
    expect(
      packageScript,
      contains('DMG_APPLICATIONS_ICON_POSITION="{420, 170}"'),
    );
    expect(packageScript, contains('configure_dmg_finder_window()'));
    expect(packageScript,
        contains('set toolbar visible of container window to false'));
    expect(packageScript,
        contains('set statusbar visible of container window to false'));
    expect(packageScript,
        contains(r'set the bounds of container window to $DMG_WINDOW_BOUNDS'));
    expect(packageScript,
        contains(r'set icon size of viewOptions to $DMG_ICON_SIZE'));
    expect(
      packageScript,
      contains(r'set position of item "$DMG_APP_BUNDLE_NAME"'),
    );
    expect(packageScript, contains('set position of item "Applications"'));
  });

  test('DMG Finder window layout is best-effort so headless CI still packages',
      () {
    final packageScript = File('script/build_and_run.sh').readAsStringSync();

    // The cosmetic layout must not abort packaging by default — headless CI
    // runners cannot script the mounted volume (-1728 "Can't get disk").
    expect(
      packageScript,
      contains('WHISPER_MACOS_REQUIRE_DMG_LAYOUT'),
    );
    expect(
      packageScript,
      contains(
        'Warning: skipping DMG Finder window layout (cosmetic); '
        'packaging plain DMG',
      ),
    );

    // The layout failure still runs the compression + verification afterwards.
    final layoutFailure = packageScript.indexOf('WHISPER_MACOS_REQUIRE_DMG_LAYOUT');
    final convert =
        packageScript.indexOf('hdiutil convert "\$rw_dmg_path"');
    expect(layoutFailure, isNot(-1));
    expect(convert, isNot(-1));
    expect(layoutFailure, lessThan(convert));
  });

  test('macOS package script can import a stable signing certificate', () {
    final script = File('script/build_and_run.sh').readAsStringSync();

    expect(script, contains('WHISPER_MACOS_CERTIFICATE_P12_BASE64'));
    expect(script, contains('WHISPER_MACOS_CERTIFICATE_PASSWORD'));
    expect(script, contains(r'security import "$tmpdir/cert.p12"'));
    expect(script, contains('security set-key-partition-list'));
    expect(script, contains('WHISPER_MACOS_REQUIRE_STABLE_SIGNING'));
    expect(
        script, contains(r'security find-identity -p codesigning "$KEYCHAIN"'));
    expect(
      script,
      isNot(contains(r'security find-identity -p codesigning -v "$KEYCHAIN"')),
    );
    expect(script, contains('RESOLVED_SIGN_IDENTITY'));
    expect(script, contains(r'--sign "$RESOLVED_SIGN_IDENTITY"'));
    expect(script, contains(r'--keychain "$KEYCHAIN"'));
    expect(script, contains('TEMP_DIRS=()'));
    expect(script, contains('cleanup_temp_dirs'));
    expect(script, isNot(contains("trap 'rm -rf \"\$tmpdir\"' RETURN")));
  });

  test('macOS package script can cross-build an Intel-only package', () {
    final script = File('script/build_and_run.sh').readAsStringSync();

    expect(script, contains('package-macos-x64'));
    expect(script, contains("-destination 'platform=macOS,arch=x86_64'"));
    expect(script, contains('ARCHS=x86_64'));
    expect(script, contains('ONLY_ACTIVE_ARCH=YES'));
    expect(script, contains('verify_bundle_architecture'));
    expect(script, contains('DMG_PATH="whisper-x86_64.dmg"'));
    expect(script, contains('cleanup_macos_native_asset_staging'));
    expect(script, contains('rm -rf build/native_assets/macos'));
    expect(script, contains('.dart_tool/flutter_build'));
    expect(script, contains('prepare_macos_native_asset_staging x86_64'));
  });

  test('macOS package script can be launched through sh', () async {
    final result = await Process.run(
      'sh',
      ['script/build_and_run.sh', '__invalid__'],
    );

    expect(result.exitCode, 2);
    expect(result.stderr, contains('usage:'));
    expect(result.stderr, isNot(contains('syntax error')));
    expect(result.stderr, isNot(contains('unbound variable')));
  }, skip: Platform.isWindows);
}
