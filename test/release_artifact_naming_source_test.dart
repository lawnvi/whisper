import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CI and release jobs use published stable Flutter versions', () {
    final ci = File('.github/workflows/ci.yml').readAsStringSync();
    final release = File('.github/workflows/release.yml').readAsStringSync();

    expect(ci, contains("flutter-version: '3.44.9'"));
    expect(release, contains("flutter-version: '3.44.9'"));
    expect(ci, isNot(contains("flutter-version: '3.47.0'")));
    expect(release, isNot(contains("flutter-version: '3.47.0'")));
  });

  test('release workflow publishes normalized artifact file names', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    expect(workflow, contains('PACKAGE_VERSION='));
    expect(workflow, contains(r'whisper-${PACKAGE_VERSION}-macos-arm64.dmg'));
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
    expect(workflow, isNot(contains(r'whisper-${PACKAGE_VERSION}-macos.dmg')));
    expect(workflow, isNot(contains('zip -r app.ipa Payload')));
    expect(
      workflow,
      isNot(contains('/DOUTPUT_NAME="whisper-windows-x86_64.exe"')),
    );
    expect(workflow, isNot(contains('whisper-x86_64.rpm')));
    expect(workflow, isNot(contains('build/linux/deb/whisper-amd64.deb')));
    expect(workflow, isNot(contains('build/app/outputs/flutter-apk/*.apk')));
  });

  test('release assets are published once for each release trigger', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    final releaseActions = RegExp(
      'uses: softprops/action-gh-release@v2',
    ).allMatches(workflow);

    expect(workflow, contains('publish-release:'));
    expect(workflow, contains('uses: actions/download-artifact@v4'));
    expect(workflow, contains('merge-multiple: true'));
    expect(workflow, contains('      - build-on-macos'));
    expect(workflow, contains('      - build-on-macos-intel'));
    expect(workflow, contains('      - build-on-windows'));
    expect(workflow, contains('      - build-on-linux'));
    expect(workflow, contains('files: release-assets/**/*'));
    expect(workflow, contains('overwrite_files: true'));
    expect(releaseActions.length, 2);
    expect(workflow, contains('name: Publish tagged release'));
    expect(workflow, contains('name: Update manually rebuilt release asset'));
  });

  test('a manually rebuilt Intel package can update its dev release', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    expect(workflow, contains('publish:'));
    expect(workflow, contains("inputs.target == 'macos-intel'"));
    expect(workflow, contains('inputs.publish'));
    expect(workflow, contains("inputs.version != ''"));
    expect(workflow, contains("format('dev-v{0}', inputs.version)"));
    expect(
      workflow,
      contains("needs.build-on-macos-intel.result == 'success'"),
    );
  });
}
