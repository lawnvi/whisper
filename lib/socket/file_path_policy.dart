import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

const int maxIncomingFileNameBytes = 240;
const int _fileIoBufferSize = 1024 * 1024;

final RegExp _canonicalTransferId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final RegExp _windowsReservedName = RegExp(
  r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
  caseSensitive: false,
);
const Set<int> _windowsInvalidCharacters = <int>{
  0x3c,
  0x3e,
  0x3a,
  0x22,
  0x7c,
  0x3f,
  0x2a,
};
final Lock _downloadReservationLock = Lock();

typedef ReservationFlush = Future<void> Function(RandomAccessFile handle);

bool validateIncomingFileName(String fileName) {
  if (fileName.isEmpty ||
      !_hasWellFormedUtf16(fileName) ||
      utf8.encode(fileName).length > maxIncomingFileNameBytes ||
      fileName == '.' ||
      fileName == '..' ||
      fileName.endsWith('.') ||
      fileName.endsWith(' ') ||
      fileName.contains('/') ||
      fileName.contains('\\')) {
    return false;
  }
  for (final rune in fileName.runes) {
    if (rune <= 0x1f ||
        (rune >= 0x7f && rune <= 0x9f) ||
        _windowsInvalidCharacters.contains(rune)) {
      return false;
    }
  }
  final portableStem = fileName.split('.').first;
  return !_windowsReservedName.hasMatch(portableStem);
}

bool _hasWellFormedUtf16(String value) {
  final units = value.codeUnits;
  for (var index = 0; index < units.length; index += 1) {
    final unit = units[index];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (index + 1 >= units.length) {
        return false;
      }
      final next = units[++index];
      if (next < 0xdc00 || next > 0xdfff) {
        return false;
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

Future<String> safeTransferTempPath(Directory root, String transferId) async {
  if (!_canonicalTransferId.hasMatch(transferId)) {
    throw const FormatException('invalid transfer id');
  }
  final canonicalRoot = p.normalize(await root.resolveSymbolicLinks());
  final canonicalTransferDirectory = await _resolveChildDirectoryWithoutCreate(
    canonicalRoot,
    const <String>['.whisper', 'transfers'],
  );
  if (!_isWithinOrEqual(canonicalRoot, canonicalTransferDirectory)) {
    throw FileSystemException(
      'transfer directory escapes download root',
      canonicalTransferDirectory,
    );
  }
  final candidate = p.normalize(
    p.join(canonicalTransferDirectory, '$transferId.part'),
  );
  if (p.dirname(candidate) != canonicalTransferDirectory ||
      !p.isWithin(canonicalRoot, candidate)) {
    throw FileSystemException('transfer path escapes download root', candidate);
  }
  final candidateType = await FileSystemEntity.type(
    candidate,
    followLinks: false,
  );
  if (candidateType != FileSystemEntityType.notFound &&
      candidateType != FileSystemEntityType.file) {
    throw FileSystemException('transfer temp is not a regular file', candidate);
  }
  return candidate;
}

Future<File> revalidateTransferTempFile({
  required Directory root,
  required String transferId,
  required String expectedPath,
}) async {
  final safePath = await safeTransferTempPath(root, transferId);
  if (!p.equals(p.normalize(expectedPath), safePath)) {
    throw FileSystemException(
      'transfer temp path changed outside its download root',
      expectedPath,
    );
  }
  return File(safePath);
}

Future<String> _resolveChildDirectoryWithoutCreate(
  String canonicalRoot,
  List<String> segments,
) async {
  var current = canonicalRoot;
  for (final segment in segments) {
    final next = p.normalize(p.join(current, segment));
    final type = await FileSystemEntity.type(next, followLinks: false);
    switch (type) {
      case FileSystemEntityType.notFound:
        current = next;
        break;
      case FileSystemEntityType.directory:
        current = p.normalize(await Directory(next).resolveSymbolicLinks());
        break;
      case FileSystemEntityType.link:
        final resolved = p.normalize(await Link(next).resolveSymbolicLinks());
        if (await FileSystemEntity.type(resolved) !=
            FileSystemEntityType.directory) {
          throw FileSystemException('transfer parent is not a directory', next);
        }
        current = resolved;
        break;
      case FileSystemEntityType.file:
      case FileSystemEntityType.unixDomainSock:
      case FileSystemEntityType.pipe:
        throw FileSystemException('transfer parent is not a directory', next);
    }
    if (!_isWithinOrEqual(canonicalRoot, current)) {
      throw FileSystemException(
        'transfer directory escapes download root',
        current,
      );
    }
  }
  return current;
}

bool _isWithinOrEqual(String parent, String child) =>
    p.equals(parent, child) || p.isWithin(parent, child);

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
      final digestSink = _DigestSink();
      final input = sha256.startChunkedConversion(digestSink);
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
        input.add(bytes);
        await reservation._handle.writeFrom(bytes);
        copied += bytes.length;
      }
      input.close();
      if (copied != snapshot.length ||
          digestSink.value.toString() != snapshot.sha256Value ||
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
      await _verifyPublishedReservation(
        reservation,
        expectedSize: snapshot.length,
        expectedSha256: snapshot.sha256Value,
        requirePreviousStat: false,
      );
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
    final pathDigest = await _hashFilePath(
      File(reservation.path),
      expectedLength: length,
    );
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
    }
    if (mayDelete) {
      await File(reservation.path).delete();
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
    first.type == second.type &&
    first.mode == second.mode &&
    first.size == second.size &&
    first.modified == second.modified &&
    first.changed == second.changed;

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
