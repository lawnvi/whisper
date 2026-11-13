import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/app_update.dart';

void main() {
  test('release builds embed their stable or preview update channel', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    final macosScript = File('script/build_and_run.sh').readAsStringSync();

    expect(workflow, contains('UPDATE_CHANNEL="stable"'));
    expect(workflow, contains('UPDATE_CHANNEL="preview"'));
    expect(
      RegExp(
        r'--dart-define=WHISPER_UPDATE_CHANNEL',
      ).allMatches(workflow).length,
      greaterThanOrEqualTo(4),
    );
    expect(
      macosScript,
      contains(r'WHISPER_UPDATE_CHANNEL=${WHISPER_UPDATE_CHANNEL}'),
    );
  });

  // Without the hardened runtime any program of the user could load its own
  // library into the released app (DYLD_INSERT_LIBRARIES through `open --env`
  // or the login item's plist) and act with Whisper's Accessibility and
  // Screen Recording grants. Only the packaged build shows it.
  test('macOS releases are signed with the hardened runtime', () {
    final macosScript = File('script/build_and_run.sh').readAsStringSync();
    expect(macosScript, contains('runtime=(--options runtime)'));
    expect(
      RegExp(
        r'sign_app "\$\w+" "\$\w+" release$',
        multiLine: true,
      ).allMatches(macosScript).length,
      2,
    );
    for (final path in <String>[
      'macos/Runner/Release.entitlements',
      'macos/Runner/IntelVirtualHID.entitlements',
    ]) {
      expect(
        File(path).readAsStringSync(),
        isNot(contains('allow-dyld-environment-variables')),
      );
    }
  });

  test('platform installers support in-app update handoff', () {
    final installer = File('windows/installer.nsi').readAsStringSync();
    final androidManifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(installer, contains(r'taskkill /IM "${APP_EXE}" /F'));
    expect(
      installer.indexOf('taskkill /IM'),
      lessThan(installer.indexOf(r'File /r "${BUILD_DIR}\*.*"')),
    );
    // Started by Whisper to update itself, it asks nothing and starts
    // Whisper again. Both ends must mean the same flag.
    expect(installer, contains('"$windowsUpdateInstallerArgument"'));
    expect(installer, contains(r"""Exec '"$INSTDIR\${APP_EXE}"'"""));
    expect(
      androidManifest,
      contains('android.permission.REQUEST_INSTALL_PACKAGES'),
    );
  });
}
