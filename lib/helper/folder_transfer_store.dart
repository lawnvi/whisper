import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/socket/folder_transfer_manifest.dart';
import 'package:whisper/socket/folder_transfer_scan.dart'
    show folderSkippedEntryListLimit;
import 'package:whisper/socket/wire_input_policy.dart'
    show isCanonicalTransferId;

const String _manifestSuffix = '.manifest';
const String _skippedSuffix = '.skipped.json';
const String _stagingSuffix = '.folder';

/// What a folder transfer keeps on disk beside its database row.
///
/// The sender keeps the manifest it scanned, so a transfer continued after a
/// restart still describes the same snapshot of the folder. Both sides keep
/// the names of the entries that were left out, for the conversation to show.
final class FolderTransferStore {
  const FolderTransferStore({Future<Directory> Function()? directory})
    : _directory = directory;

  final Future<Directory> Function()? _directory;

  Future<Directory> _resolveDirectory() async {
    final provider = _directory;
    if (provider != null) return provider();
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'folder-transfers'));
  }

  Future<String> _pathFor(String transferId, String suffix) async {
    if (!isCanonicalTransferId(transferId)) {
      throw ArgumentError.value(transferId, 'transferId');
    }
    return p.join((await _resolveDirectory()).path, '$transferId$suffix');
  }

  Future<String> manifestPath(String transferId) =>
      _pathFor(transferId, _manifestSuffix);

  Future<void> writeManifest(String transferId, Uint8List manifest) async {
    final path = await manifestPath(transferId);
    await Directory(p.dirname(path)).create(recursive: true);
    final pending = File('$path.tmp');
    await pending.writeAsBytes(manifest, flush: true);
    await pending.rename(path);
  }

  Future<void> deleteManifest(String transferId) async {
    try {
      final file = File(await manifestPath(transferId));
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Removed with the other leftovers at the next start.
    }
  }

  /// Adds [entries] to what is already recorded for [transferId].
  Future<void> addSkipped(
    String transferId,
    List<FolderSkippedEntry> entries,
  ) async {
    if (entries.isEmpty) return;
    final known = await readSkipped(transferId);
    final seen = <String>{for (final entry in known) entry.path};
    final merged = <FolderSkippedEntry>[
      ...known,
      for (final entry in entries)
        if (seen.add(entry.path)) entry,
    ].take(folderSkippedEntryListLimit).toList(growable: false);
    final path = await _pathFor(transferId, _skippedSuffix);
    await Directory(p.dirname(path)).create(recursive: true);
    await File(path).writeAsString(
      jsonEncode(<String, Object?>{
        'entries': <Object?>[for (final entry in merged) entry.toJson()],
      }),
      flush: true,
    );
  }

  Future<List<FolderSkippedEntry>> readSkipped(String transferId) async {
    try {
      final file = File(await _pathFor(transferId, _skippedSuffix));
      if (!await file.exists()) return const <FolderSkippedEntry>[];
      final decoded = jsonDecode(await file.readAsString());
      final entries = decoded is Map ? decoded['entries'] : null;
      if (entries is! List) return const <FolderSkippedEntry>[];
      return <FolderSkippedEntry>[
        for (final item in entries) ?FolderSkippedEntry.tryFromJson(item),
      ];
    } on Object {
      return const <FolderSkippedEntry>[];
    }
  }

  /// A file this young may belong to a transfer that is about to be
  /// recorded, so it is left for a later pass.
  static const Duration leftoverGracePeriod = Duration(minutes: 15);

  /// Removes what no transfer needs any more: manifests of transfers that
  /// finished or are gone, and skipped lists whose transfer was deleted.
  Future<void> removeLeftovers(LocalDatabase database) async {
    final directory = await _resolveDirectory();
    if (!await directory.exists()) return;
    final cutoff = DateTime.now().subtract(leftoverGracePeriod);
    final files = <String, List<File>>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final transferId = name.split('.').first;
      if (isCanonicalTransferId(transferId) &&
          (await entity.lastModified()).isBefore(cutoff)) {
        files.putIfAbsent(transferId, () => <File>[]).add(entity);
      }
    }
    if (files.isEmpty) return;
    final transfers = await database.fetchFileTransfersByIds(files.keys);
    for (final entry in files.entries) {
      final transfer = transfers[entry.key];
      for (final file in entry.value) {
        final keep = file.path.endsWith(_manifestSuffix)
            ? transfer != null &&
                  transfer.direction == FileTransferDirection.outgoing &&
                  transfer.state != FileTransferState.completed &&
                  transfer.state != FileTransferState.canceled
            : transfer != null && file.path.endsWith(_skippedSuffix);
        if (keep) continue;
        try {
          await file.delete();
        } on FileSystemException {
          // Tried again at the next start.
        }
      }
    }
  }
}

/// Removes folders that were being received for transfers which can no longer
/// continue: canceled, completed, or deleted together with their message.
Future<void> removeAbandonedFolderStaging(
  LocalDatabase database,
  Directory downloadRoot,
) async {
  final transfers = Directory(
    p.join(downloadRoot.path, '.whisper', 'transfers'),
  );
  if (await FileSystemEntity.type(transfers.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    return;
  }
  final staged = <String, Directory>{};
  await for (final entity in transfers.list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (entity is! Directory || !name.endsWith(_stagingSuffix)) continue;
    final transferId = name.substring(0, name.length - _stagingSuffix.length);
    if (isCanonicalTransferId(transferId)) staged[transferId] = entity;
  }
  if (staged.isEmpty) return;
  final known = await database.fetchFileTransfersByIds(staged.keys);
  for (final entry in staged.entries) {
    final transfer = known[entry.key];
    if (transfer != null &&
        transfer.messageRowId > 0 &&
        transfer.direction == FileTransferDirection.incoming &&
        transfer.state != FileTransferState.completed &&
        transfer.state != FileTransferState.canceled) {
      continue;
    }
    try {
      await entry.value.delete(recursive: true);
    } on FileSystemException {
      // Tried again at the next start.
    }
  }
}
