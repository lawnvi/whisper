import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:whisper/helper/android_document_picker.dart';

import '../helper/file.dart';

bool isAndroidContentUri(String value) => value.startsWith('content://');

abstract class FileTransferSource {
  Future<bool> exists();

  Future<int> length();

  Future<Uint8List> readRange(int offset, int length);
}

class PathFileTransferSource implements FileTransferSource {
  PathFileTransferSource(String path) : file = File(path);

  final File file;

  @override
  Future<bool> exists() async => file.exists();

  @override
  Future<int> length() async => file.length();

  @override
  Future<Uint8List> readRange(int offset, int length) async {
    final reader = await file.open();
    try {
      await reader.setPosition(offset);
      return await reader.read(length);
    } finally {
      await reader.close();
    }
  }
}

class AndroidContentUriTransferSource implements FileTransferSource {
  AndroidContentUriTransferSource({
    required this.uri,
    required this.expectedSize,
    AndroidDocumentPickerPlatform? picker,
  }) : _picker = picker ?? AndroidDocumentPicker.shared;

  final String uri;
  final int expectedSize;
  final AndroidDocumentPickerPlatform _picker;

  @override
  Future<bool> exists() async {
    final metadata = await _picker.metadata(uri);
    return metadata != null;
  }

  @override
  Future<int> length() async {
    if (expectedSize > 0) {
      return expectedSize;
    }
    final metadata = await _picker.metadata(uri);
    return metadata?.size ?? 0;
  }

  @override
  Future<Uint8List> readRange(int offset, int length) {
    return _picker.readBytes(uri: uri, offset: offset, length: length);
  }
}

Future<String> checksumForTransferSource(
  FileTransferSource source, {
  required String algorithm,
}) async {
  if (source is PathFileTransferSource) {
    return fileChecksum(source.file, algorithm: algorithm);
  }

  final checksum = StreamingChecksum(algorithm: algorithm);
  final totalLength = await source.length();
  var offset = 0;
  const readSize = 1024 * 1024;
  while (offset < totalLength) {
    final length = math.min(readSize, totalLength - offset);
    final bytes = await source.readRange(offset, length);
    if (bytes.isEmpty && length > 0) {
      break;
    }
    checksum.add(bytes);
    offset += bytes.length;
  }
  return checksum.close();
}

Future<String> resumeProofHashForTransferSource(
  FileTransferSource source, {
  required int resumeOffset,
  required int chunkSize,
}) async {
  if (resumeOffset <= 0 || chunkSize <= 0) {
    return '';
  }
  final proofEnd = resumeOffset;
  final proofStart = proofEnd - chunkSize;
  if (proofStart < 0) {
    return '';
  }
  if (source is PathFileTransferSource) {
    return resumeProofHash(
      source.file,
      resumeOffset: resumeOffset,
      chunkSize: chunkSize,
    );
  }
  final bytes = await source.readRange(proofStart, chunkSize);
  if (bytes.length != chunkSize) {
    return '';
  }
  return bytesChecksum(bytes, algorithm: 'sha256');
}
