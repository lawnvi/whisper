import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/helper.dart';

void main() {
  group('verifyCode', () {
    test('extracts Chinese verification codes', () {
      expect(verifyCode('【Whisper】您的验证码是 123456，请勿泄露。'), '123456');
    });

    test('extracts English verification codes', () {
      expect(
        verifyCode('Your verification code is 739204. Do not share it.'),
        '739204',
      );
    });

    test('extracts Spanish verification codes with accents', () {
      expect(
        verifyCode('Tu código de verificación es 654321. No lo compartas.'),
        '654321',
      );
    });

    test('normalizes separated OTP digits', () {
      expect(verifyCode('Your OTP is 123-456.'), '123456');
      expect(verifyCode('Use code 12 34 56 to sign in.'), '123456');
    });

    test('does not extract ordinary numbers without verification context', () {
      expect(verifyCode('Your order 123456 has shipped.'), isEmpty);
    });
  });

  group('isVerificationCodeNotificationPackage', () {
    test('recognizes common Android SMS packages', () {
      expect(isVerificationCodeNotificationPackage('com.android.mms'), isTrue);
      expect(
        isVerificationCodeNotificationPackage(
          'com.google.android.apps.messaging',
        ),
        isTrue,
      );
      expect(
        isVerificationCodeNotificationPackage('com.samsung.android.messaging'),
        isTrue,
      );
    });

    test('does not treat unrelated apps as SMS sources', () {
      expect(
          isVerificationCodeNotificationPackage('com.example.shop'), isFalse);
      expect(isVerificationCodeNotificationPackage(null), isFalse);
    });
  });
}
