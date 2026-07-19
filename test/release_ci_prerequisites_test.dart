import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final workflow = File('.github/workflows/release.yml').readAsStringSync();

  test('Windows runtime DLLs use explicit file destinations', () {
    expect(workflow, contains(r'$releaseDir = (Resolve-Path -LiteralPath'));
    expect(workflow, contains(r'$destination = Join-Path $releaseDir $_'));
    expect(
      workflow,
      isNot(contains(r'copy c:\Windows\System32\vcruntime140_1.dll')),
    );
  });

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
