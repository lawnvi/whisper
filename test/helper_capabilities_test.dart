import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/helper.dart';

void main() {
  group('native capability helpers', () {
    test(
        'Linux supports native system audio capture independently of remote input',
        () {
      if (!Platform.isLinux) {
        return;
      }

      expect(supportsNativeSystemAudio(), isTrue);
      expect(supportsNativeRemoteInput(), isFalse);
    });
  });
}
