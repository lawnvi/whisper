import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:synchronized/synchronized.dart';
import 'package:whisper/socket/file_transfer_source.dart';
import 'package:whisper/socket/folder_transfer_digest.dart';
import 'package:whisper/socket/folder_transfer_manifest.dart';

const int _catchUpBufferSize = 1024 * 1024;

/// Reads a folder as the byte stream its manifest describes. Blocking: lives
/// in the worker isolate of [FolderTransferSource].
///
/// A file that cannot be read, or whose size no longer matches the manifest,
/// does not stop the stream: its bytes go out as zeros and its trailer says
/// it is unavailable, so the other side drops that one file and carries on.
final class FolderStreamReader {
  FolderStreamReader({required this.rootPath, required this.manifest})
    : _rootPrefix = rootPath.endsWith(manifest.pathSeparator)
          ? rootPath
          : '$rootPath${manifest.pathSeparator}',
      _trailers = Uint8List(manifest.fileCount * folderTrailerLength),
      _trailerKnown = Uint8List(manifest.fileCount);

  final String rootPath;
  final FolderManifest manifest;
  final String _rootPrefix;

  /// Every trailer computed so far, so going back over part of the stream
  /// never means hashing a finished file again.
  final Uint8List _trailers;
  final Uint8List _trailerKnown;
  final List<int> _newlyUnavailable = <int>[];
  final Uint8List _catchUpBuffer = Uint8List(_catchUpBufferSize);

  int _file = -1;
  RandomAccessFile? _handle;
  int _position = 0;
  bool _unavailable = false;
  FolderFileDigest? _digest;

  /// How far into the current file the digest has got.
  int _hashed = 0;

  String pathOfFile(int file) =>
      '$_rootPrefix${manifest.relativePath(manifest.fileEntry(file))}';

  /// Files found unavailable since the last call.
  List<int> takeUnavailableFiles() {
    final files = List<int>.of(_newlyUnavailable);
    _newlyUnavailable.clear();
    return files;
  }

  void fill(
    Uint8List destination,
    int destinationOffset,
    int streamOffset,
    int length,
  ) {
    if (streamOffset < 0 ||
        length < 0 ||
        streamOffset + length > manifest.streamSize) {
      throw RangeError('folder stream range is out of bounds');
    }
    var written = 0;
    while (written < length) {
      final offset = streamOffset + written;
      final remaining = length - written;
      final target = destinationOffset + written;
      if (offset < manifest.manifestLength) {
        final count = math.min(remaining, manifest.manifestLength - offset);
        destination.setRange(target, target + count, manifest.bytes, offset);
        written += count;
        continue;
      }
      final file = manifest.fileAt(offset);
      final size = manifest.fileSize(file);
      final relative = offset - manifest.fileStart(file);
      if (relative < size) {
        final count = math.min(remaining, size - relative);
        _readData(file, size, relative, destination, target, count);
        written += count;
      } else {
        final trailerOffset = relative - size;
        final count = math.min(remaining, folderTrailerLength - trailerOffset);
        _ensureTrailer(file, size);
        final start = file * folderTrailerLength + trailerOffset;
        destination.setRange(target, target + count, _trailers, start);
        written += count;
      }
    }
  }

  void close() {
    _closeCurrent();
    _file = -1;
  }

  void _readData(
    int file,
    int size,
    int relative,
    Uint8List destination,
    int target,
    int count,
  ) {
    _select(file, size);
    if (!_unavailable) {
      try {
        if (relative > _hashed) _hashThrough(file, relative);
      } on FileSystemException {
        _markUnavailable(file);
      }
    }
    if (_unavailable) {
      destination.fillRange(target, target + count, 0);
      return;
    }
    final handle = _handle!;
    var read = 0;
    try {
      if (_position != relative) {
        handle.setPositionSync(relative);
        _position = relative;
      }
      while (read < count) {
        final step = handle.readIntoSync(
          destination,
          target + read,
          target + count,
        );
        if (step <= 0) break;
        read += step;
      }
    } on FileSystemException {
      read = -1;
    }
    if (read != count) {
      _markUnavailable(file);
      destination.fillRange(target, target + count, 0);
      return;
    }
    _position += count;
    if (relative == _hashed) {
      (_digest ??= FolderFileDigest()).add(
        Uint8List.sublistView(destination, target, target + count),
      );
      _hashed += count;
      if (_hashed == size) _completeTrailer(file);
    }
  }

  void _ensureTrailer(int file, int size) {
    if (_trailerKnown[file] != 0) return;
    _select(file, size);
    if (_unavailable) return;
    try {
      _hashThrough(file, size);
    } on FileSystemException {
      _markUnavailable(file);
      return;
    }
    if (!_unavailable) _completeTrailer(file);
  }

  /// Makes [file] the open file. A file whose trailer is already known is
  /// opened only to be read again; its digest is not restarted.
  void _select(int file, int size) {
    if (_file == file && (_handle != null || _unavailable)) return;
    if (_file != file) {
      _closeCurrent();
      _file = file;
    }
    final known = _trailerKnown[file] != 0;
    if (known &&
        _trailers[file * folderTrailerLength] != folderTrailerStatusOk) {
      _unavailable = true;
      return;
    }
    _unavailable = false;
    _hashed = known ? size : 0;
    final path = pathOfFile(file);
    try {
      // A link swapped in after the scan must not lead out of the folder.
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw FileSystemException('folder entry is not a regular file', path);
      }
      final handle = File(path).openSync();
      if (handle.lengthSync() != size) {
        handle.closeSync();
        throw FileSystemException('folder entry changed size', path);
      }
      _handle = handle;
      _position = 0;
    } on FileSystemException {
      if (!Directory(rootPath).existsSync()) {
        throw FileSystemException('folder is no longer available', rootPath);
      }
      _markUnavailable(file);
    }
  }

  /// Feeds the digest the bytes of the current file up to [end], for a read
  /// that starts past them (a resumed transfer) or needs the whole digest.
  void _hashThrough(int file, int end) {
    if (_hashed >= end) return;
    final handle = _handle!;
    if (_position != _hashed) {
      handle.setPositionSync(_hashed);
      _position = _hashed;
    }
    final digest = _digest ??= FolderFileDigest();
    while (_hashed < end) {
      final want = math.min(_catchUpBuffer.length, end - _hashed);
      final step = handle.readIntoSync(_catchUpBuffer, 0, want);
      if (step <= 0) {
        throw FileSystemException('folder entry ended early', pathOfFile(file));
      }
      digest.add(Uint8List.sublistView(_catchUpBuffer, 0, step));
      _hashed += step;
      _position += step;
    }
  }

  void _completeTrailer(int file) {
    final digest = (_digest ?? FolderFileDigest()).close();
    _digest = null;
    final start = file * folderTrailerLength;
    _trailers[start] = folderTrailerStatusOk;
    _trailers.setRange(start + 1, start + folderTrailerLength, digest);
    _trailerKnown[file] = 1;
    _closeHandle();
  }

  void _markUnavailable(int file) {
    final start = file * folderTrailerLength;
    final alreadyReported =
        _trailerKnown[file] != 0 &&
        _trailers[start] == folderTrailerStatusUnavailable;
    _trailers[start] = folderTrailerStatusUnavailable;
    _trailers.fillRange(start + 1, start + folderTrailerLength, 0);
    _trailerKnown[file] = 1;
    if (!alreadyReported) _newlyUnavailable.add(file);
    _unavailable = true;
    _digest?.dispose();
    _digest = null;
    _closeHandle();
  }

  void _closeCurrent() {
    _digest?.dispose();
    _digest = null;
    _closeHandle();
    _unavailable = false;
    _hashed = 0;
  }

  void _closeHandle() {
    final handle = _handle;
    _handle = null;
    _position = 0;
    if (handle == null) return;
    try {
      handle.closeSync();
    } on FileSystemException {
      // Nothing was written through this handle.
    }
  }
}

/// A folder exposed to the transfer engine as one source. The reading and
/// hashing happen in a worker isolate, so a tree of many small files does not
/// stall the UI isolate with thousands of file operations per frame.
final class FolderTransferSource
    implements FileTransferSource, DirectReadFileTransferSource {
  FolderTransferSource({
    required this.rootPath,
    required Future<String> Function() manifestPath,
    required this.manifestSha256,
    required this.expectedSize,
  }) : _manifestPath = manifestPath;

  final String rootPath;

  /// Where the manifest scanned for this transfer is kept.
  final Future<String> Function() _manifestPath;
  final String manifestSha256;
  final int expectedSize;

  final Lock _requests = Lock();
  final Set<int> _unavailableFiles = <int>{};
  Future<_FolderSourceWorker>? _worker;
  Int64List? _fileStarts;
  bool _closed = false;

  /// How many files lie wholly before [streamOffset], or null until the
  /// worker has read the manifest.
  int? filesBefore(int streamOffset) {
    final starts = _fileStarts;
    if (starts == null) return null;
    // The number of starts at or below the offset, less the one that opens
    // the file still under way.
    var low = 0;
    var high = starts.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (starts[middle] <= streamOffset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low == 0 ? 0 : low - 1;
  }

  /// How many files have gone out marked unavailable so far.
  int get unavailableFileCount => _unavailableFiles.length;

  @override
  Future<bool> exists() async =>
      await Directory(rootPath).exists() &&
      await File(await _manifestPath()).exists();

  @override
  Future<int> length() async => (await _ensureWorker()).streamSize;

  @override
  Future<Uint8List> readRange(int offset, int length) async {
    final bytes = Uint8List(length);
    await readRangeInto(
      bytes,
      destinationOffset: 0,
      sourceOffset: offset,
      length: length,
    );
    return bytes;
  }

  @override
  Future<int> readRangeInto(
    Uint8List destination, {
    required int destinationOffset,
    required int sourceOffset,
    required int length,
  }) async {
    final worker = await _ensureWorker();
    final reply = await _requests.synchronized(
      () => worker.request(<Object?>['read', sourceOffset, length]),
    );
    final bytes = (reply[0]! as TransferableTypedData)
        .materialize()
        .asUint8List();
    destination.setRange(
      destinationOffset,
      destinationOffset + bytes.length,
      bytes,
    );
    _unavailableFiles.addAll((reply[1]! as List<Object?>).cast<int>());
    return bytes.length;
  }

  /// The files that went out marked unavailable, by path, up to [limit].
  Future<List<FolderSkippedEntry>> unavailableEntries({
    required int limit,
  }) async {
    if (_unavailableFiles.isEmpty || _closed) {
      return const <FolderSkippedEntry>[];
    }
    final files = (_unavailableFiles.toList()..sort())
        .take(limit)
        .toList(growable: false);
    final worker = await _ensureWorker();
    final reply = await _requests.synchronized(
      () => worker.request(<Object?>['paths', files]),
    );
    return <FolderSkippedEntry>[
      for (final path in (reply[0]! as List<Object?>).cast<String>())
        FolderSkippedEntry(
          path: path,
          reason: FolderSkipReason.sourceUnavailable,
        ),
    ];
  }

  @override
  Future<void> close() async {
    _closed = true;
    final worker = _worker;
    _worker = null;
    if (worker == null) return;
    try {
      (await worker).close();
    } on Object {
      // A worker that never started has nothing to release.
    }
  }

  Future<_FolderSourceWorker> _ensureWorker() {
    if (_closed) {
      throw const FileSystemException('folder transfer source is closed');
    }
    return _worker ??= _manifestPath().then((manifestPath) async {
      final worker = await _FolderSourceWorker.start(
        rootPath: rootPath,
        manifestPath: manifestPath,
        manifestSha256: manifestSha256,
        expectedSize: expectedSize,
      );
      _fileStarts = worker.fileStarts;
      return worker;
    });
  }
}

final class _FolderSourceWorker {
  _FolderSourceWorker._({
    required SendPort commands,
    required ReceivePort events,
    required this.streamSize,
    required this.fileStarts,
  }) : _commands = commands,
       _events = events;

  static Future<_FolderSourceWorker> start({
    required String rootPath,
    required String manifestPath,
    required String manifestSha256,
    required int expectedSize,
  }) async {
    final events = ReceivePort();
    final ready = Completer<List<Object?>>();
    _FolderSourceWorker? worker;
    events.listen((message) {
      if (!ready.isCompleted) {
        if (message is List<Object?> && message.first == 'ready') {
          ready.complete(message);
        } else {
          ready.completeError(
            FileSystemException(_describeWorkerFailure(message), rootPath),
          );
        }
        return;
      }
      worker?._handle(message);
    });
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn<List<Object?>>(
        _folderSourceWorker,
        <Object?>[
          events.sendPort,
          rootPath,
          manifestPath,
          manifestSha256,
          expectedSize,
          Platform.pathSeparator,
        ],
        onError: events.sendPort,
        onExit: events.sendPort,
        errorsAreFatal: true,
      );
    } catch (_) {
      events.close();
      rethrow;
    }
    try {
      final message = await ready.future;
      return worker = _FolderSourceWorker._(
        commands: message[1]! as SendPort,
        events: events,
        streamSize: message[2]! as int,
        fileStarts: (message[3]! as TransferableTypedData)
            .materialize()
            .asInt64List(),
      );
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      events.close();
      rethrow;
    }
  }

  final SendPort _commands;
  final ReceivePort _events;
  final int streamSize;
  final Int64List fileStarts;
  Completer<List<Object?>>? _pending;
  Object? _failure;

  Future<List<Object?>> request(List<Object?> command) {
    final failure = _failure;
    if (failure != null) return Future<List<Object?>>.error(failure);
    final pending = _pending = Completer<List<Object?>>();
    _commands.send(command);
    return pending.future;
  }

  void close() {
    _fail(const FileSystemException('folder transfer source is closed'));
    // The worker leaves on its own once it has closed the file it holds.
    _commands.send(const <Object?>['close']);
    _events.close();
  }

  void _handle(Object? message) {
    if (message is List<Object?> &&
        message.isNotEmpty &&
        message.first == 'reply') {
      final pending = _pending;
      _pending = null;
      pending?.complete(message.sublist(1));
      return;
    }
    _fail(FileSystemException(_describeWorkerFailure(message)));
  }

  void _fail(Object error) {
    _failure ??= error;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error);
    }
  }
}

String _describeWorkerFailure(Object? message) {
  if (message is List<Object?> &&
      message.length >= 2 &&
      message[0] == 'error') {
    return 'folder transfer source failed: ${message[1]}';
  }
  return 'folder transfer source stopped';
}

void _folderSourceWorker(List<Object?> bootstrap) {
  final events = bootstrap[0]! as SendPort;
  final rootPath = bootstrap[1]! as String;
  final manifestPath = bootstrap[2]! as String;
  final manifestSha256 = bootstrap[3]! as String;
  final expectedSize = bootstrap[4]! as int;
  final pathSeparator = bootstrap[5]! as String;
  final commands = ReceivePort();
  FolderStreamReader? reader;
  void fail(Object error) {
    reader?.close();
    events.send(<Object?>['error', error.runtimeType.toString()]);
    commands.close();
  }

  try {
    final bytes = File(manifestPath).readAsBytesSync();
    if (sha256.convert(bytes).toString() != manifestSha256) {
      throw const FileSystemException('folder manifest changed');
    }
    final manifest = FolderManifest.parse(bytes, pathSeparator: pathSeparator);
    if (manifest.streamSize != expectedSize ||
        !Directory(rootPath).existsSync()) {
      throw const FileSystemException('folder no longer matches its manifest');
    }
    reader = FolderStreamReader(rootPath: rootPath, manifest: manifest);
    events.send(<Object?>[
      'ready',
      commands.sendPort,
      manifest.streamSize,
      TransferableTypedData.fromList(<TypedData>[manifest.fileStarts]),
    ]);
  } on Object catch (error) {
    fail(error);
    return;
  }

  final activeReader = reader;
  commands.listen((message) {
    try {
      final command = message as List<Object?>;
      switch (command.first) {
        case 'read':
          final length = command[2]! as int;
          final buffer = Uint8List(length);
          activeReader.fill(buffer, 0, command[1]! as int, length);
          events.send(<Object?>[
            'reply',
            TransferableTypedData.fromList(<TypedData>[buffer]),
            activeReader.takeUnavailableFiles(),
          ]);
        case 'paths':
          events.send(<Object?>[
            'reply',
            <String>[
              for (final file in (command[1]! as List<Object?>).cast<int>())
                activeReader.manifest.portablePath(
                  activeReader.manifest.fileEntry(file),
                ),
            ],
          ]);
        case 'close':
          activeReader.close();
          commands.close();
        default:
          throw const FormatException('unknown folder source command');
      }
    } on Object catch (error) {
      fail(error);
    }
  });
}
