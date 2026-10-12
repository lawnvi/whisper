import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/socket/folder_transfer_manifest.dart';
import 'package:whisper/socket/transfer_file_name.dart';

enum FolderScanFailure { unreadable, tooManyEntries, tooLarge }

/// How many skipped entries are kept by name; the count keeps going.
const int folderSkippedEntryListLimit = 1000;

/// Files the operating system leaves in folders for its own use. They are
/// left out without being reported as skipped.
const Set<String> _ignoredNames = <String>{
  '.DS_Store',
  'Thumbs.db',
  'desktop.ini',
};

final class FolderScanResult {
  const FolderScanResult._({
    required this.manifest,
    required this.manifestSha256,
    required this.fileCount,
    required this.directoryCount,
    required this.totalBytes,
    required this.skippedCount,
    required this.skipped,
    required this.rootModifiedMs,
  }) : failure = null;

  FolderScanResult.failed(FolderScanFailure this.failure)
    : manifest = Uint8List(0),
      manifestSha256 = '',
      fileCount = 0,
      directoryCount = 0,
      totalBytes = 0,
      skippedCount = 0,
      skipped = const <FolderSkippedEntry>[],
      rootModifiedMs = 0;

  final FolderScanFailure? failure;
  final Uint8List manifest;
  final String manifestSha256;
  final int fileCount;
  final int directoryCount;
  final int totalBytes;

  /// Entries left out of the manifest; [skipped] names the first of them.
  final int skippedCount;
  final List<FolderSkippedEntry> skipped;
  final int rootModifiedMs;

  int get streamSize =>
      manifest.length + totalBytes + fileCount * folderTrailerLength;
}

/// Walks [rootPath] and writes the manifest for sending it. Blocking: meant
/// to run off the UI isolate.
///
/// Links are never followed, so nothing outside the folder can be pulled in
/// and a link loop cannot hang the walk.
FolderScanResult scanFolderForTransfer(
  String rootPath, {
  int maxEntries = folderManifestMaxEntries,
  int maxStreamSize = folderStreamMaxSize,
}) {
  final root = Directory(_listablePath(rootPath));
  final builder = FolderManifestBuilder();
  final skipped = <FolderSkippedEntry>[];
  var skippedCount = 0;
  void skip(String path, FolderSkipReason reason) {
    skippedCount += 1;
    if (skipped.length < folderSkippedEntryListLimit) {
      skipped.add(FolderSkippedEntry(path: path, reason: reason));
    }
  }

  final pending = Queue<_PendingDirectory>()
    ..add(
      _PendingDirectory(
        directory: root,
        entry: folderManifestRootParent,
        portablePath: '',
        depth: 0,
        pathBytes: 0,
      ),
    );
  while (pending.isNotEmpty) {
    final current = pending.removeFirst();
    final List<FileSystemEntity> children;
    try {
      children = current.directory.listSync(followLinks: false);
    } on FileSystemException {
      if (current.entry == folderManifestRootParent) {
        return FolderScanResult.failed(FolderScanFailure.unreadable);
      }
      // The directory itself is already listed and arrives empty.
      skip(current.portablePath, FolderSkipReason.unreadable);
      continue;
    }

    final items = <_ScannedItem>[];
    for (final child in children) {
      final name = p.basename(child.path);
      if (_ignoredNames.contains(name)) continue;
      final portablePath = current.portablePath.isEmpty
          ? name
          : '${current.portablePath}/$name';
      if (child is Link) {
        skip(portablePath, FolderSkipReason.symlink);
        continue;
      }
      if (!validateIncomingFileName(name)) {
        skip(portablePath, FolderSkipReason.invalidName);
        continue;
      }
      final nameBytes = utf8.encode(name);
      final pathBytes =
          (current.pathBytes == 0 ? 0 : current.pathBytes + 1) +
          nameBytes.length;
      if (current.depth + 1 > folderManifestMaxDepth ||
          pathBytes > folderManifestMaxPathBytes) {
        skip(portablePath, FolderSkipReason.pathTooLong);
        continue;
      }
      if (child is Directory) {
        items.add(
          _ScannedItem(
            name: nameBytes,
            portablePath: portablePath,
            pathBytes: pathBytes,
            directory: child,
          ),
        );
        continue;
      }
      final stat = FileStat.statSync(child.path);
      if (stat.type != FileSystemEntityType.file) {
        skip(
          portablePath,
          stat.type == FileSystemEntityType.notFound
              ? FolderSkipReason.unreadable
              : FolderSkipReason.special,
        );
        continue;
      }
      if (stat.size > folderManifestMaxFileSize) {
        skip(portablePath, FolderSkipReason.tooLarge);
        continue;
      }
      items.add(
        _ScannedItem(
          name: nameBytes,
          portablePath: portablePath,
          pathBytes: pathBytes,
          size: stat.size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
        ),
      );
    }
    items.sort((a, b) => compareFolderEntryNames(a.name, b.name));

    for (final item in items) {
      if (builder.entryCount >= maxEntries) {
        return FolderScanResult.failed(FolderScanFailure.tooManyEntries);
      }
      final directory = item.directory;
      if (directory != null) {
        final entry = builder.addDirectory(
          parent: current.entry,
          name: item.name,
        );
        pending.add(
          _PendingDirectory(
            directory: directory,
            entry: entry,
            portablePath: item.portablePath,
            depth: current.depth + 1,
            pathBytes: item.pathBytes,
          ),
        );
      } else {
        builder.addFile(
          parent: current.entry,
          name: item.name,
          size: item.size,
          modifiedMs: item.modifiedMs,
        );
      }
      if (builder.streamSize > maxStreamSize ||
          builder.manifestLength > folderManifestMaxBytes) {
        return FolderScanResult.failed(FolderScanFailure.tooLarge);
      }
    }
  }

  final manifest = builder.build();
  var rootModifiedMs = 0;
  try {
    rootModifiedMs = root.statSync().modified.millisecondsSinceEpoch;
  } on FileSystemException {
    // The folder's own timestamp is informational.
  }
  return FolderScanResult._(
    manifest: manifest,
    manifestSha256: sha256.convert(manifest).toString(),
    fileCount: builder.fileCount,
    directoryCount: builder.directoryCount,
    totalBytes: builder.totalFileBytes,
    skippedCount: skippedCount,
    skipped: skipped,
    rootModifiedMs: rootModifiedMs,
  );
}

/// Windows refuses to list a directory whose path has passed 260 characters
/// unless the path is in its extended-length form. Everything found below
/// such a path carries the prefix on, so the whole walk stays listable.
String _listablePath(String path) {
  const prefix = r'\\?\';
  if (!Platform.isWindows || path.startsWith(prefix)) return path;
  final absolute = p.normalize(p.absolute(path));
  return absolute.startsWith(r'\\')
      ? '${prefix}UNC${absolute.substring(1)}'
      : '$prefix$absolute';
}

final class _PendingDirectory {
  const _PendingDirectory({
    required this.directory,
    required this.entry,
    required this.portablePath,
    required this.depth,
    required this.pathBytes,
  });

  final Directory directory;
  final int entry;
  final String portablePath;
  final int depth;
  final int pathBytes;
}

final class _ScannedItem {
  const _ScannedItem({
    required this.name,
    required this.portablePath,
    required this.pathBytes,
    this.directory,
    this.size = 0,
    this.modifiedMs = 0,
  });

  final Uint8List name;
  final String portablePath;
  final int pathBytes;
  final Directory? directory;
  final int size;
  final int modifiedMs;
}
