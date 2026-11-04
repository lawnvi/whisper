import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/android/phone_trust.dart';

void main() {
  test('reads the identity a phone reports over adb', () {
    final identity = PhoneTrust.parse(
      'Result: Bundle[{identityKey=AbC-_1x, '
      'peerId=1b2c3d4e-0000-4000-8000-123456789abc, version=1}]\n',
    );
    expect(identity?.peerId, '1b2c3d4e-0000-4000-8000-123456789abc');
    expect(identity?.identityKey, 'AbC-_1x');
    // Whisper never opened since install, an old Whisper, or none at all.
    expect(
      PhoneTrust.parse('Result: Bundle[{identityKey=, peerId=, version=1}]'),
      isNull,
    );
    expect(PhoneTrust.parse('Error: Unknown authority'), isNull);
    expect(PhoneTrust.parse(''), isNull);
  });
}
