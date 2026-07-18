import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';

typedef FolderStagingDirectoryProvider = Future<Directory> Function();
typedef ActiveTransferPathsProvider = Future<Set<String>> Function();

const Uuid _folderArchiveUuid = Uuid();
final Set<String> _processOwnedFolderArchives = <String>{};

Future<Set<String>> recoverableFolderTransferPaths() async {
  final transfers = await LocalDatabase().fetchRetainedOutgoingFileTransfers();
  return transfers
      .where(
        (transfer) =>
            transfer.direction == FileTransferDirection.outgoing &&
            !transfer.finalPath.startsWith('content://'),
      )
      .map((transfer) => p.normalize(p.absolute(transfer.finalPath)))
      .toSet();
}

final class StagedTransferFolder {
  const StagedTransferFolder({
    required this.sourceDirectory,
    required this.archiveFile,
  });

  final Directory sourceDirectory;
  final File archiveFile;
}

final class FolderTransferStager {
  const FolderTransferStager({
    FolderStagingDirectoryProvider? stagingDirectoryProvider,
    ActiveTransferPathsProvider? activeTransferPathsProvider,
  }) : _stagingDirectoryProvider = stagingDirectoryProvider,
       _activeTransferPathsProvider = activeTransferPathsProvider;

  static const Duration orphanGracePeriod = Duration(minutes: 15);

  final FolderStagingDirectoryProvider? _stagingDirectoryProvider;
  final ActiveTransferPathsProvider? _activeTransferPathsProvider;

  Future<StagedTransferFolder> stage(String directoryPath) async {
    final source = Directory(directoryPath);
    if (!await source.exists()) {
      throw FileSystemException('Folder does not exist', directoryPath);
    }
    if (await FileSystemEntity.type(directoryPath, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'Folder path is not a directory',
        directoryPath,
      );
    }

    final stagingDirectory = await _resolveStagingDirectory();
    await stagingDirectory.create(recursive: true);
    await _deleteStaleArchives(stagingDirectory);
    final sourcePath = p.normalize(await source.resolveSymbolicLinks());
    final stagingPath = p.normalize(
      await stagingDirectory.resolveSymbolicLinks(),
    );
    if (p.equals(sourcePath, stagingPath) ||
        p.isWithin(stagingPath, sourcePath)) {
      throw FileSystemException(
        'Folder is inside Whisper staging storage',
        directoryPath,
      );
    }
    final archiveName = _archiveNameFor(source);
    final archiveFile = File(p.join(stagingPath, archiveName));
    final ownedArchivePath = p.normalize(archiveFile.absolute.path);
    _processOwnedFolderArchives.add(ownedArchivePath);
    try {
      final archivePath = archiveFile.path;
      await Isolate.run(
        () => _writeStoredFolderArchive(
          sourcePath,
          archivePath,
          excludedDirectoryPath: p.isWithin(sourcePath, stagingPath)
              ? stagingPath
              : null,
        ),
      );
    } catch (_) {
      _processOwnedFolderArchives.remove(ownedArchivePath);
      if (await archiveFile.exists()) {
        await archiveFile.delete();
      }
      rethrow;
    }
    if (!await archiveFile.exists()) {
      throw FileSystemException(
        'Folder archive was not created',
        archiveFile.path,
      );
    }
    return StagedTransferFolder(
      sourceDirectory: source,
      archiveFile: archiveFile,
    );
  }

  Future<void> cleanup() async {
    final stagingDirectory = await _resolveStagingDirectory();
    await stagingDirectory.create(recursive: true);
    await _deleteStaleArchives(stagingDirectory);
  }

  Future<Directory> _resolveStagingDirectory() async {
    final supplied = _stagingDirectoryProvider;
    if (supplied != null) {
      return supplied();
    }
    return _defaultFolderStagingDirectory();
  }

  Future<void> _deleteStaleArchives(Directory directory) async {
    final activePathsProvider = _activeTransferPathsProvider;
    if (activePathsProvider == null) {
      return;
    }
    final Set<String> activePaths;
    try {
      activePaths = await activePathsProvider();
    } catch (_) {
      // If active transfers cannot be read, preserving archives is safer.
      return;
    }
    final normalizedActivePaths = <String>{};
    for (final activePath in activePaths) {
      try {
        final activeFile = File(activePath);
        normalizedActivePaths.add(
          p.normalize(
            await activeFile.exists()
                ? await activeFile.resolveSymbolicLinks()
                : activeFile.absolute.path,
          ),
        );
      } catch (_) {
        normalizedActivePaths.add(p.normalize(p.absolute(activePath)));
      }
    }
    final cutoff = DateTime.now().subtract(orphanGracePeriod);
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.zip')) {
        continue;
      }
      try {
        final normalizedPath = p.normalize(await entity.resolveSymbolicLinks());
        if (_processOwnedFolderArchives.contains(normalizedPath)) {
          continue;
        }
        final isActive = normalizedActivePaths.any(
          (activePath) => p.equals(activePath, normalizedPath),
        );
        if (!isActive && (await entity.lastModified()).isBefore(cutoff)) {
          await entity.delete();
        }
      } catch (_) {
        // Stale cache cleanup must not block a new folder transfer.
      }
    }
  }

  String _archiveNameFor(Directory source) {
    final rawName = p.basename(source.absolute.path);
    final safeName = rawName
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .trim();
    final baseName = safeName.isEmpty ? 'folder' : safeName;
    return '${baseName}_${_folderArchiveUuid.v4()}.zip';
  }
}

Future<bool> releaseStagedFolderTransferArchive(
  String archivePath, {
  FolderStagingDirectoryProvider? stagingDirectoryProvider,
}) async {
  if (archivePath.isEmpty || !archivePath.toLowerCase().endsWith('.zip')) {
    return false;
  }
  try {
    final normalizedArchive = p.normalize(p.absolute(archivePath));
    final archive = File(archivePath);
    if (!await archive.exists()) {
      _processOwnedFolderArchives.remove(normalizedArchive);
      return false;
    }
    final stagingDirectory = stagingDirectoryProvider == null
        ? await _defaultFolderStagingDirectory()
        : await stagingDirectoryProvider();
    if (!await stagingDirectory.exists()) {
      return false;
    }
    final stagingPath = p.normalize(
      await stagingDirectory.resolveSymbolicLinks(),
    );
    final resolvedArchivePath = p.normalize(
      await archive.resolveSymbolicLinks(),
    );
    if (!p.isWithin(stagingPath, resolvedArchivePath)) {
      return false;
    }
    await archive.delete();
    _processOwnedFolderArchives
      ..remove(normalizedArchive)
      ..remove(resolvedArchivePath);
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> releaseUnownedStagedFolderTransferArchive(
  String archivePath, {
  FolderStagingDirectoryProvider? stagingDirectoryProvider,
  ActiveTransferPathsProvider? retainedTransferPathsProvider,
}) async {
  final retainedProvider =
      retainedTransferPathsProvider ?? recoverableFolderTransferPaths;
  try {
    final normalizedArchive = p.normalize(p.absolute(archivePath));
    final retainedPaths = await retainedProvider();
    if (retainedPaths.any(
      (path) => p.equals(p.normalize(p.absolute(path)), normalizedArchive),
    )) {
      return false;
    }
  } catch (_) {
    // If durable ownership cannot be checked, preserving the archive is safer.
    return false;
  }
  return releaseStagedFolderTransferArchive(
    archivePath,
    stagingDirectoryProvider: stagingDirectoryProvider,
  );
}

Future<Directory> _defaultFolderStagingDirectory() async {
  final temporary = await getTemporaryDirectory();
  return Directory(p.join(temporary.path, 'whisper', 'folder-staging'));
}

Future<void> _writeStoredFolderArchive(
  String sourcePath,
  String archivePath, {
  String? excludedDirectoryPath,
}) async {
  final encoder = ZipFileEncoder();
  var encoderOpen = false;
  try {
    encoder.create(archivePath, level: ZipFileEncoder.store);
    encoderOpen = true;
    await encoder.addDirectory(
      Directory(sourcePath),
      includeDirName: true,
      level: ZipFileEncoder.store,
      followLinks: false,
      filter: excludedDirectoryPath == null
          ? null
          : (entity, _) {
              final entityPath = p.normalize(entity.absolute.path);
              return p.equals(entityPath, excludedDirectoryPath) ||
                      p.isWithin(excludedDirectoryPath, entityPath)
                  ? ZipFileOperation.skip
                  : ZipFileOperation.include;
            },
    );
    await encoder.close();
    encoderOpen = false;
  } catch (_) {
    if (encoderOpen) {
      try {
        await encoder.close();
      } catch (_) {
        // The caller removes the partially written archive.
      }
    }
    rethrow;
  }
}
