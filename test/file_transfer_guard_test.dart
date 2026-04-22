import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/file.dart';
import 'dart:io';

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

  group('transfer checksum helpers', () {
    test('uses sha256 for resumable transfer checksum', () async {
      final directory = await Directory.systemTemp.createTemp('whisper-test-');
      final file = File('${directory.path}/payload.bin');
      await file.writeAsBytes(const <int>[1, 2, 3, 4]);

      final digest = await fileChecksum(file, algorithm: 'sha256');

      expect(
        digest,
        '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a',
      );
      await directory.delete(recursive: true);
    });

    test('computes resume proof hash from the previous full chunk', () async {
      final directory = await Directory.systemTemp.createTemp('whisper-test-');
      final file = File('${directory.path}/payload.bin');
      await file.writeAsBytes(List<int>.generate(8, (index) => index + 1));

      final proof = await resumeProofHash(
        file,
        resumeOffset: 8,
        chunkSize: 4,
      );

      expect(
        proof,
        '55e5509f8052998294266ee5b50cb592938191fb5d67f73cac2e60b0276b1bdd',
      );
      await directory.delete(recursive: true);
    });
  });
}
