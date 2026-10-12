import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:whisper/socket/folder_output_file.dart';
import 'package:whisper/socket/folder_transfer_digest.dart';
import 'package:whisper/socket/folder_transfer_manifest.dart';
import 'package:whisper/socket/folder_transfer_scan.dart'
    show folderSkippedEntryListLimit;
import 'package:whisper/socket/folder_write_pool.dart';

const String folderStagingManifestName = 'manifest';
const String folderStagingJournalName = 'journal';
const String folderStagingTreeName = 'tree';

const int _journalHeaderLength = 36;
const int _journalRecordLength = 8;
const int _journalRecordFailed = 1;
const int _journalRecordCheckpoint = 2;
const int _rehashBufferSize = 1024 * 1024;

enum FolderReceiveFailureKind { manifest, storage, io }

final class FolderReceiveException implements Exception {
  const FolderReceiveException(this.kind, this.description);

  final FolderReceiveFailureKind kind;
  final String description;

  @override
  String toString() => 'FolderReceiveException(${kind.name})';
}

final class FolderReceiveConfig {
  const FolderReceiveConfig({
    required this.stagingPath,
    required this.streamSize,
    required this.manifestLength,
    required this.manifestSha256,
    required this.fileCount,
    required this.directoryCount,
    required this.totalBytes,
    required this.caseInsensitiveNames,
    required this.pathSeparator,
    required this.checkpointIntervalBytes,
    this.checkpointIntervalMs = 1000,
    this.progressIntervalMs = 100,
    this.writeWorkers = 0,
  });

  final String stagingPath;
  final int streamSize;
  final int manifestLength;
  final String manifestSha256;
  final int fileCount;
  final int directoryCount;
  final int totalBytes;
  final bool caseInsensitiveNames;
  final String pathSeparator;

  /// A checkpoint is taken once this many bytes or [checkpointIntervalMs]
  /// have gone by, whichever comes first. The time limit is what keeps a
  /// sender waiting on a tree of tiny files from giving up on us.
  final int checkpointIntervalBytes;
  final int checkpointIntervalMs;
  final int progressIntervalMs;

  /// Isolates that write small files side by side; see [FolderWritePool].
  /// With none, every file is written where the stream is read.
  final int writeWorkers;
}

final class FolderReceiveProgress {
  const FolderReceiveProgress({
    required this.processedOffset,
    required this.durableOffset,
    required this.filesWritten,
    required this.filesSkipped,
    required this.filesSettled,
  });

  /// Stream bytes consumed so far.
  final int processedOffset;

  /// Stream bytes covered by the latest checkpoint; safe to acknowledge.
  final int durableOffset;
  final int filesWritten;
  final int filesSkipped;

  /// Files the stream has moved past, whether written or left out. This is
  /// what a progress display counts up.
  final int filesSettled;
}

final class FolderReceiveSummary {
  const FolderReceiveSummary({
    required this.filesWritten,
    required this.filesSkipped,
    required this.skipped,
  });

  final int filesWritten;
  final int filesSkipped;

  /// The first of the skipped files by name; [filesSkipped] counts them all.
  final List<FolderSkippedEntry> skipped;
}

/// Splits a folder stream back into files under the staging directory.
/// Blocking: lives in the worker isolate of [FolderReceiveSession].
///
/// Staging holds the verified manifest, a journal and the tree being built.
/// The journal records which files failed and how far the stream has been
/// settled, so a restart checks only the files after the last checkpoint.
///
/// With [deferred], a small file is gathered in memory and handed over whole
/// once its trailer has matched, to be written while the stream moves on.
/// Such files reach the disk in no particular order, so a checkpoint covers
/// the stream only up to the first of them that is still on its way.
final class FolderStreamWriter {
  FolderStreamWriter(this.config, {this.onProgress, this.deferred});

  final FolderReceiveConfig config;
  final void Function(FolderReceiveProgress progress)? onProgress;

  /// Disposed of together with this writer.
  final FolderDeferredWrites? deferred;
  final Stopwatch _clock = Stopwatch()..start();
  final SplayTreeSet<int> _failedFiles = SplayTreeSet<int>();
  final Map<int, FolderSkipReason> _failureReasons = <int, FolderSkipReason>{};
  final Uint8List _trailer = Uint8List(folderTrailerLength);

  /// Entries left out because a directory above them could not be created.
  final Set<int> _unwritableEntries = <int>{};

  final FolderFileWriter _files = FolderFileWriter();

  FolderManifest? _manifest;
  Uint8List? _manifestBuffer;
  RandomAccessFile? _journal;
  int _position = 0;
  int _durable = 0;
  int _lastCheckpointMs = 0;
  int _lastProgressMs = 0;
  int _filesWritten = 0;

  // The file the stream is currently inside.
  int _file = 0;
  bool _begun = false;
  bool _discarding = false;
  FolderSkipReason? _fileFailure;
  FolderOutputFile? _output;
  FolderFileDigest? _digest;
  int _fileReceived = 0;
  int _trailerFilled = 0;

  /// The current file while it is gathered to be handed to [deferred].
  Uint8List? _held;

  /// Files handed to [deferred] that are not known to be on disk yet, in
  /// stream order.
  final Queue<_DeferredEntry> _unsettled = Queue<_DeferredEntry>();
  final Map<int, _DeferredEntry> _unsettledByFile = <int, _DeferredEntry>{};
  int _deferredBytes = 0;

  String get _separator => config.pathSeparator;
  String get _manifestPath =>
      '${config.stagingPath}$_separator$folderStagingManifestName';
  String get _journalPath =>
      '${config.stagingPath}$_separator$folderStagingJournalName';
  String get _treePath =>
      '${config.stagingPath}$_separator$folderStagingTreeName';

  int get processedOffset => _position;
  int get durableOffset => _durable;
  bool get isComplete => _position == config.streamSize && _unsettled.isEmpty;

  /// What has been handed to [deferred] and is not written yet.
  int get deferredBytes => _deferredBytes;
  int get deferredFiles => _unsettledByFile.length;

  /// The file every one before which is on disk or given up on.
  int get _settledFile => _unsettled.isEmpty ? _file : _unsettled.first.file;

  /// How far into the stream everything is on disk.
  int get _settledPosition {
    if (_unsettled.isNotEmpty) {
      return _manifest!.fileStart(_unsettled.first.file);
    }
    return _held == null
        ? _position
        : _position - _fileReceived - _trailerFilled;
  }

  /// A file larger than this is written as it arrives. The stream has to be
  /// able to reach the end of a gathered file before the next checkpoint,
  /// and a sender is only sure to get that far past the last one.
  int get _deferLimit =>
      math.min(deferred!.maxFileBytes, config.checkpointIntervalBytes ~/ 2);
  int get filesSkipped =>
      (_manifest?.skippedFileCount ?? 0) + _failedFiles.length;

  FolderReceiveProgress get progress => FolderReceiveProgress(
    processedOffset: _position,
    durableOffset: _durable,
    filesWritten: _filesWritten,
    filesSkipped: filesSkipped,
    filesSettled: _manifest == null ? 0 : _file,
  );

  FolderReceiveSummary get summary {
    final manifest = _manifest!;
    final skipped = <FolderSkippedEntry>[];
    for (final file in _failedFiles) {
      if (skipped.length >= folderSkippedEntryListLimit) break;
      skipped.add(
        FolderSkippedEntry(
          path: manifest.portablePath(manifest.fileEntry(file)),
          reason: _failureReasons[file] ?? FolderSkipReason.writeFailed,
        ),
      );
    }
    if (manifest.skippedFileCount > 0) {
      for (
        var file = 0;
        file < manifest.fileCount &&
            skipped.length < folderSkippedEntryListLimit;
        file += 1
      ) {
        if (manifest.isFileSkipped(file) && !_failedFiles.contains(file)) {
          final entry = manifest.fileEntry(file);
          skipped.add(
            FolderSkippedEntry(
              path: manifest.portablePath(entry),
              reason: _unwritableEntries.contains(entry)
                  ? FolderSkipReason.writeFailed
                  : FolderSkipReason.nameCollision,
            ),
          );
        }
      }
    }
    return FolderReceiveSummary(
      filesWritten: _filesWritten,
      filesSkipped: filesSkipped,
      skipped: skipped,
    );
  }

  /// Picks up whatever an earlier attempt left in staging and reports where
  /// the stream should continue from.
  FolderReceiveProgress open() {
    _guard(() {
      Directory(config.stagingPath).createSync(recursive: true);
      final manifest = _loadStoredManifest();
      if (manifest == null) {
        _clearStaging();
        _manifestBuffer = Uint8List(config.manifestLength);
        if (config.manifestLength == 0) {
          throw const FolderManifestException('empty folder manifest');
        }
        return;
      }
      _manifest = manifest;
      // The journal only speaks for a tree that is still there. Without
      // one, for instance after publishing was cut short, every file is
      // checked again instead of being taken as received.
      final treeExists =
          FileSystemEntity.typeSync(_treePath, followLinks: false) ==
          FileSystemEntityType.directory;
      _createDirectories(verifyExisting: true);
      final checkpoint = treeExists ? _loadJournal() : 0;
      _resumeFrom(checkpoint);
      _rewriteJournal();
      _durable = _position;
    });
    return progress;
  }

  /// Consumes the next stretch of the stream.
  void add(Uint8List chunk) {
    _guard(() {
      if (chunk.length > config.streamSize - _position) {
        throw const FolderReceiveException(
          FolderReceiveFailureKind.io,
          'folder stream is longer than announced',
        );
      }
      var index = 0;
      while (index < chunk.length) {
        final manifest = _manifest;
        if (manifest == null) {
          final buffer = _manifestBuffer!;
          final count = math.min(
            chunk.length - index,
            buffer.length - _position,
          );
          buffer.setRange(_position, _position + count, chunk, index);
          index += count;
          _position += count;
          if (_position == buffer.length) _acceptManifest(buffer);
        } else {
          final size = manifest.fileSize(_file);
          if (!_begun) _beginFile(manifest);
          if (_fileReceived < size) {
            final count = math.min(chunk.length - index, size - _fileReceived);
            _writeData(chunk, index, count);
            index += count;
            _fileReceived += count;
            _position += count;
          } else {
            final count = math.min(
              chunk.length - index,
              folderTrailerLength - _trailerFilled,
            );
            _trailer.setRange(
              _trailerFilled,
              _trailerFilled + count,
              chunk,
              index,
            );
            index += count;
            _trailerFilled += count;
            _position += count;
            if (_trailerFilled == folderTrailerLength) _finishFile(manifest);
          }
        }
        _afterStep();
      }
      if (isComplete) checkpoint();
    });
  }

  /// Makes everything written so far the point a restart continues from.
  void checkpoint() {
    _guard(() {
      final settled = _settledPosition;
      if (_manifest != null) {
        _output?.flush();
        _appendJournal(_journalRecordCheckpoint, 0, _settledFile);
        _journal?.flushSync();
      }
      _durable = math.max(_durable, settled);
      _lastCheckpointMs = _clock.elapsedMilliseconds;
      _emitProgress();
    });
  }

  /// Records the outcome of a file handed to [deferred].
  void settleDeferred(int file, {FolderWriteFailure? failure}) {
    _guard(() {
      final entry = _unsettledByFile.remove(file);
      if (entry == null) return;
      entry.settled = true;
      _deferredBytes -= entry.length;
      if (failure == null) {
        _filesWritten += 1;
      } else if (failure.diskFull) {
        throw FolderReceiveException(
          FolderReceiveFailureKind.storage,
          failure.description,
        );
      } else {
        _recordFailure(file, FolderSkipReason.writeFailed);
      }
      while (_unsettled.isNotEmpty && _unsettled.first.settled) {
        _unsettled.removeFirst();
      }
      if (isComplete) {
        checkpoint();
      } else {
        _afterStep();
      }
    });
  }

  /// Takes the checkpoint that has come due while no data was arriving.
  /// Writes finishing on their own do not always add up to one, and a sender
  /// that has filled its window sends nothing until it hears of progress.
  void checkpointIfDue() {
    if (_manifest == null || _settledPosition <= _durable) return;
    if (_clock.elapsedMilliseconds - _lastCheckpointMs >=
        config.checkpointIntervalMs) {
      checkpoint();
    }
  }

  /// Leaves staging ready to be continued later.
  void close() {
    try {
      if (_manifest != null && _journal != null) {
        _output?.flush();
        _appendJournal(_journalRecordCheckpoint, 0, _settledFile);
        _journal?.flushSync();
      }
    } on FileSystemException {
      // A stale checkpoint only costs a longer check on the next start.
    }
    abandon();
  }

  /// Lets go of every open file without recording anything further, which
  /// is where a process that was killed leaves staging: at its last
  /// periodic checkpoint.
  void abandon() {
    try {
      _closeOutput();
    } on FileSystemException {
      // Nothing can be done about it here.
    }
    _digest?.dispose();
    _digest = null;
    try {
      _journal?.closeSync();
    } on FileSystemException {
      // See above.
    }
    _journal = null;
    _files.dispose();
    _held = null;
    _unsettled.clear();
    _unsettledByFile.clear();
    _deferredBytes = 0;
    deferred?.dispose();
  }

  void _afterStep() {
    final now = _clock.elapsedMilliseconds;
    final ahead = _settledPosition - _durable;
    if (ahead > 0 &&
        (now - _lastCheckpointMs >= config.checkpointIntervalMs ||
            ahead >= config.checkpointIntervalBytes)) {
      checkpoint();
    } else if (now - _lastProgressMs >= config.progressIntervalMs) {
      _emitProgress();
    }
  }

  void _emitProgress() {
    _lastProgressMs = _clock.elapsedMilliseconds;
    onProgress?.call(progress);
  }

  FolderManifest? _loadStoredManifest() {
    final file = File(_manifestPath);
    if (FileSystemEntity.typeSync(_manifestPath, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final bytes = file.readAsBytesSync();
    if (bytes.length != config.manifestLength ||
        sha256.convert(bytes).toString() != config.manifestSha256) {
      return null;
    }
    try {
      return _parseManifest(bytes);
    } on FolderManifestException {
      return null;
    }
  }

  FolderManifest _parseManifest(Uint8List bytes) {
    final manifest = FolderManifest.parse(
      bytes,
      pathSeparator: config.pathSeparator,
      caseInsensitiveNames: config.caseInsensitiveNames,
    );
    if (manifest.streamSize != config.streamSize ||
        manifest.fileCount != config.fileCount ||
        manifest.directoryCount != config.directoryCount ||
        manifest.totalFileBytes != config.totalBytes) {
      throw const FolderManifestException(
        'folder manifest does not match its offer',
      );
    }
    return manifest;
  }

  void _acceptManifest(Uint8List bytes) {
    if (sha256.convert(bytes).toString() != config.manifestSha256) {
      throw const FolderManifestException('folder manifest digest mismatch');
    }
    final manifest = _parseManifest(bytes);
    File(_manifestPath).writeAsBytesSync(bytes, flush: true);
    _manifest = manifest;
    _manifestBuffer = null;
    _createDirectories(verifyExisting: false);
    _file = 0;
    _rewriteJournal();
  }

  /// Creates every directory up front, so writing a file never has to check
  /// for its parent. A directory that cannot be created takes everything
  /// under it out of the transfer.
  void _createDirectories({required bool verifyExisting}) {
    final manifest = _manifest!;
    Directory(_treePath).createSync(recursive: true);
    _requireRealDirectory(_treePath);
    for (var entry = 0; entry < manifest.entryCount; entry += 1) {
      final parent = manifest.parentOf(entry);
      if (parent != folderManifestRootParent && manifest.isSkipped(parent)) {
        if (!manifest.isSkipped(entry)) {
          manifest.markSkipped(entry);
          _unwritableEntries.add(entry);
        }
        continue;
      }
      if (!manifest.isDirectory(entry) || manifest.isSkipped(entry)) continue;
      final path = '$_treePath$_separator${manifest.relativePath(entry)}';
      try {
        Directory(path).createSync();
        if (verifyExisting) _requireRealDirectory(path);
      } on FileSystemException catch (error) {
        if (_isDiskFull(error)) rethrow;
        manifest.markSkipped(entry);
      }
    }
  }

  void _requireRealDirectory(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException('folder staging path is not a directory', path);
    }
  }

  void _clearStaging() {
    for (final name in const <String>[
      folderStagingManifestName,
      folderStagingJournalName,
      folderStagingTreeName,
    ]) {
      final path = '${config.stagingPath}$_separator$name';
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type == FileSystemEntityType.directory) {
        Directory(path).deleteSync(recursive: true);
      } else if (type == FileSystemEntityType.link) {
        Link(path).deleteSync();
      } else {
        File(path).deleteSync();
      }
    }
  }

  /// Returns the ordinal every file below which is already settled.
  int _loadJournal() {
    final file = File(_journalPath);
    if (FileSystemEntity.typeSync(_journalPath, followLinks: false) !=
        FileSystemEntityType.file) {
      return 0;
    }
    final bytes = file.readAsBytesSync();
    final header = _journalHeader();
    if (bytes.length < header.length) return 0;
    for (var index = 0; index < header.length; index += 1) {
      if (bytes[index] != header[index]) return 0;
    }
    final manifest = _manifest!;
    final view = ByteData.sublistView(bytes);
    var checkpoint = 0;
    for (
      var offset = header.length;
      offset + _journalRecordLength <= bytes.length;
      offset += _journalRecordLength
    ) {
      final type = view.getUint8(offset);
      final file = view.getUint32(offset + 4);
      if (file > manifest.fileCount) continue;
      if (type == _journalRecordCheckpoint) {
        checkpoint = math.max(checkpoint, file);
      } else if (type == _journalRecordFailed && file < manifest.fileCount) {
        final reason = view.getUint8(offset + 1);
        _failedFiles.add(file);
        _failureReasons[file] = reason < FolderSkipReason.values.length
            ? FolderSkipReason.values[reason]
            : FolderSkipReason.writeFailed;
      }
    }
    return checkpoint;
  }

  /// Works out where the stream continues. Files below [checkpoint] are
  /// settled. After it, a file counts as received when it is on disk at its
  /// full size, with one exception: the last such file may have lost its
  /// trailer to the interruption, so its trailer is asked for again.
  void _resumeFrom(int checkpoint) {
    final manifest = _manifest!;
    var file = checkpoint;
    var lastComplete = -1;
    var partial = 0;
    for (; file < manifest.fileCount; file += 1) {
      if (manifest.isFileSkipped(file) || _failedFiles.contains(file)) continue;
      final path = _pathOfFile(manifest, file);
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) break;
      final size = manifest.fileSize(file);
      final length = type == FileSystemEntityType.file
          ? File(path).lengthSync()
          : -1;
      if (length == size) {
        // A file written away from the stream may have been cut off between
        // its last byte and its date. The last one is settled by its
        // trailer; the ones before it get their date again here.
        if (lastComplete >= 0) _restoreModified(manifest, lastComplete);
        lastComplete = file;
        continue;
      }
      if (length > 0 && length < size) {
        partial = length;
      } else {
        _deleteEntity(path, type);
      }
      break;
    }

    // Anything recorded as failed from here on is received again.
    final resumeFile = lastComplete >= 0 ? lastComplete : file;
    _failedFiles.removeWhere((failed) => failed >= resumeFile);
    _failureReasons.removeWhere((failed, _) => failed >= resumeFile);
    _filesWritten = _countWritten(manifest, resumeFile);

    if (lastComplete >= 0) {
      final size = manifest.fileSize(lastComplete);
      _file = lastComplete;
      _begun = true;
      _fileReceived = size;
      _digest = _digestOfStoredPrefix(manifest, lastComplete, size);
      _position = manifest.trailerStart(lastComplete);
      return;
    }
    _file = file;
    if (file >= manifest.fileCount) {
      _position = config.streamSize;
      return;
    }
    _position = manifest.fileStart(file) + partial;
    if (partial > 0) {
      _begun = true;
      _fileReceived = partial;
      _digest = _digestOfStoredPrefix(manifest, file, partial);
      _output = _files.append(_pathOfFile(manifest, file));
    }
  }

  int _countWritten(FolderManifest manifest, int end) {
    var written = end;
    for (final failed in _failedFiles) {
      if (failed < end) written -= 1;
    }
    if (manifest.skippedFileCount > 0) {
      for (var file = 0; file < end; file += 1) {
        if (manifest.isFileSkipped(file) && !_failedFiles.contains(file)) {
          written -= 1;
        }
      }
    }
    return written;
  }

  FolderFileDigest _digestOfStoredPrefix(
    FolderManifest manifest,
    int file,
    int length,
  ) {
    final digest = FolderFileDigest();
    if (length == 0) return digest;
    final buffer = Uint8List(_rehashBufferSize);
    final handle = File(_pathOfFile(manifest, file)).openSync();
    try {
      var hashed = 0;
      while (hashed < length) {
        final step = handle.readIntoSync(
          buffer,
          0,
          math.min(buffer.length, length - hashed),
        );
        if (step <= 0) {
          throw FileSystemException('stored folder entry ended early');
        }
        digest.add(Uint8List.sublistView(buffer, 0, step));
        hashed += step;
      }
    } catch (_) {
      digest.dispose();
      rethrow;
    } finally {
      handle.closeSync();
    }
    return digest;
  }

  void _beginFile(FolderManifest manifest) {
    _begun = true;
    _fileFailure = null;
    _discarding = manifest.isFileSkipped(_file);
    if (_discarding) return;
    _digest = FolderFileDigest();
    if (deferred != null && manifest.fileSize(_file) <= _deferLimit) {
      _held = Uint8List(manifest.fileSize(_file));
      return;
    }
    try {
      _output = _files.create(_pathOfFile(manifest, _file));
    } on FileSystemException catch (error) {
      if (_isDiskFull(error)) rethrow;
      _abandonCurrent(FolderSkipReason.writeFailed);
    }
  }

  void _writeData(Uint8List chunk, int start, int count) {
    if (_discarding) return;
    _digest!.add(Uint8List.sublistView(chunk, start, start + count));
    final held = _held;
    if (held != null) {
      held.setRange(_fileReceived, _fileReceived + count, chunk, start);
      return;
    }
    try {
      _output!.write(chunk, start, start + count);
    } on FileSystemException catch (error) {
      if (_isDiskFull(error)) rethrow;
      _abandonCurrent(FolderSkipReason.writeFailed);
    }
  }

  void _finishFile(FolderManifest manifest) {
    final file = _file;
    if (_discarding) {
      final failure = _fileFailure;
      if (failure != null) _recordFailure(file, failure);
    } else if (_trailer[0] != folderTrailerStatusOk) {
      _abandonCurrent(FolderSkipReason.sourceUnavailable);
      _recordFailure(file, FolderSkipReason.sourceUnavailable);
    } else {
      final digest = _digest!.close();
      _digest = null;
      var matches = true;
      for (var index = 0; index < folderTrailerDigestLength; index += 1) {
        if (digest[index] != _trailer[index + 1]) {
          matches = false;
          break;
        }
      }
      final held = _held;
      if (!matches) {
        _abandonCurrent(FolderSkipReason.integrity);
        _recordFailure(file, FolderSkipReason.integrity);
      } else if (held != null) {
        _held = null;
        _defer(manifest, file, held);
      } else {
        _settleVerifiedFile(manifest, file);
        _filesWritten += 1;
      }
    }
    _file = file + 1;
    _begun = false;
    _discarding = false;
    _fileFailure = null;
    _fileReceived = 0;
    _trailerFilled = 0;
  }

  /// Closes a file whose trailer matched, leaving it with the modification
  /// time from the manifest. The time goes on through the handle the file
  /// was written with wherever there is one; see [FolderFileWriter].
  void _settleVerifiedFile(FolderManifest manifest, int file) {
    final modifiedMs = manifest.fileModifiedMs(file);
    final output = _output;
    if (output != null) {
      _output = null;
      output.close(modifiedMs: modifiedMs);
      return;
    }
    // Only a file whose bytes were all there before an interruption gets
    // here: it is already closed, and waited just for its trailer.
    _restoreModified(manifest, file);
  }

  void _restoreModified(FolderManifest manifest, int file) {
    final modifiedMs = manifest.fileModifiedMs(file);
    if (modifiedMs <= 0) return;
    try {
      File(
        _pathOfFile(manifest, file),
      ).setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(modifiedMs));
    } on FileSystemException {
      // The file is complete; only its timestamp is off.
    }
  }

  /// Hands a checked file over to be written away from the stream.
  void _defer(FolderManifest manifest, int file, Uint8List bytes) {
    final entry = _DeferredEntry(file, bytes.length);
    _unsettled.add(entry);
    _unsettledByFile[file] = entry;
    _deferredBytes += bytes.length;
    deferred!.write(
      FolderDeferredFile(
        file: file,
        path: _pathOfFile(manifest, file),
        bytes: bytes,
        modifiedMs: manifest.fileModifiedMs(file),
      ),
    );
  }

  /// Stops writing the current file and removes what there is of it; the
  /// rest of its bytes are read past. That goes for a file left by an
  /// earlier attempt too, which a gathered file has not replaced yet.
  void _abandonCurrent(FolderSkipReason reason) {
    _discarding = true;
    _fileFailure = reason;
    _digest?.dispose();
    _digest = null;
    _held = null;
    _closeOutput();
    final path = _pathOfFile(_manifest!, _file);
    try {
      _deleteEntity(path, FileSystemEntity.typeSync(path, followLinks: false));
    } on FileSystemException {
      // Left behind at worst; it is still reported as not transferred.
    }
  }

  void _recordFailure(int file, FolderSkipReason reason) {
    if (!_failedFiles.add(file)) return;
    _failureReasons[file] = reason;
    _appendJournal(_journalRecordFailed, reason.index, file);
  }

  void _closeOutput() {
    final output = _output;
    _output = null;
    if (output == null) return;
    try {
      output.close();
    } on FileSystemException catch (error) {
      if (_isDiskFull(error)) rethrow;
    }
  }

  void _deleteEntity(String path, FileSystemEntityType type) {
    switch (type) {
      case FileSystemEntityType.notFound:
        return;
      case FileSystemEntityType.directory:
        Directory(path).deleteSync(recursive: true);
      case FileSystemEntityType.link:
        Link(path).deleteSync();
      default:
        File(path).deleteSync();
    }
  }

  String _pathOfFile(FolderManifest manifest, int file) =>
      '$_treePath$_separator'
      '${manifest.relativePath(manifest.fileEntry(file))}';

  Uint8List _journalHeader() {
    final header = Uint8List(_journalHeaderLength)
      ..[0] = 0x57
      ..[1] = 0x46
      ..[2] = 0x4a
      ..[3] = 0x31;
    final digest = config.manifestSha256;
    for (var index = 0; index < 32; index += 1) {
      header[4 + index] = int.parse(
        digest.substring(index * 2, index * 2 + 2),
        radix: 16,
      );
    }
    return header;
  }

  /// Starts the journal over with what is still true after a resume.
  void _rewriteJournal() {
    try {
      _journal?.closeSync();
    } on FileSystemException {
      // Replaced below.
    }
    final journal = File(_journalPath).openSync(mode: FileMode.writeOnly);
    _journal = journal;
    journal.writeFromSync(_journalHeader());
    for (final file in _failedFiles) {
      _appendJournal(
        _journalRecordFailed,
        (_failureReasons[file] ?? FolderSkipReason.writeFailed).index,
        file,
      );
    }
    _appendJournal(_journalRecordCheckpoint, 0, _file);
    journal.flushSync();
  }

  void _appendJournal(int type, int detail, int file) {
    final journal = _journal;
    if (journal == null) return;
    final record = ByteData(_journalRecordLength)
      ..setUint8(0, type)
      ..setUint8(1, detail)
      ..setUint32(4, file);
    journal.writeFromSync(record.buffer.asUint8List());
  }

  void _guard(void Function() body) {
    try {
      body();
    } on FolderReceiveException {
      rethrow;
    } on FolderManifestException catch (error) {
      throw FolderReceiveException(
        FolderReceiveFailureKind.manifest,
        error.message,
      );
    } on FileSystemException catch (error) {
      throw FolderReceiveException(
        _isDiskFull(error)
            ? FolderReceiveFailureKind.storage
            : FolderReceiveFailureKind.io,
        error.osError?.message ?? error.message,
      );
    }
  }
}

bool _isDiskFull(FileSystemException error) => folderWriteHitFullDisk(error);

final class _DeferredEntry {
  _DeferredEntry(this.file, this.length);

  final int file;
  final int length;
  bool settled = false;
}

/// The receiving end of a folder transfer as the engine sees it. Payloads go
/// to a worker isolate that does the writing; progress and the outcome come
/// back as events.
final class FolderReceiveSession {
  FolderReceiveSession._({
    required Isolate isolate,
    required SendPort commands,
    required ReceivePort events,
    required this.resume,
  }) : _isolate = isolate,
       _commands = commands,
       _events = events,
       _latest = resume {
    // Closing a session early fails this future; that must not surface as
    // an unhandled error when nobody is waiting on it.
    unawaited(
      _finished.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  /// At most this much is with the worker at a time. The rest waits here, so
  /// closing never has to sit behind a long backlog of small files.
  static const int _maxInFlightBytes = 1024 * 1024;
  static const int _sliceBytes = 256 * 1024;
  static const Duration _closeTimeout = Duration(seconds: 15);

  static Future<FolderReceiveSession> start(FolderReceiveConfig config) async {
    final events = ReceivePort();
    final opened = Completer<List<Object?>>();
    FolderReceiveSession? session;
    events.listen((message) {
      if (!opened.isCompleted) {
        if (message is List<Object?> && message.first == 'opened') {
          opened.complete(message);
        } else {
          opened.completeError(_failureFrom(message));
        }
        return;
      }
      session?._handle(message);
    });
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn<(SendPort, FolderReceiveConfig)>(
        _folderReceiveWorker,
        (events.sendPort, config),
        onError: events.sendPort,
        onExit: events.sendPort,
        errorsAreFatal: true,
      );
    } catch (_) {
      events.close();
      rethrow;
    }
    try {
      final message = await opened.future;
      return session = FolderReceiveSession._(
        isolate: isolate,
        commands: message[1]! as SendPort,
        events: events,
        resume: _progressFrom(message[2]),
      );
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      events.close();
      rethrow;
    }
  }

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _events;

  /// Where the stream continues from, as found in staging.
  final FolderReceiveProgress resume;
  final Queue<Uint8List> _queued = Queue<Uint8List>();
  final Completer<FolderReceiveSummary> _finished =
      Completer<FolderReceiveSummary>();
  final Completer<void> _exited = Completer<void>();
  FolderReceiveProgress _latest;
  int _inFlight = 0;
  bool _closing = false;

  void Function(FolderReceiveProgress progress)? onProgress;

  FolderReceiveProgress get latest => _latest;

  /// Completes once the whole stream has been written, or fails with a
  /// [FolderReceiveException] when the transfer cannot go on.
  Future<FolderReceiveSummary> get finished => _finished.future;

  void add(Uint8List payload) {
    if (_closing || payload.isEmpty) return;
    for (var start = 0; start < payload.length; start += _sliceBytes) {
      _queued.add(
        Uint8List.sublistView(
          payload,
          start,
          math.min(payload.length, start + _sliceBytes),
        ),
      );
    }
    _pump();
  }

  /// Stops the worker and waits for it to let go of its files. Staging stays
  /// as it is, ready to be continued or removed by the caller.
  Future<void> close() async {
    if (!_closing) {
      _closing = true;
      _queued.clear();
      _commands.send(const <Object?>['close']);
    }
    try {
      await _exited.future.timeout(_closeTimeout);
    } on TimeoutException {
      _isolate.kill(priority: Isolate.immediate);
      _finish();
    }
  }

  void _pump() {
    while (_queued.isNotEmpty && _inFlight < _maxInFlightBytes) {
      final slice = _queued.removeFirst();
      _inFlight += slice.length;
      _commands.send(<Object?>[
        'data',
        TransferableTypedData.fromList(<TypedData>[slice]),
      ]);
    }
  }

  void _handle(Object? message) {
    if (message is List<Object?> && message.isNotEmpty) {
      switch (message.first) {
        case 'consumed':
          _inFlight -= message[1]! as int;
          if (!_closing) _pump();
          return;
        case 'progress':
          _latest = _progressFrom(message[1]);
          if (!_closing) onProgress?.call(_latest);
          return;
        case 'finished':
          _latest = _progressFrom(message[1]);
          if (!_finished.isCompleted) {
            _finished.complete(
              FolderReceiveSummary(
                filesWritten: _latest.filesWritten,
                filesSkipped: _latest.filesSkipped,
                skipped: <FolderSkippedEntry>[
                  for (final item in message[2]! as List<Object?>)
                    ?FolderSkippedEntry.tryFromJson(item),
                ],
              ),
            );
          }
          return;
      }
    }
    // An error report, or the worker leaving.
    if (!_finished.isCompleted) {
      _finished.completeError(_failureFrom(message));
    }
    if (message == null) _finish();
  }

  void _finish() {
    if (!_finished.isCompleted) {
      _finished.completeError(_failureFrom(null));
    }
    if (!_exited.isCompleted) {
      _exited.complete();
      _events.close();
    }
  }
}

List<int> _progressToWire(FolderReceiveProgress progress) => <int>[
  progress.processedOffset,
  progress.durableOffset,
  progress.filesWritten,
  progress.filesSkipped,
  progress.filesSettled,
];

FolderReceiveProgress _progressFrom(Object? wire) {
  final values = (wire! as List<Object?>).cast<int>();
  return FolderReceiveProgress(
    processedOffset: values[0],
    durableOffset: values[1],
    filesWritten: values[2],
    filesSkipped: values[3],
    filesSettled: values[4],
  );
}

FolderReceiveException _failureFrom(Object? message) {
  if (message is List<Object?> &&
      message.length >= 3 &&
      message.first == 'error') {
    return FolderReceiveException(
      FolderReceiveFailureKind.values.byName(message[1]! as String),
      message[2]! as String,
    );
  }
  return const FolderReceiveException(
    FolderReceiveFailureKind.io,
    'folder receive worker stopped',
  );
}

/// With this much waiting to be written, the worker stops asking for more
/// of the stream until the files in hand are on disk.
const int _maxDeferredBytes = 8 * 1024 * 1024;
const int _maxDeferredFiles = 4096;

void _folderReceiveWorker((SendPort, FolderReceiveConfig) bootstrap) {
  final (events, config) = bootstrap;
  final commands = ReceivePort();
  late final FolderStreamWriter writer;
  Timer? ticker;
  var stopped = false;
  var finished = false;
  // Stretches of the stream that are read but not answered for yet.
  var unanswered = 0;

  void reportFinished() {
    if (finished || !writer.isComplete) return;
    finished = true;
    ticker?.cancel();
    final summary = writer.summary;
    events.send(<Object?>[
      'finished',
      _progressToWire(writer.progress),
      <Object?>[for (final entry in summary.skipped) entry.toJson()],
    ]);
  }

  void answerConsumed() {
    if (unanswered == 0 ||
        writer.deferredBytes > _maxDeferredBytes ||
        writer.deferredFiles > _maxDeferredFiles) {
      return;
    }
    events.send(<Object?>['consumed', unanswered]);
    unanswered = 0;
  }

  void stop() {
    stopped = true;
    ticker?.cancel();
    writer.close();
    commands.close();
  }

  void fail(Object error) {
    if (stopped) return;
    stop();
    final failure = error is FolderReceiveException
        ? error
        : FolderReceiveException(
            FolderReceiveFailureKind.io,
            error.runtimeType.toString(),
          );
    events.send(<Object?>['error', failure.kind.name, failure.description]);
  }

  /// Runs what follows a file reaching the disk away from the stream.
  void afterDeferred(void Function() body) {
    if (stopped) return;
    try {
      body();
      answerConsumed();
      reportFinished();
    } on Object catch (error) {
      fail(error);
    }
  }

  final pool = config.writeWorkers > 0
      ? FolderWritePool(
          workers: config.writeWorkers,
          onSettled: (file, failure) => afterDeferred(
            () => writer.settleDeferred(file, failure: failure),
          ),
          onBroken: (description) => fail(
            FolderReceiveException(FolderReceiveFailureKind.io, description),
          ),
        )
      : null;
  writer = FolderStreamWriter(
    config,
    onProgress: (progress) =>
        events.send(<Object?>['progress', _progressToWire(progress)]),
    deferred: pool,
  );

  try {
    final resume = writer.open();
    events.send(<Object?>[
      'opened',
      commands.sendPort,
      _progressToWire(resume),
    ]);
    reportFinished();
  } on Object catch (error) {
    fail(error);
    return;
  }
  if (pool != null && !finished) {
    ticker = Timer.periodic(
      Duration(milliseconds: math.max(50, config.checkpointIntervalMs)),
      (_) => afterDeferred(writer.checkpointIfDue),
    );
  }

  commands.listen((message) {
    if (stopped) return;
    try {
      final command = message as List<Object?>;
      switch (command.first) {
        case 'data':
          final bytes = (command[1]! as TransferableTypedData)
              .materialize()
              .asUint8List();
          writer.add(bytes);
          unanswered += bytes.length;
          answerConsumed();
          reportFinished();
        case 'close':
          stop();
        default:
          throw const FormatException('unknown folder receive command');
      }
    } on Object catch (error) {
      fail(error);
    }
  });
}
