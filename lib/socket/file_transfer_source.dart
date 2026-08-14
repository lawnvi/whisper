import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:whisper/helper/android_document_picker.dart';
import 'package:synchronized/synchronized.dart';

import '../helper/file.dart';
import 'file_transfer_v3.dart';

bool isAndroidContentUri(String value) => value.startsWith('content://');

abstract class FileTransferSource {
  Future<bool> exists();

  Future<int> length();

  Future<Uint8List> readRange(int offset, int length);
}

abstract interface class DirectReadFileTransferSource {
  Future<int> readRangeInto(
    Uint8List destination, {
    required int destinationOffset,
    required int sourceOffset,
    required int length,
  });

  Future<void> close();
}

class PathFileTransferSource
    implements FileTransferSource, DirectReadFileTransferSource {
  PathFileTransferSource(String path) : file = File(path);

  final File file;
  final Lock _readerLock = Lock();
  RandomAccessFile? _reader;

  @override
  Future<bool> exists() async => file.exists();

  @override
  Future<int> length() async => file.length();

  @override
  Future<Uint8List> readRange(int offset, int length) async {
    final bytes = Uint8List(length);
    final count = await readRangeInto(
      bytes,
      destinationOffset: 0,
      sourceOffset: offset,
      length: length,
    );
    if (count == length) {
      return bytes;
    }
    return Uint8List.sublistView(bytes, 0, count);
  }

  @override
  Future<int> readRangeInto(
    Uint8List destination, {
    required int destinationOffset,
    required int sourceOffset,
    required int length,
  }) {
    return _readerLock.synchronized(() async {
      final reader = _reader ??= await file.open();
      await reader.setPosition(sourceOffset);
      return reader.readInto(
        destination,
        destinationOffset,
        destinationOffset + length,
      );
    });
  }

  @override
  Future<void> close() {
    return _readerLock.synchronized(() async {
      final reader = _reader;
      _reader = null;
      await reader?.close();
    });
  }
}

Future<int> readTransferSourceRangeInto(
  FileTransferSource source,
  Uint8List destination, {
  required int destinationOffset,
  required int sourceOffset,
  required int length,
}) async {
  if (source is DirectReadFileTransferSource) {
    return (source as DirectReadFileTransferSource).readRangeInto(
      destination,
      destinationOffset: destinationOffset,
      sourceOffset: sourceOffset,
      length: length,
    );
  }
  final bytes = await source.readRange(sourceOffset, length);
  destination.setRange(
    destinationOffset,
    destinationOffset + bytes.length,
    bytes,
  );
  return bytes.length;
}

Future<void> closeTransferSource(FileTransferSource source) async {
  if (source is DirectReadFileTransferSource) {
    await (source as DirectReadFileTransferSource).close();
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
    final metadata = await _picker.metadata(uri);
    final size = metadata?.size;
    if (size == null || size < 0) {
      throw const FileSystemException('Transfer source size is unavailable');
    }
    if (size != expectedSize) {
      throw const FileSystemException(
        'Transfer source size does not match the declared size',
      );
    }
    return size;
  }

  @override
  Future<Uint8List> readRange(int offset, int length) {
    return _picker.readBytes(uri: uri, offset: offset, length: length);
  }
}

Future<String> checksumForTransferSource(
  FileTransferSource source, {
  required String algorithm,
  int? expectedLength,
}) async {
  if (source is PathFileTransferSource) {
    final path = source.file.path;
    return Isolate.run(() => _checksumPath(path, algorithm, expectedLength));
  }

  final checksum = StreamingChecksum(algorithm: algorithm);
  final actualLength = await source.length();
  if (expectedLength != null && actualLength != expectedLength) {
    throw const FileSystemException(
      'Transfer source size does not match the declared size',
    );
  }
  final totalLength = expectedLength ?? actualLength;
  var offset = 0;
  const readSize = 1024 * 1024;
  while (offset < totalLength) {
    final length = math.min(readSize, totalLength - offset);
    final bytes = await source.readRange(offset, length);
    if (bytes.length != length) {
      throw const FileSystemException(
        'Unexpected EOF while hashing transfer source',
      );
    }
    checksum.add(bytes);
    offset += bytes.length;
  }
  return checksum.close();
}

Future<StreamingChecksum> streamingChecksumForTransferSourcePrefix(
  FileTransferSource source, {
  required String algorithm,
  required int end,
}) async {
  final checksum = StreamingChecksum(algorithm: algorithm);
  if (end <= 0) {
    return checksum;
  }
  final actualLength = await source.length();
  if (actualLength < end) {
    throw const FileSystemException(
      'Transfer source ended before checksum prefix',
    );
  }
  var offset = 0;
  const readSize = 1024 * 1024;
  while (offset < end) {
    final length = math.min(readSize, end - offset);
    final bytes = await source.readRange(offset, length);
    if (bytes.length != length) {
      throw const FileSystemException(
        'Unexpected EOF while hashing transfer source prefix',
      );
    }
    checksum.add(bytes);
    offset += bytes.length;
  }
  return checksum;
}

Future<String> _checksumPath(
  String path,
  String algorithm,
  int? expectedLength,
) async {
  final file = File(path);
  if (expectedLength != null && await file.length() != expectedLength) {
    throw const FileSystemException(
      'Transfer source size does not match the declared size',
    );
  }
  return fileChecksum(file, algorithm: algorithm);
}

Future<String> resumeProofHashForTransferSource(
  FileTransferSource source, {
  required int resumeOffset,
}) async {
  if (resumeOffset <= 0) {
    return '';
  }
  final proofLength = math.min(
    fileTransferV3ResumeProofWindowSize,
    resumeOffset,
  );
  final proofEnd = resumeOffset;
  final proofStart = proofEnd - proofLength;
  if (source is PathFileTransferSource) {
    return resumeProofHash(
      source.file,
      resumeOffset: resumeOffset,
      chunkSize: proofLength,
    );
  }
  final bytes = await source.readRange(proofStart, proofLength);
  if (bytes.length != proofLength) {
    throw const FileSystemException(
      'Unexpected EOF while hashing resume proof',
    );
  }
  return bytesChecksum(bytes, algorithm: 'sha256');
}
