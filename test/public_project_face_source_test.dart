import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('readmes expose latest downloads before screenshots', () {
    for (final path in ['README.md', 'README_en.md']) {
      final readme = File(path).readAsStringSync();
      final downloadIndex =
          readme.indexOf('https://github.com/lawnvi/whisper/releases/latest');
      final screenshotsIndex = readme.indexOf(path == 'README.md'
          ? '## 截图'
          : '## Screenshots');

      expect(downloadIndex, isNot(-1), reason: '$path lacks latest release URL');
      expect(screenshotsIndex, isNot(-1), reason: '$path lacks screenshots');
      expect(
        downloadIndex,
        lessThan(screenshotsIndex),
        reason: '$path should make downloads visible before screenshots',
      );
    }
  });

}
