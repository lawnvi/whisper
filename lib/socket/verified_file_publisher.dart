import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';
import 'package:whisper/helper/atomic_file_move.dart';
import 'package:whisper/helper/exclusive_file_link.dart';
import 'package:whisper/socket/transfer_file_name.dart';

const int _fileIoBufferSize = 1024 * 1024;
final Lock _downloadReservationLock = Lock();
typedef ReservationFlush = Future<void> Function(RandomAccessFile handle);

final class DownloadFileReservation {
  DownloadFileReservation._({
    required this.path,
    required RandomAccessFile handle,
    required Uint8List ownershipToken,
    required FileStat ownershipStat,
  }) : _handle = handle,
       _ownershipToken = ownershipToken,
       _ownershipStat = ownershipStat;

  final String path;
  final RandomAccessFile _handle;
  final Uint8List _ownershipToken;
  final FileStat _ownershipStat;
  final Lock _publishLock = Lock();
  bool _consumed = false;
  bool _closed = false;
  int? _publishedSize;
  String? _publishedSha256;
  FileStat? _publishedStat;
  String? _originalPath;
  DateTime? _originalModified;
  AtomicFileMove? _move;
  VerifiedTransferSnapshot? _linkedSnapshot;

  bool get sourceWasMoved => _originalPath != null;
  bool get sourceWasLinked => _linkedSnapshot != null;
}

final class VerifiedTransferSnapshot {
  VerifiedTransferSnapshot._({
    required this.path,
    required RandomAccessFile handle,
    required this.length,
    required this.sha256Value,
    required FileStat pathStat,
    required bool verifyPathContentBeforePublishing,
  }) : _handle = handle,
       _pathStat = pathStat,
       _verifyPathContentBeforePublishing = verifyPathContentBeforePublishing;

  final String path;
  final int length;
  final String sha256Value;
  final RandomAccessFile _handle;
  final FileStat _pathStat;
  final bool _verifyPathContentBeforePublishing;
  bool _closed = false;

  static Future<VerifiedTransferSnapshot> open(
    File file, {
    required int expectedSize,
    required String expectedSha256,
  }) async {
    if (expectedSize < 0 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedSha256)) {
      throw const FormatException('invalid verified snapshot metadata');
    }
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'transfer temp is not a regular file',
        file.path,
      );
    }
    final before = await file.stat();
    if (before.size != expectedSize) {
      throw FileSystemException('transfer temp length changed', file.path);
    }
    final handle = await file.open(mode: FileMode.read);
    try {
      final actual = await _hashRandomAccessFile(
        handle,
        expectedLength: expectedSize,
      );
      final after = await file.stat();
      if (!_sameStableFileStat(before, after) ||
          await handle.length() != expectedSize ||
          actual != expectedSha256) {
        throw FileSystemException(
          'transfer temp changed during verification',
          file.path,
        );
      }
      await handle.setPosition(0);
      return VerifiedTransferSnapshot._(
        path: file.path,
        handle: handle,
        length: expectedSize,
        sha256Value: actual,
        pathStat: after,
        verifyPathContentBeforePublishing: true,
      );
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }

  static Future<VerifiedTransferSnapshot> openFromStreamingChecksum(
    File file, {
    required int expectedSize,
    required String expectedSha256,
    required String streamingSha256,
  }) async {
    if (expectedSize < 0 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedSha256) ||
        streamingSha256 != expectedSha256) {
      throw FileSystemException('transfer checksum mismatch', file.path);
    }
    return openFromStreamingDigest(
      file,
      expectedSize: expectedSize,
      streamingSha256: streamingSha256,
    );
  }

  static Future<VerifiedTransferSnapshot> openFromStreamingDigest(
    File file, {
    required int expectedSize,
    required String streamingSha256,
  }) async {
    if (expectedSize < 0 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(streamingSha256)) {
      throw const FormatException('invalid streaming snapshot metadata');
    }
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'transfer temp is not a regular file',
        file.path,
      );
    }
    final before = await file.stat();
    if (before.size != expectedSize) {
      throw FileSystemException('transfer temp length changed', file.path);
    }
    final handle = await file.open(mode: FileMode.read);
    try {
      if (await handle.length() != expectedSize ||
          !_sameStableFileStat(before, await file.stat())) {
        throw FileSystemException(
          'transfer temp changed after streaming verification',
          file.path,
        );
      }
      return VerifiedTransferSnapshot._(
        path: file.path,
        handle: handle,
        length: expectedSize,
        sha256Value: streamingSha256,
        pathStat: before,
        verifyPathContentBeforePublishing: false,
      );
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }

  Future<void> _verifyStillOwnedMetadata() async {
    if (_closed) {
      throw StateError('verified transfer snapshot is closed');
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.file ||
        await _handle.length() != length ||
        !_sameStableFileStat(_pathStat, await File(path).stat())) {
      throw FileSystemException('verified transfer snapshot changed', path);
    }
  }

  Future<void> _verifyStillOwned() async {
    await _verifyStillOwnedMetadata();
    if (await _hashFilePath(File(path), expectedLength: length) !=
        sha256Value) {
      throw FileSystemException('verified transfer snapshot changed', path);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _handle.close();
  }
}

Future<DownloadFileReservation> reserveUniqueDownloadFile(
  Directory root,
  String fileName,
) async {
  if (!validateIncomingFileName(fileName)) {
    throw ArgumentError.value(fileName, 'fileName', 'invalid filename');
  }
  return _downloadReservationLock.synchronized(() async {
    final canonicalRoot = p.normalize(await root.resolveSymbolicLinks());
    final extension = p.extension(fileName);
    final stem = extension.isEmpty
        ? fileName
        : fileName.substring(0, fileName.length - extension.length);
    var suffix = 0;
    while (true) {
      final candidateName = suffix == 0 ? fileName : '$stem-$suffix$extension';
      final candidatePath = p.normalize(p.join(canonicalRoot, candidateName));
      if (p.dirname(candidatePath) != canonicalRoot) {
        throw FileSystemException(
          'download reservation escapes root',
          candidatePath,
        );
      }
      final candidate = File(candidatePath);
      try {
        await candidate.create(exclusive: true);
      } on FileSystemException {
        final type = await FileSystemEntity.type(
          candidatePath,
          followLinks: false,
        );
        if (type == FileSystemEntityType.notFound) {
          rethrow;
        }
        suffix += 1;
        continue;
      }
      final createdStat = await candidate.stat();
      final handle = await candidate.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
        if (await handle.length() != 0 ||
            !_sameStableFileStat(createdStat, await candidate.stat())) {
          throw FileSystemException(
            'download reservation changed before opening',
            candidatePath,
          );
        }
        final random = Random.secure();
        final token = Uint8List.fromList(
          List<int>.generate(32, (_) => random.nextInt(256)),
        );
        await handle.writeFrom(token);
        await handle.flush();
        final stat = await candidate.stat();
        if (stat.type != FileSystemEntityType.file ||
            stat.size != token.length) {
          throw FileSystemException(
            'download reservation could not be retained',
            candidatePath,
          );
        }
        return DownloadFileReservation._(
          path: candidatePath,
          handle: handle,
          ownershipToken: token,
          ownershipStat: stat,
        );
      } catch (_) {
        try {
          await handle.unlock();
        } catch (_) {}
        await handle.close();
        rethrow;
      }
    }
  });
}

Future<File> publishTempWithoutOverwrite(
  File temp,
  DownloadFileReservation reservation,
) async {
  if (reservation._consumed) {
    throw StateError('download reservation has already been consumed');
  }
  final length = await temp.length();
  final digest = await _hashFilePath(temp, expectedLength: length);
  final snapshot = await VerifiedTransferSnapshot.open(
    temp,
    expectedSize: length,
    expectedSha256: digest,
  );
  try {
    return await publishVerifiedSnapshot(snapshot, reservation);
  } finally {
    await snapshot.close();
  }
}

/// Publishes verified bytes without copying on supported filesystems: an
/// exclusive move on Unix, or a hard link with deferred temp cleanup on Windows.
/// Copying remains the fallback. Failed commits can discard the final name and
/// preserve/restore the source through discardDownloadReservation().
Future<DownloadFileReservation> publishVerifiedDownload(
  VerifiedTransferSnapshot snapshot,
  Directory root,
  String fileName, {
  FutureOr<void> Function(File file)? preparePublishedFile,
  AtomicFileMove atomicMove = moveFileWithoutOverwrite,
  ExclusiveFileLink atomicLink = linkFileWithoutOverwrite,
}) async {
  if (!validateIncomingFileName(fileName)) {
    throw ArgumentError.value(fileName, 'fileName', 'invalid filename');
  }
  final moved = await _downloadReservationLock.synchronized(() async {
    // Streaming snapshots already cover every received byte. The legacy
    // content-verifying path keeps its existing copy and revalidation contract.
    if (snapshot._verifyPathContentBeforePublishing) return null;
    await snapshot._verifyStillOwnedMetadata();
    final canonicalRoot = p.normalize(await root.resolveSymbolicLinks());
    final extension = p.extension(fileName);
    final stem = fileName.substring(0, fileName.length - extension.length);
    for (var suffix = 0; ; suffix++) {
      final name = suffix == 0 ? fileName : '$stem-$suffix$extension';
      final destination = p.join(canonicalRoot, name);
      await snapshot._verifyStillOwnedMetadata();
      final result = atomicMove(snapshot.path, destination);
      if (result == AtomicFileMoveResult.destinationExists) continue;
      var linked = false;
      if (result == AtomicFileMoveResult.unavailable) {
        final linkResult = atomicLink(snapshot.path, destination);
        if (linkResult == ExclusiveFileLinkResult.unavailable) return null;
        if (linkResult == ExclusiveFileLinkResult.destinationExists) continue;
        linked = true;
      }

      final published = File(destination);
      DownloadFileReservation? reservation;
      FileStat? movedStat;
      try {
        movedStat = await published.stat();
        if (await FileSystemEntity.type(destination, followLinks: false) !=
                FileSystemEntityType.file ||
            !_sameFileContentStat(snapshot._pathStat, movedStat) ||
            await snapshot._handle.length() != snapshot.length) {
          throw FileSystemException(
            'transfer changed during publication',
            destination,
          );
        }
        final handle = await published.open(mode: FileMode.append);
        reservation =
            DownloadFileReservation._(
                path: destination,
                handle: handle,
                ownershipToken: Uint8List(0),
                ownershipStat: movedStat,
              )
              .._consumed = true
              .._publishedSize = snapshot.length
              .._publishedSha256 = snapshot.sha256Value
              .._publishedStat = movedStat
              .._originalPath = linked ? null : snapshot.path
              .._linkedSnapshot = linked ? snapshot : null
              .._originalModified = snapshot._pathStat.modified
              .._move = atomicMove;
        await handle.lock(FileLock.exclusive);
        if (!_sameStableFileStat(movedStat, await published.stat())) {
          throw FileSystemException(
            'published transfer path changed',
            destination,
          );
        }
        await preparePublishedFile?.call(published);
        await _verifyPublishedReservationMetadata(
          reservation,
          expectedSize: snapshot.length,
        );
        reservation._publishedStat = await published.stat();
        return reservation;
      } catch (_) {
        if (reservation != null) {
          await _capturePartialReservationOwnership(reservation);
          await discardDownloadReservation(reservation);
        } else if (movedStat != null &&
            _sameFileContentStat(snapshot._pathStat, movedStat) &&
            _sameStableFileStat(movedStat, await published.stat())) {
          // Never overwrite a source path recreated while publication failed.
          if (linked) {
            await snapshot.close();
            await published.delete();
          } else {
            atomicMove(destination, snapshot.path);
          }
        }
        rethrow;
      }
    }
  });
  if (moved != null) return moved;

  final reservation = await reserveUniqueDownloadFile(root, fileName);
  try {
    await publishVerifiedSnapshot(
      snapshot,
      reservation,
      preparePublishedFile: preparePublishedFile,
    );
    return reservation;
  } catch (_) {
    await discardDownloadReservation(reservation);
    rethrow;
  }
}

Future<File> publishVerifiedSnapshot(
  VerifiedTransferSnapshot snapshot,
  DownloadFileReservation reservation, {
  ReservationFlush? flushReservation,
  FutureOr<void> Function(File file)? preparePublishedFile,
}) {
  return reservation._publishLock.synchronized(() async {
    if (reservation._consumed) {
      throw StateError('download reservation has already been consumed');
    }
    if (snapshot._verifyPathContentBeforePublishing) {
      await snapshot._verifyStillOwned();
    } else {
      await snapshot._verifyStillOwnedMetadata();
    }
    await _verifyReservationPlaceholder(reservation);
    reservation._consumed = true;
    try {
      await snapshot._handle.setPosition(0);
      await reservation._handle.setPosition(0);
      await reservation._handle.truncate(0);
      final reverifyContent = snapshot._verifyPathContentBeforePublishing;
      final digestSink = reverifyContent ? _DigestSink() : null;
      final input = digestSink == null
          ? null
          : sha256.startChunkedConversion(digestSink);
      var copied = 0;
      while (copied < snapshot.length) {
        final bytes = await snapshot._handle.read(
          min(_fileIoBufferSize, snapshot.length - copied),
        );
        if (bytes.isEmpty) {
          throw FileSystemException(
            'verified transfer snapshot ended early',
            snapshot.path,
          );
        }
        input?.add(bytes);
        await reservation._handle.writeFrom(bytes);
        copied += bytes.length;
      }
      input?.close();
      if (copied != snapshot.length ||
          (digestSink != null &&
              digestSink.value.toString() != snapshot.sha256Value) ||
          await snapshot._handle.length() != snapshot.length) {
        throw FileSystemException(
          'verified transfer snapshot changed while publishing',
          snapshot.path,
        );
      }
      await (flushReservation ?? _flushReservationHandle)(reservation._handle);
      await snapshot._verifyStillOwnedMetadata();
      final published = File(reservation.path);
      await preparePublishedFile?.call(published);
      if (reverifyContent) {
        await _verifyPublishedReservation(
          reservation,
          expectedSize: snapshot.length,
          expectedSha256: snapshot.sha256Value,
          requirePreviousStat: false,
        );
      } else {
        await _verifyPublishedReservationMetadata(
          reservation,
          expectedSize: snapshot.length,
        );
      }
      reservation._publishedSize = snapshot.length;
      reservation._publishedSha256 = snapshot.sha256Value;
      reservation._publishedStat = await published.stat();
      return published;
    } catch (_) {
      await _capturePartialReservationOwnership(reservation);
      rethrow;
    }
  });
}

Future<void> _flushReservationHandle(RandomAccessFile handle) => handle.flush();

Future<void> _capturePartialReservationOwnership(
  DownloadFileReservation reservation,
) async {
  try {
    final length = await reservation._handle.length();
    final handleDigest = await _hashRandomAccessFile(
      reservation._handle,
      expectedLength: length,
    );
    final before = await File(reservation.path).stat();
    if (before.type != FileSystemEntityType.file || before.size != length) {
      return;
    }
    // Windows enforces our byte-range lock against a second read handle, even
    // in this process. Use the locked handle and stable metadata there, just
    // as _verifyPublishedReservation does during rollback.
    final pathDigest = Platform.isWindows
        ? handleDigest
        : await _hashFilePath(File(reservation.path), expectedLength: length);
    final after = await File(reservation.path).stat();
    if (handleDigest != pathDigest || !_sameStableFileStat(before, after)) {
      return;
    }
    reservation._publishedSize = length;
    reservation._publishedSha256 = handleDigest;
    reservation._publishedStat = after;
  } catch (_) {
    // A partial file with uncertain ownership is deliberately left untouched.
  }
}

Future<void> discardDownloadReservation(DownloadFileReservation reservation) {
  return reservation._publishLock.synchronized(() async {
    if (reservation._closed) return;
    var mayDelete = false;
    try {
      if (reservation._publishedSize case final size?) {
        await _verifyPublishedReservation(
          reservation,
          expectedSize: size,
          expectedSha256: reservation._publishedSha256!,
          requirePreviousStat: true,
        );
      } else if (!reservation._consumed) {
        await _verifyReservationPlaceholder(reservation);
      } else {
        throw FileSystemException(
          'download reservation ownership is indeterminate',
          reservation.path,
        );
      }
      mayDelete = true;
    } on FileSystemException {
      mayDelete = false;
    } finally {
      await _closeReservationHandle(reservation);
      // Windows sharing applies to every hard link, so the verified source
      // handle must also close before the failed final name can be removed.
      await reservation._linkedSnapshot?.close();
    }
    if (mayDelete) {
      if (reservation._originalPath case final originalPath?) {
        final result = reservation._move!(reservation.path, originalPath);
        if (result == AtomicFileMoveResult.moved) {
          await File(
            originalPath,
          ).setLastModified(reservation._originalModified!);
        }
      } else {
        final linkedSource = reservation._linkedSnapshot?.path;
        if (linkedSource != null &&
            await File(linkedSource).exists() &&
            await FileSystemEntity.identical(reservation.path, linkedSource)) {
          await File(
            linkedSource,
          ).setLastModified(reservation._originalModified!);
        }
        await File(reservation.path).delete();
      }
    }
  });
}

Future<void> refreshPublishedDownloadReservation(
  DownloadFileReservation reservation,
) {
  return reservation._publishLock.synchronized(() async {
    final size = reservation._publishedSize;
    final checksum = reservation._publishedSha256;
    if (reservation._closed || size == null || checksum == null) {
      throw StateError('download reservation has not been published');
    }
    await _verifyPublishedReservation(
      reservation,
      expectedSize: size,
      expectedSha256: checksum,
      requirePreviousStat: false,
    );
    reservation._publishedStat = await File(reservation.path).stat();
  });
}

Future<void> releaseDownloadReservation(DownloadFileReservation reservation) {
  return reservation._publishLock.synchronized(() async {
    if (reservation._closed) return;
    if (reservation._publishedSize == null ||
        reservation._publishedSha256 == null) {
      throw StateError('download reservation has not been published');
    }
    await _closeReservationHandle(reservation);
  });
}

Future<void> _verifyReservationPlaceholder(
  DownloadFileReservation reservation,
) async {
  if (reservation._closed) {
    throw StateError('download reservation is closed');
  }
  final type = await FileSystemEntity.type(
    reservation.path,
    followLinks: false,
  );
  final stat = await File(reservation.path).stat();
  if (type != FileSystemEntityType.file ||
      !_sameStableFileStat(reservation._ownershipStat, stat) ||
      await reservation._handle.length() !=
          reservation._ownershipToken.length) {
    throw FileSystemException(
      'download reservation ownership changed',
      reservation.path,
    );
  }
  await reservation._handle.setPosition(0);
  final ownedBytes = await reservation._handle.read(
    reservation._ownershipToken.length,
  );
  if (!_equalBytes(ownedBytes, reservation._ownershipToken)) {
    throw FileSystemException(
      'download reservation ownership token changed',
      reservation.path,
    );
  }
  if (!Platform.isWindows) {
    final pathBytes = await File(reservation.path).readAsBytes();
    if (!_equalBytes(pathBytes, reservation._ownershipToken)) {
      throw FileSystemException(
        'download reservation ownership token changed',
        reservation.path,
      );
    }
  }
}

Future<void> _verifyPublishedReservation(
  DownloadFileReservation reservation, {
  required int expectedSize,
  required String expectedSha256,
  required bool requirePreviousStat,
}) async {
  if (reservation._closed ||
      await FileSystemEntity.type(reservation.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await reservation._handle.length() != expectedSize) {
    throw FileSystemException(
      'published reservation ownership changed',
      reservation.path,
    );
  }
  final currentStat = await File(reservation.path).stat();
  if (requirePreviousStat &&
      !_sameStableFileStat(reservation._publishedStat!, currentStat)) {
    throw FileSystemException(
      'published reservation metadata changed',
      reservation.path,
    );
  }
  final handleDigest = await _hashRandomAccessFile(
    reservation._handle,
    expectedLength: expectedSize,
  );
  if (handleDigest != expectedSha256) {
    throw FileSystemException(
      'published reservation content changed',
      reservation.path,
    );
  }
  // Windows byte-range locks reject a second read handle even in this process.
  // The locked handle and stable path metadata retain ownership there; Unix
  // additionally verifies through the path to detect a replaced directory entry.
  if (!Platform.isWindows &&
      await _hashFilePath(
            File(reservation.path),
            expectedLength: expectedSize,
          ) !=
          expectedSha256) {
    throw FileSystemException(
      'published reservation content changed',
      reservation.path,
    );
  }
}

Future<void> _verifyPublishedReservationMetadata(
  DownloadFileReservation reservation, {
  required int expectedSize,
}) async {
  if (reservation._closed ||
      await FileSystemEntity.type(reservation.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await reservation._handle.length() != expectedSize ||
      (await File(reservation.path).stat()).size != expectedSize) {
    throw FileSystemException(
      'published reservation ownership changed',
      reservation.path,
    );
  }
}

Future<void> _closeReservationHandle(
  DownloadFileReservation reservation,
) async {
  if (reservation._closed) return;
  reservation._closed = true;
  try {
    await reservation._handle.unlock();
  } catch (_) {}
  await reservation._handle.close();
}

Future<String> _hashFilePath(File file, {required int expectedLength}) async {
  final handle = await file.open(mode: FileMode.read);
  try {
    return await _hashRandomAccessFile(handle, expectedLength: expectedLength);
  } finally {
    await handle.close();
  }
}

Future<String> _hashRandomAccessFile(
  RandomAccessFile handle, {
  required int expectedLength,
}) async {
  await handle.setPosition(0);
  final digestSink = _DigestSink();
  final input = sha256.startChunkedConversion(digestSink);
  var consumed = 0;
  while (consumed < expectedLength) {
    final bytes = await handle.read(
      min(_fileIoBufferSize, expectedLength - consumed),
    );
    if (bytes.isEmpty) {
      throw const FileSystemException('file ended before expected length');
    }
    input.add(bytes);
    consumed += bytes.length;
  }
  input.close();
  if (consumed != expectedLength || await handle.length() != expectedLength) {
    throw const FileSystemException('file length changed while hashing');
  }
  return digestSink.value.toString();
}

bool _sameStableFileStat(FileStat first, FileStat second) =>
    _sameFileContentStat(first, second) && first.changed == second.changed;

bool _sameFileContentStat(FileStat first, FileStat second) =>
    first.type == second.type &&
    first.mode == second.mode &&
    first.size == second.size &&
    first.modified == second.modified;

bool _equalBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index += 1) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

final class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get value {
    final digest = _digest;
    if (digest == null) throw StateError('digest is unavailable');
    return digest;
  }

  @override
  void add(Digest data) {
    if (_digest != null) throw StateError('digest was produced twice');
    _digest = data;
  }

  @override
  void close() {}
}
