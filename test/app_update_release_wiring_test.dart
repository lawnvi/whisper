import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
    expect(
      androidManifest,
      contains('android.permission.REQUEST_INSTALL_PACKAGES'),
    );
  });
}
