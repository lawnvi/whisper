import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/file.dart';

void main() {
  group('hasEnoughStorageForFile', () {
    test(
        'returns false when available bytes are lower than file size and reserve',
        () {
      expect(
        hasEnoughStorageForFile(
          fileSize: 100,
          availableBytes: 120,
          reserveBytes: 32,
        ),
        isFalse,
      );
    });

    test('returns true when available bytes cover file size and reserve', () {
      expect(
        hasEnoughStorageForFile(
          fileSize: 100,
          availableBytes: 160,
          reserveBytes: 32,
        ),
        isTrue,
      );
    });

    test('returns true when available bytes cannot be determined', () {
      expect(
        hasEnoughStorageForFile(
          fileSize: 100,
          availableBytes: null,
        ),
        isTrue,
      );
    });
  });

  group('isFileIntegrityValid', () {
    test('returns true when checksum matches', () {
      expect(
        isFileIntegrityValid(
          expectedMd5: 'abc123',
          actualMd5: 'abc123',
        ),
        isTrue,
      );
    });

    test('returns false when checksum does not match', () {
      expect(
        isFileIntegrityValid(
          expectedMd5: 'abc123',
          actualMd5: 'xyz456',
        ),
        isFalse,
      );
    });

    test('returns true when expected checksum is empty', () {
      expect(
        isFileIntegrityValid(
          expectedMd5: '',
          actualMd5: 'xyz456',
        ),
        isTrue,
      );
    });
  });
}
