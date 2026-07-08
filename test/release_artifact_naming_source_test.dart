import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release workflow publishes normalized artifact file names', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    expect(workflow, contains('PACKAGE_VERSION='));
    expect(workflow, contains(r'whisper-${PACKAGE_VERSION}-macos-x86_64.dmg'));
    expect(workflow, contains(r'whisper-${PACKAGE_VERSION}-ios-unsigned.ipa'));
    expect(
      workflow,
      contains(r'whisper-$($env:PACKAGE_VERSION)-windows-x86_64.exe'),
    );
    expect(workflow, contains(r'whisper-${PACKAGE_VERSION}-linux-amd64.deb'));
    expect(workflow, contains(r'whisper-${PACKAGE_VERSION}-linux-x86_64.rpm'));
    expect(
      workflow,
      contains(r'whisper-${PACKAGE_VERSION}-linux-x86_64.AppImage'),
    );
    expect(
      workflow,
      contains(r'whisper-${PACKAGE_VERSION}-android-universal.apk'),
    );
    expect(
      workflow,
      contains(r'whisper-${PACKAGE_VERSION}-android-arm64-v8a.apk'),
    );
    expect(
      workflow,
      contains(r'whisper-${PACKAGE_VERSION}-android-armeabi-v7a.apk'),
    );
    expect(
      workflow,
      contains(r'whisper-${PACKAGE_VERSION}-android-x86_64.apk'),
    );

    expect(workflow, isNot(contains('WHISPER_MACOS_DMG_PATH: whisper.dmg')));
    expect(workflow, isNot(contains('zip -r app.ipa Payload')));
    expect(workflow,
        isNot(contains('/DOUTPUT_NAME="whisper-windows-x86_64.exe"')));
    expect(workflow, isNot(contains('whisper-x86_64.rpm')));
    expect(workflow, isNot(contains('build/linux/deb/whisper-amd64.deb')));
    expect(workflow, isNot(contains('build/app/outputs/flutter-apk/*.apk')));
  });
}
