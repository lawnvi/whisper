import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/helper.dart';

void main() {
  group('native capability helpers', () {
    test('Linux enables native remote input when an X11 display is available',
        () {
      if (!Platform.isLinux) {
        return;
      }

      expect(supportsNativeSystemAudio(), isTrue);
      expect(
        supportsNativeRemoteInput(),
        (Platform.environment['DISPLAY'] ?? '').trim().isNotEmpty,
      );
    });
  });
}
