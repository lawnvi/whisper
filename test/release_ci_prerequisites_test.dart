import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final workflow = File('.github/workflows/release.yml').readAsStringSync();
  final windowsInstaller = File('windows/installer.nsi').readAsStringSync();

  test(
    'Windows packaging discovers and reuses the Flutter output directory',
    () {
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
}
