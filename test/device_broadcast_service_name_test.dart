import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/page/deviceList.dart';

void main() {
  group('buildWhisperServiceName', () {
    test('uses the local uid to avoid Bonjour name collisions', () {
      expect(
        buildWhisperServiceName('whisper', 'device-1'),
        'whisper-device-1',
      );
    });
  });
}
