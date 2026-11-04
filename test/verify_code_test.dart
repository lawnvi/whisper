import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/helper.dart';

void main() {
  group('verifyCode', () {
    test('does not extract ordinary numbers without verification context', () {
      expect(verifyCode('Your order 123456 has shipped.'), isEmpty);
    });
  });

  group('isVerificationCodeNotificationPackage', () {
    test('does not treat unrelated apps as SMS sources', () {
      expect(
        isVerificationCodeNotificationPackage('com.example.shop'),
        isFalse,
      );
      expect(isVerificationCodeNotificationPackage(null), isFalse);
    });
  });
}
