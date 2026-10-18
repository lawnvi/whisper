import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../model/file_transfer.dart';
import 'files_log.dart';

/// One copy that landed where it was asked to go.
class PlacedTransfer {
  const PlacedTransfer({required this.transferId, required this.path});

  final String transferId;
  final String path;
}

/// Copies through the file manager are ordinary resumable transfers into
/// the downloads folder; this moves each one into the folder the user
/// chose as soon as it completes, and keeps the history pointing at it.
class TransferPlacements extends ChangeNotifier {
  TransferPlacements();

  static final TransferPlacements shared = TransferPlacements();

  final _pending = <String, ({String directory, DateTime until})>{};
  final _placed = StreamController<PlacedTransfer>.broadcast();

  /// Copies made in the file manager, sent or received. Like clipboard
  /// sync they are not part of the conversation: hidden there while they
  /// run, their messages removed once they complete (the files stay). One
  /// that fails shows up in the conversation, where it can be retried.
  final _quiet = <String>{};

  /// Removes the chat message of a completed copy.
  Future<void> Function(String transferId)? forgetRecord;

  /// Carries a stopped transfer on (wired to the transfer engine).
  Future<void> Function(String transferId)? resume;

  /// Copies this device sends that a reconnect paused and that were asked
  /// to carry on.
  final _resumed = <String>{};

  /// [transferId] is a copy this device sends for the file manager.
  void markQuiet(String transferId) => _quiet.add(transferId);

  bool isQuiet(String transferId) =>
      transferId.isNotEmpty &&
      (_quiet.contains(transferId) || _pending.containsKey(transferId));

  /// Points the stored transfer (and its chat message) at the new path.
  Future<void> Function(String transferId, String oldPath, String newPath)?
  relocateRecord;

  /// Tells the media index about moved files (Android galleries).
  Future<void> Function(List<String> paths)? mediaScan;

  Stream<PlacedTransfer> get placed => _placed.stream;

  /// Copies that arrived but could not be moved where they were asked to
  /// go (they stay in the downloads folder).
  Stream<String> get unplaced => _unplaced.stream;
  final _unplaced = StreamController<String>.broadcast();

  /// The last state logged for each copy, so the log has its changes only.
  final _loggedStates = <String, FileTransferState>{};

  /// Every transfer update, for progress shown by the file manager.
  Stream<TransferSnapshot> get updates => _updates.stream;
  final _updates = StreamController<TransferSnapshot>.broadcast();

  bool isExpected(String transferId) => _pending.containsKey(transferId);

  /// The next incoming transfer [transferId] goes into [directory].
  void expect(
    String transferId,
    String directory, {
    Duration lifetime = const Duration(days: 2),
  }) {
    _quiet.add(transferId);
    _pending[transferId] = (
      directory: directory,
      until: DateTime.now().add(lifetime),
    );
    _pending.removeWhere((_, value) => value.until.isBefore(DateTime.now()));
  }

  /// Sends [transferId], still on its way, into [directory] instead.
  /// False once it has landed, or if it was never expected.
  bool retarget(String transferId, String directory) {
    final pending = _pending[transferId];
    if (pending == null) {
      return false;
    }
    _pending[transferId] = (directory: directory, until: pending.until);
    FilesLog.write('transfer ${FilesLog.id(transferId)} sent elsewhere');
    return true;
  }

  Future<void> onTransferUpdated(TransferSnapshot snapshot) async {
    _updates.add(snapshot);
    final quiet = _quiet.contains(snapshot.transferId);
    if (quiet && _loggedStates[snapshot.transferId] != snapshot.state) {
      _loggedStates[snapshot.transferId] = snapshot.state;
      FilesLog.write(
        'transfer ${FilesLog.id(snapshot.transferId)} '
        '${snapshot.direction.name} ${snapshot.state.name}'
        '${snapshot.lastError.isEmpty ? '' : ' (${snapshot.lastError})'}',
      );
      if (isTerminalFileTransferState(snapshot.state)) {
        _loggedStates.remove(snapshot.transferId);
      }
    }
    // A reconnect pauses what was under way, for someone to carry it on
    // from its message; a copy has no message to tap, so it carries on by
    // itself. Once: one that stops again waits for the user.
    if (quiet &&
        snapshot.direction == FileTransferDirection.outgoing &&
        snapshot.state == FileTransferState.paused &&
        snapshot.lastError.isEmpty &&
        _resumed.add(snapshot.transferId)) {
      unawaited(resume?.call(snapshot.transferId));
    }
    await _place(snapshot);
    if (!quiet) {
      return;
    }
    switch (snapshot.state) {
      case FileTransferState.completed:
        await forgetRecord?.call(snapshot.transferId);
        _quiet.remove(snapshot.transferId);
        _resumed.remove(snapshot.transferId);
        notifyListeners();
      case FileTransferState.failed || FileTransferState.canceled:
        _quiet.remove(snapshot.transferId);
        _resumed.remove(snapshot.transferId);
        notifyListeners();
      default:
        break;
    }
  }

  Future<void> _place(TransferSnapshot snapshot) async {
    final pending = _pending[snapshot.transferId];
    if (pending == null ||
        snapshot.direction != FileTransferDirection.incoming) {
      return;
    }
    switch (snapshot.state) {
      case FileTransferState.completed:
        _pending.remove(snapshot.transferId);
        final from = snapshot.finalPath;
        if (from.isEmpty) {
          return;
        }
        final String to;
        try {
          to = await moveInto(from, pending.directory);
        } on FileSystemException catch (error) {
          // Left in the downloads folder; the history still points there.
          FilesLog.write(
            'transfer ${FilesLog.id(snapshot.transferId)} not placed '
            '(${error.osError?.errorCode ?? error.message})',
          );
          _unplaced.add(snapshot.transferId);
          return;
        }
        try {
          await relocateRecord?.call(snapshot.transferId, from, to);
          await mediaScan?.call([from, to]);
        } catch (_) {
          // The file is where it was asked to go; only the record lags.
        }
        FilesLog.write('transfer ${FilesLog.id(snapshot.transferId)} placed');
        _placed.add(PlacedTransfer(transferId: snapshot.transferId, path: to));
        notifyListeners();
      case FileTransferState.failed || FileTransferState.canceled:
        _pending.remove(snapshot.transferId);
      default:
        break;
    }
  }

  /// Moves [source] (file or folder) into [directory] under a name that
  /// is free there, across filesystems if need be. Returns the new path.
  static Future<String> moveInto(String source, String directory) async {
    final target = await freeName(directory, p.basename(source));
    if (p.equals(p.dirname(source), directory)) {
      return source;
    }
    final type = await FileSystemEntity.type(source, followLinks: false);
    try {
      if (type == FileSystemEntityType.directory) {
        await Directory(source).rename(target);
      } else {
        await File(source).rename(target);
      }
      return target;
    } on FileSystemException {
      // Another volume (or, on Windows, a file still open somewhere): copy.
      if (type == FileSystemEntityType.directory) {
        await _copyTree(Directory(source), Directory(target));
      } else {
        await File(source).copy(target);
      }
    }
    // The copy is in place. The original is removed if it can be; one that
    // is still held open stays behind rather than failing the whole copy.
    try {
      if (type == FileSystemEntityType.directory) {
        await Directory(source).delete(recursive: true);
      } else {
        await File(source).delete();
      }
    } on FileSystemException catch (error) {
      FilesLog.write(
        'placement kept the original '
        '(${error.osError?.errorCode ?? error.message})',
      );
    }
    return target;
  }

  /// "name", else "name 2", "name 3"… in [directory].
  static Future<String> freeName(String directory, String name) async {
    var candidate = p.join(directory, name);
    final stem = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    for (
      var n = 2;
      await FileSystemEntity.type(candidate, followLinks: false) !=
          FileSystemEntityType.notFound;
      n++
    ) {
      candidate = p.join(directory, '$stem $n$ext');
    }
    return candidate;
  }

  static Future<void> _copyTree(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(followLinks: false)) {
      final target = p.join(to.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyTree(entity, Directory(target));
      } else if (entity is File) {
        await entity.copy(target);
      }
    }
  }
}
