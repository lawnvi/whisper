@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/windows_disk_space.dart';

void main() {
  test('free space is read for an existing folder', () {
    final available = windowsAvailableBytes(Directory.systemTemp.path);

    expect(available, isNotNull);
    expect(available, greaterThan(0));
  });

  test('a folder that does not exist has no answer of its own', () {
    final missing = p.join(Directory.systemTemp.path, 'whisper-no-such-folder');

    expect(windowsAvailableBytes(missing), isNull);
  });

  test(
    'a download folder not created yet is answered for by its drive',
    () async {
      final missing = p.join(
        Directory.systemTemp.path,
        'whisper-no-such-folder',
      );

      expect(
        await availableBytesForPath(missing),
        windowsAvailableBytes(p.windows.rootPrefix(missing)),
      );
    },
  );

  test('asking is quick enough to do for every incoming transfer', () {
    final clock = Stopwatch()..start();
    for (var index = 0; index < 100; index += 1) {
      windowsAvailableBytes(Directory.systemTemp.path);
    }

    expect(clock.elapsedMilliseconds, lessThan(1000));
  });
}
