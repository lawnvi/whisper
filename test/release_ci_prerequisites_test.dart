import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final workflow = File('.github/workflows/release.yml').readAsStringSync();
  final windowsInstaller = File('windows/installer.nsi').readAsStringSync();

  test(
    'Windows packaging discovers and reuses the Flutter output directory',
    () {
      expect(workflow, contains('runs-on: windows-2022'));
      expect(
        workflow,
        contains(r'PUB_CACHE: ${{ github.workspace }}\.pub-cache'),
      );
      final build = workflow.indexOf('flutter build windows');
      final exitCheck = workflow.indexOf(r'if ($LASTEXITCODE -ne 0)');
      final discoverRunner = workflow.indexOf(
        r'Get-ChildItem -LiteralPath "build/windows" -Filter "whisper.exe"',
      );
      expect(build, greaterThanOrEqualTo(0));
      expect(exitCheck, greaterThan(build));
      expect(discoverRunner, greaterThan(exitCheck));
      expect(
        workflow,
        contains(
          r'Get-ChildItem -LiteralPath "build/windows" -Filter "whisper.exe"',
        ),
      );
      expect(workflow, contains(r'WINDOWS_RELEASE_DIR=$releaseDir'));
      expect(
        workflow,
        contains(r'Resolve-Path -LiteralPath $env:WINDOWS_RELEASE_DIR'),
      );
      expect(workflow, contains(r'$destination = Join-Path $releaseDir $_'));
      expect(workflow, contains(r'/DBUILD_DIR="$env:WINDOWS_RELEASE_DIR"'));
      expect(windowsInstaller, contains(r'!define BUILD_DIR'));
      expect(windowsInstaller, contains(r'File /r "${BUILD_DIR}\*.*"'));
      expect(
        workflow,
        isNot(contains(r'copy c:\Windows\System32\vcruntime140_1.dll')),
      );
    },
  );

  test('Ubuntu 22 resolves the GStreamer libunwind conflict', () {
    final removeConflict = workflow.indexOf(
      'apt-get remove -y libunwind-14-dev',
    );
    final installDependencies = workflow.indexOf(
      'libunwind-dev libgstreamer1.0-dev',
    );

    expect(removeConflict, greaterThanOrEqualTo(0));
    expect(installDependencies, greaterThan(removeConflict));
  });

  test('release builds reuse caches and avoid redundant tool installs', () {
    expect(
      RegExp(r'^\s+cache: true$', multiLine: true).allMatches(workflow).length,
      greaterThanOrEqualTo(4),
    );
    expect(workflow, contains('build-on-android:'));
    expect(workflow, contains('description: Platform to build'));
    expect(workflow, contains("inputs.target == 'windows'"));
    expect(workflow, contains("inputs.target == 'android'"));
    expect(workflow, contains('name: Linux'));
    expect(workflow, contains('name: Android'));
    expect(workflow, contains('flutter build windows --no-pub'));
    expect(workflow, contains('flutter build linux --no-pub'));
    expect(workflow, contains('flutter build ios --no-codesign --no-pub'));
    expect(workflow, contains('flutter build apk --split-per-abi --no-pub'));
    expect(workflow, isNot(contains('choco install nsis')));
    expect(workflow, isNot(contains('commandlinetools.zip')));
    expect(workflow, isNot(contains('sdkmanager" --update')));
    expect(workflow, isNot(contains('pod install --repo-update')));
  });
}
