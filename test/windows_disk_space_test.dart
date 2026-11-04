@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/windows_disk_space.dart';

void main() {
  test(
    'a download folder not created yet is answered for by its drive',
    () async {
      final missing = p.join(
        Directory.systemTemp.path,
        'whisper-no-such-folder',
      );

      // The two readings are taken a moment apart on a disk in use.
      expect(
        await availableBytesForPath(missing),
        closeTo(
          windowsAvailableBytes(p.windows.rootPrefix(missing))!,
          256 * 1024 * 1024,
        ),
      );
    },
  );
}
