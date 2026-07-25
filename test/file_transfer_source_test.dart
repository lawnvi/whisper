import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/android_document_picker.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/socket/file_transfer_source.dart';

void main() {
  test('PathFileTransferSource waits for reads before closing the file', () {
    final source = File(
      'lib/socket/file_transfer_source.dart',
    ).readAsStringSync();
    final readRangeStart = source.indexOf(
      'Future<Uint8List> readRange(int offset, int length) async',
    );
    expect(readRangeStart, isNonNegative);
    final pathSource = source.substring(
      readRangeStart,
      source.indexOf('class AndroidContentUriTransferSource', readRangeStart),
    );

    expect(pathSource, contains('return await reader.read(length);'));
    expect(pathSource, isNot(contains('return reader.read(length);')));
  });

  test('AndroidContentUriTransferSource reads content uri ranges', () async {
    final bytes = Uint8List.fromList(List<int>.generate(16, (index) => index));
    final picker = _FakeAndroidDocumentPicker(bytes);
    final source = AndroidContentUriTransferSource(
      uri: 'content://documents/item',
      expectedSize: bytes.length,
      picker: picker,
    );

    expect(await source.exists(), isTrue);
    expect(await source.length(), bytes.length);
    expect(await source.readRange(4, 5), <int>[4, 5, 6, 7, 8]);
  });

  test('path source checksum runs off the UI isolate', () async {
    final root = await Directory.systemTemp.createTemp('whisper-source-hash-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}${Platform.pathSeparator}large.bin');
    final bytes = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));
    await file.writeAsBytes(bytes);

    final digest = await checksumForTransferSource(
      PathFileTransferSource(file.path),
      algorithm: 'sha256',
      expectedLength: bytes.length,
    );

    expect(digest, bytesChecksum(bytes, algorithm: 'sha256'));
  });

  test(
    'streaming source checksum can resume from an existing prefix',
    () async {
      final bytes = Uint8List.fromList(
        List<int>.generate(32, (index) => index),
      );
      final source = AndroidContentUriTransferSource(
        uri: 'content://documents/item',
        expectedSize: bytes.length,
        picker: _FakeAndroidDocumentPicker(bytes),
      );

      final checksum = await streamingChecksumForTransferSourcePrefix(
        source,
        algorithm: 'sha256',
        end: 12,
      );
      checksum.add(bytes.sublist(12));

      expect(checksum.close(), bytesChecksum(bytes, algorithm: 'sha256'));
    },
  );

  test('resume proof hashes the final min(1 MiB, offset) bytes', () async {
    final bytes = Uint8List.fromList(List<int>.generate(12, (index) => index));
    final picker = _FakeAndroidDocumentPicker(bytes);
    final source = AndroidContentUriTransferSource(
      uri: 'content://documents/item',
      expectedSize: bytes.length,
      picker: picker,
    );

    final proof = await resumeProofHashForTransferSource(
      source,
      resumeOffset: 8,
    );

    expect(proof, bytesChecksum(bytes.sublist(0, 8), algorithm: 'sha256'));
  });

  test(
    'checksum rejects a content uri that ends before its declared size',
    () async {
      final bytes = Uint8List.fromList(const <int>[1, 2, 3, 4]);
      final source = AndroidContentUriTransferSource(
        uri: 'content://documents/truncated',
        expectedSize: 8,
        picker: _FakeAndroidDocumentPicker(bytes),
      );

      await expectLater(
        checksumForTransferSource(source, algorithm: 'sha256'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('missing provider size stays unknown instead of becoming zero', () {
    final metadata = AndroidDocumentFile.fromMap(<Object?, Object?>{
      'uri': 'content://documents/unknown',
      'name': 'unknown.bin',
    });

    expect(metadata.size, -1);
  });
}

class _FakeAndroidDocumentPicker implements AndroidDocumentPickerPlatform {
  _FakeAndroidDocumentPicker(this.bytes);

  final Uint8List bytes;

  @override
  Future<AndroidDocumentFile?> metadata(String uri) async {
    return AndroidDocumentFile(
      uri: uri,
      name: 'item.bin',
      size: bytes.length,
      mimeType: 'application/octet-stream',
      lastModified: 0,
    );
  }

  @override
  Future<List<AndroidDocumentFile>> pickFiles({bool allowMultiple = true}) {
    throw UnimplementedError();
  }

  @override
  Future<Uint8List> loadThumbnail({
    required String uri,
    required int width,
    required int height,
  }) async => Uint8List(0);

  @override
  Future<bool> openDocument(String uri) async => false;

  @override
  Future<Uint8List> readBytes({
    required String uri,
    required int offset,
    required int length,
  }) async {
    final end = (offset + length).clamp(0, bytes.length);
    return Uint8List.fromList(bytes.sublist(offset, end));
  }
}
