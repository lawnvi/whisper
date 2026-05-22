import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/android_document_picker.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/socket/file_transfer_source.dart';

void main() {
  test('PathFileTransferSource waits for reads before closing the file', () {
    final source =
        File('lib/socket/file_transfer_source.dart').readAsStringSync();
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

  test('resumeProofHashForTransferSource hashes previous full chunk', () async {
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
      chunkSize: 4,
    );

    expect(proof, bytesChecksum(bytes.sublist(4, 8), algorithm: 'sha256'));
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
  Future<Uint8List> readBytes({
    required String uri,
    required int offset,
    required int length,
  }) async {
    final end = (offset + length).clamp(0, bytes.length);
    return Uint8List.fromList(bytes.sublist(offset, end));
  }
}
