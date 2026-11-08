import 'dart:io';
import 'dart:math' as math;

import 'package:whisper/helper/parallel_streaming_checksum.dart';
import 'package:whisper/socket/file_transfer_source.dart';

/// How far a transfer may run ahead of its checksum worker. On a desktop
/// that is eight frames: hashing then keeps pace on its own thread instead
/// of holding up every other frame (a slow CPU's SHA-256 is the slowest step
/// a transfer has). Phones send 1 MiB frames and keep less in memory.
final int checksumLeadBytes = Platform.isAndroid || Platform.isIOS
    ? 8 * 1024 * 1024
    : 32 * 1024 * 1024;

Future<ParallelStreamingChecksum> parallelChecksumForFilePrefix(
  File file, {
  required String algorithm,
  required int end,
}) async {
  final checksum = await ParallelStreamingChecksum.start(
    algorithm: algorithm,
    maxPendingBytes: checksumLeadBytes,
  );
  try {
    if (end > 0) {
      await for (final chunk in file.openRead(0, end)) {
        await checksum.add(chunk);
      }
    }
    return checksum;
  } catch (_) {
    await checksum.dispose();
    rethrow;
  }
}

Future<ParallelStreamingChecksum> parallelChecksumForSourcePrefix(
  FileTransferSource source, {
  required String algorithm,
  required int end,
}) async {
  final checksum = await ParallelStreamingChecksum.start(
    algorithm: algorithm,
    maxPendingBytes: checksumLeadBytes,
  );
  try {
    var offset = 0;
    while (offset < end) {
      final length = math.min(1024 * 1024, end - offset);
      final bytes = await source.readRange(offset, length);
      if (bytes.length != length) {
        throw const FileSystemException(
          'Unexpected EOF while hashing transfer source prefix',
        );
      }
      await checksum.add(bytes);
      offset += bytes.length;
    }
    return checksum;
  } catch (_) {
    await checksum.dispose();
    rethrow;
  }
}
