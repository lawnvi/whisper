@TestOn('linux')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/desktop_video_library.dart';

void main() {
  test('looking for libmpv says which one there is, or that there is none', () {
    final found = linuxSystemLibmpv();

    expect(found, anyOf(isNull, startsWith('libmpv.so')));
    expect(ensureDesktopVideoLibrary(), found != null);
    // Asked again, it does not search again.
    expect(linuxSystemLibmpv(), found);
    // ignore: avoid_print
    print('libmpv on this system: $found');
  });
}
