import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';

typedef FolderStagingDirectoryProvider = Future<Directory> Function();
typedef ActiveTransferPathsProvider = Future<Set<String>> Function();

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

/// Removes archives created by versions that supported ZIP folder transfer.
final class LegacyFolderTransferCleanup {
  const LegacyFolderTransferCleanup({
    FolderStagingDirectoryProvider? stagingDirectoryProvider,
    ActiveTransferPathsProvider? activeTransferPathsProvider,
  }) : _stagingDirectoryProvider = stagingDirectoryProvider,
       _activeTransferPathsProvider = activeTransferPathsProvider;

  static const Duration orphanGracePeriod = Duration(minutes: 15);

  final FolderStagingDirectoryProvider? _stagingDirectoryProvider;
  final ActiveTransferPathsProvider? _activeTransferPathsProvider;

  Future<void> cleanup() async {
    final directory = await _resolveStagingDirectory();
    if (!await directory.exists()) {
      return;
    }
    final activePathsProvider = _activeTransferPathsProvider;
    if (activePathsProvider == null) {
      return;
    }
    final Set<String> activePaths;
    try {
      activePaths = await activePathsProvider();
    } catch (_) {
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
        final isActive = normalizedActivePaths.any(
          (path) => p.equals(path, normalizedPath),
        );
        if (!isActive && (await entity.lastModified()).isBefore(cutoff)) {
          await entity.delete();
        }
      } catch (_) {
        // Legacy cache cleanup must never block startup.
      }
    }
  }

  Future<Directory> _resolveStagingDirectory() async {
    return _stagingDirectoryProvider?.call() ??
        _defaultFolderStagingDirectory();
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
    final archive = File(archivePath);
    if (!await archive.exists()) {
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
    return true;
  } catch (_) {
    return false;
  }
}

Future<Directory> _defaultFolderStagingDirectory() async {
  final temporary = await getTemporaryDirectory();
  return Directory(p.join(temporary.path, 'whisper', 'folder-staging'));
}
