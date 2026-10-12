import 'dart:convert';
import 'dart:typed_data';

import 'package:whisper/socket/transfer_file_name.dart';

/// A folder travels as one byte stream through the file-transfer engine:
///
///     manifest | file 0 data | trailer 0 | file 1 data | trailer 1 | ...
///
/// The manifest lists every directory and file up front, so both sides know
/// the stream length and where each file sits in it before any data moves.
/// A trailer closes each file: one status byte, then that file's SHA-256.
const int folderManifestHeaderLength = 20;
const int folderManifestRootParent = 0xFFFFFFFF;
const int folderManifestMaxEntries = 500000;
const int folderManifestMaxBytes = 64 * 1024 * 1024;
const int folderManifestMaxDepth = 64;
const int folderManifestMaxPathBytes = 4096;
const int folderManifestMaxFileSize = 100 * 1024 * 1024 * 1024;
const int folderStreamMaxSize = 1024 * 1024 * 1024 * 1024;

const int folderTrailerLength = 33;
const int folderTrailerDigestLength = 32;
const int folderTrailerStatusOk = 0;
const int folderTrailerStatusUnavailable = 1;

const int _magic0 = 0x57; // W
const int _magic1 = 0x46; // F
const int _magic2 = 0x4d; // M
const int _magic3 = 0x31; // 1
const int _kindDirectory = 0;
const int _kindFile = 1;
const int _entryFixedLength = 7;
const int _fileFieldsLength = 16;
const int _maxModifiedMs = 9007199254740991;

final class FolderManifestException extends FormatException {
  const FolderManifestException(super.message);
}

/// Why an entry of a folder did not reach the other side.
enum FolderSkipReason {
  symlink,
  special,
  invalidName,
  pathTooLong,
  tooLarge,
  unreadable,
  sourceUnavailable,
  writeFailed,
  nameCollision,
  integrity;

  static FolderSkipReason? tryParse(Object? name) {
    for (final value in FolderSkipReason.values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

final class FolderSkippedEntry {
  const FolderSkippedEntry({required this.path, required this.reason});

  /// Relative to the folder being transferred, with `/` between segments.
  final String path;
  final FolderSkipReason reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'reason': reason.name,
  };

  static FolderSkippedEntry? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    final reason = FolderSkipReason.tryParse(json['reason']);
    if (path is! String || path.isEmpty || reason == null) return null;
    return FolderSkippedEntry(path: path, reason: reason);
  }
}

/// Orders sibling names the way the manifest requires: by UTF-8 bytes.
int compareFolderEntryNames(Uint8List first, Uint8List second) {
  final shared = first.length < second.length ? first.length : second.length;
  for (var index = 0; index < shared; index += 1) {
    final difference = first[index] - second[index];
    if (difference != 0) return difference;
  }
  return first.length - second.length;
}

/// Writes a manifest. Entries must arrive one directory at a time, parents
/// before their children and siblings in [compareFolderEntryNames] order;
/// [FolderManifest.parse] rejects anything else.
final class FolderManifestBuilder {
  final BytesBuilder _entries = BytesBuilder(copy: false);
  int _entryCount = 0;
  int _fileCount = 0;
  int _totalFileBytes = 0;

  int get entryCount => _entryCount;
  int get fileCount => _fileCount;
  int get directoryCount => _entryCount - _fileCount;
  int get totalFileBytes => _totalFileBytes;

  int get manifestLength => folderManifestHeaderLength + _entries.length;

  /// The stream length this manifest would describe if built now.
  int get streamSize =>
      manifestLength + _totalFileBytes + _fileCount * folderTrailerLength;

  int addDirectory({required int parent, required Uint8List name}) {
    _addCommon(_kindDirectory, parent, name);
    return _entryCount++;
  }

  int addFile({
    required int parent,
    required Uint8List name,
    required int size,
    required int modifiedMs,
  }) {
    _addCommon(_kindFile, parent, name);
    final fields = ByteData(_fileFieldsLength)
      ..setUint64(0, size)
      ..setUint64(8, modifiedMs.clamp(0, _maxModifiedMs));
    _entries.add(fields.buffer.asUint8List());
    _fileCount += 1;
    _totalFileBytes += size;
    return _entryCount++;
  }

  void _addCommon(int kind, int parent, Uint8List name) {
    final fixed = ByteData(_entryFixedLength)
      ..setUint8(0, kind)
      ..setUint32(1, parent)
      ..setUint16(5, name.length);
    _entries
      ..add(fixed.buffer.asUint8List())
      ..add(name);
  }

  Uint8List build() {
    final entries = _entries.toBytes();
    final bytes = Uint8List(folderManifestHeaderLength + entries.length);
    bytes
      ..[0] = _magic0
      ..[1] = _magic1
      ..[2] = _magic2
      ..[3] = _magic3;
    ByteData.sublistView(bytes)
      ..setUint32(4, _entryCount)
      ..setUint32(8, _fileCount)
      ..setUint64(12, _totalFileBytes);
    bytes.setRange(folderManifestHeaderLength, bytes.length, entries);
    return bytes;
  }
}

/// A validated manifest, kept as the bytes it arrived in. Names are decoded
/// on demand so half a million entries stay a few dozen megabytes.
final class FolderManifest {
  FolderManifest._({
    required this.bytes,
    required this.pathSeparator,
    required this.totalFileBytes,
    required Uint32List entryOffsets,
    required Uint32List fileEntries,
    required Int64List fileStarts,
    required Uint8List skipped,
    required int skippedFileCount,
  }) : _skippedFileCount = skippedFileCount,
       _view = ByteData.sublistView(bytes),
       _entryOffsets = entryOffsets,
       _fileEntries = fileEntries,
       _fileStarts = fileStarts,
       _skipped = skipped;

  /// Parses and validates [bytes]. Every name has to be usable as a file name
  /// on all platforms, every parent has to be an earlier directory, and the
  /// totals have to add up, so a path built from this manifest can only land
  /// inside the folder being written.
  ///
  /// With [caseInsensitiveNames], a sibling whose name differs from an earlier
  /// one only by case is marked skipped, together with everything under it:
  /// the two would be the same file on such a file system.
  factory FolderManifest.parse(
    Uint8List bytes, {
    String pathSeparator = '/',
    bool caseInsensitiveNames = false,
  }) {
    if (bytes.length < folderManifestHeaderLength ||
        bytes.length > folderManifestMaxBytes ||
        bytes[0] != _magic0 ||
        bytes[1] != _magic1 ||
        bytes[2] != _magic2 ||
        bytes[3] != _magic3) {
      throw const FolderManifestException('invalid folder manifest header');
    }
    final view = ByteData.sublistView(bytes);
    final entryCount = view.getUint32(4);
    final fileCount = view.getUint32(8);
    final totalFileBytes = view.getUint64(12);
    if (entryCount > folderManifestMaxEntries ||
        fileCount > entryCount ||
        totalFileBytes < 0 ||
        totalFileBytes > folderStreamMaxSize) {
      throw const FolderManifestException('invalid folder manifest counts');
    }

    final entryOffsets = Uint32List(entryCount);
    final fileEntries = Uint32List(fileCount);
    final fileStarts = Int64List(fileCount + 1);
    final skipped = Uint8List(entryCount);
    final depths = Uint8List(entryCount);
    final pathBytes = Uint16List(entryCount);
    final siblingNames = caseInsensitiveNames ? <String>{} : null;

    var cursor = folderManifestHeaderLength;
    var nextFile = 0;
    var streamCursor = bytes.length;
    var summedFileBytes = 0;
    var skippedFileCount = 0;
    var previousParent = -1;
    var previousNameStart = 0;
    var previousNameLength = 0;
    for (var entry = 0; entry < entryCount; entry += 1) {
      if (bytes.length - cursor < _entryFixedLength) {
        throw const FolderManifestException('truncated folder manifest entry');
      }
      final kind = view.getUint8(cursor);
      final parent = view.getUint32(cursor + 1);
      final nameLength = view.getUint16(cursor + 5);
      final nameStart = cursor + _entryFixedLength;
      final isFile = kind == _kindFile;
      if ((!isFile && kind != _kindDirectory) ||
          nameLength == 0 ||
          nameLength > maxIncomingFileNameBytes ||
          bytes.length - nameStart <
              nameLength + (isFile ? _fileFieldsLength : 0)) {
        throw const FolderManifestException('invalid folder manifest entry');
      }
      final isRootChild = parent == folderManifestRootParent;
      if (!isRootChild &&
          (parent >= entry ||
              view.getUint8(entryOffsets[parent]) != _kindDirectory)) {
        throw const FolderManifestException('invalid folder manifest parent');
      }
      // Children of one directory sit together in ascending name order, which
      // also rules out two entries with the same path.
      final parentRank = isRootChild ? 0 : parent + 1;
      if (parentRank < previousParent) {
        throw const FolderManifestException('folder manifest is out of order');
      }
      final sameParent = parentRank == previousParent;
      if (sameParent &&
          _compareRanges(
                bytes,
                previousNameStart,
                previousNameLength,
                nameStart,
                nameLength,
              ) >=
              0) {
        throw const FolderManifestException('folder manifest is out of order');
      }
      final String name;
      try {
        name = utf8.decode(
          Uint8List.sublistView(bytes, nameStart, nameStart + nameLength),
        );
      } on FormatException {
        throw const FolderManifestException('invalid folder entry name');
      }
      if (!validateIncomingFileName(name)) {
        throw const FolderManifestException('invalid folder entry name');
      }
      final depth = isRootChild ? 1 : depths[parent] + 1;
      final pathLength = (isRootChild ? 0 : pathBytes[parent] + 1) + nameLength;
      if (depth > folderManifestMaxDepth ||
          pathLength > folderManifestMaxPathBytes) {
        throw const FolderManifestException('folder entry path is too long');
      }
      depths[entry] = depth;
      pathBytes[entry] = pathLength;
      entryOffsets[entry] = cursor;

      var isSkipped = !isRootChild && skipped[parent] != 0;
      if (siblingNames != null) {
        if (!sameParent) siblingNames.clear();
        if (!siblingNames.add(name.toLowerCase())) isSkipped = true;
      }
      if (isSkipped) skipped[entry] = 1;

      cursor = nameStart + nameLength;
      if (isFile) {
        final size = view.getUint64(cursor);
        final modifiedMs = view.getUint64(cursor + 8);
        if (nextFile >= fileCount ||
            size < 0 ||
            size > folderManifestMaxFileSize ||
            modifiedMs < 0 ||
            modifiedMs > _maxModifiedMs) {
          throw const FolderManifestException('invalid folder file entry');
        }
        fileEntries[nextFile] = entry;
        fileStarts[nextFile] = streamCursor;
        streamCursor += size + folderTrailerLength;
        summedFileBytes += size;
        if (summedFileBytes > folderStreamMaxSize) {
          throw const FolderManifestException('folder is too large');
        }
        if (isSkipped) skippedFileCount += 1;
        nextFile += 1;
        cursor += _fileFieldsLength;
      }
      previousParent = parentRank;
      previousNameStart = nameStart;
      previousNameLength = nameLength;
    }
    if (cursor != bytes.length ||
        nextFile != fileCount ||
        summedFileBytes != totalFileBytes ||
        streamCursor > folderStreamMaxSize) {
      throw const FolderManifestException('folder manifest totals mismatch');
    }
    fileStarts[fileCount] = streamCursor;
    return FolderManifest._(
      bytes: bytes,
      pathSeparator: pathSeparator,
      totalFileBytes: totalFileBytes,
      entryOffsets: entryOffsets,
      fileEntries: fileEntries,
      fileStarts: fileStarts,
      skipped: skipped,
      skippedFileCount: skippedFileCount,
    );
  }

  final Uint8List bytes;
  final String pathSeparator;
  final int totalFileBytes;

  int _skippedFileCount;
  final ByteData _view;
  final Uint32List _entryOffsets;
  final Uint32List _fileEntries;
  final Int64List _fileStarts;
  final Uint8List _skipped;
  final Map<int, String> _directoryPaths = <int, String>{};

  int get entryCount => _entryOffsets.length;
  int get fileCount => _fileEntries.length;
  int get directoryCount => entryCount - fileCount;
  int get manifestLength => bytes.length;

  /// Manifest, every file's bytes and every trailer.
  int get streamSize => _fileStarts[fileCount];

  bool isDirectory(int entry) =>
      _view.getUint8(_entryOffsets[entry]) == _kindDirectory;

  /// Files that will not be written: name collisions found while parsing
  /// and whatever [markSkipped] added since.
  int get skippedFileCount => _skippedFileCount;

  bool isSkipped(int entry) => _skipped[entry] != 0;

  /// Leaves [entry] out. Callers that skip a directory have to skip what is
  /// under it as well; children always come later in the manifest.
  void markSkipped(int entry) {
    if (_skipped[entry] != 0) return;
    _skipped[entry] = 1;
    if (!isDirectory(entry)) _skippedFileCount += 1;
  }

  int parentOf(int entry) => _view.getUint32(_entryOffsets[entry] + 1);

  String nameOf(int entry) {
    final offset = _entryOffsets[entry];
    final start = offset + _entryFixedLength;
    return utf8.decode(
      Uint8List.sublistView(bytes, start, start + _view.getUint16(offset + 5)),
    );
  }

  /// The path of [entry] below the folder root, joined by [pathSeparator].
  String relativePath(int entry) {
    final parent = parentOf(entry);
    final name = nameOf(entry);
    if (parent == folderManifestRootParent) return name;
    return '${_directoryPath(parent)}$pathSeparator$name';
  }

  /// [relativePath] with `/` between segments, whatever the platform uses.
  String portablePath(int entry) {
    final path = relativePath(entry);
    return pathSeparator == '/' ? path : path.replaceAll(pathSeparator, '/');
  }

  String _directoryPath(int entry) =>
      _directoryPaths[entry] ??= relativePath(entry);

  int fileEntry(int file) => _fileEntries[file];

  int fileSize(int file) => _view.getUint64(_fileFieldsOffset(file));

  int fileModifiedMs(int file) => _view.getUint64(_fileFieldsOffset(file) + 8);

  bool isFileSkipped(int file) => _skipped[_fileEntries[file]] != 0;

  /// Stream offset of the first data byte of [file]; with `file == fileCount`
  /// this is [streamSize].
  int fileStart(int file) => _fileStarts[file];

  int trailerStart(int file) => _fileStarts[file + 1] - folderTrailerLength;

  /// [fileStart] for every file and, last, [streamSize]: enough to tell from
  /// a stream offset alone how many files lie before it.
  Int64List get fileStarts => _fileStarts;

  /// The file whose data or trailer holds [streamOffset], or -1 while the
  /// offset is still inside the manifest.
  int fileAt(int streamOffset) {
    if (streamOffset < manifestLength) return -1;
    var low = 0;
    var high = fileCount;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_fileStarts[middle + 1] <= streamOffset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  int _fileFieldsOffset(int file) {
    final offset = _entryOffsets[_fileEntries[file]];
    return offset + _entryFixedLength + _view.getUint16(offset + 5);
  }
}

int _compareRanges(
  Uint8List bytes,
  int firstStart,
  int firstLength,
  int secondStart,
  int secondLength,
) {
  final shared = firstLength < secondLength ? firstLength : secondLength;
  for (var index = 0; index < shared; index += 1) {
    final difference = bytes[firstStart + index] - bytes[secondStart + index];
    if (difference != 0) return difference;
  }
  return firstLength - secondLength;
}
