import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:whisper/socket/folder_output_file.dart';

/// A small file of a received folder, complete and checked, on its way to
/// disk.
final class FolderDeferredFile {
  const FolderDeferredFile({
    required this.file,
    required this.path,
    required this.bytes,
    required this.modifiedMs,
  });

  /// Where the file comes in the manifest.
  final int file;
  final String path;
  final Uint8List bytes;
  final int modifiedMs;
}

/// Why a file handed over for writing did not make it to disk.
final class FolderWriteFailure {
  const FolderWriteFailure({required this.diskFull, required this.description});

  final bool diskFull;
  final String description;
}

/// Takes whole small files off the hands of whoever reads the folder stream,
/// so the stream moves on while they are written.
abstract interface class FolderDeferredWrites {
  /// Files up to this size may be handed over.
  int get maxFileBytes;

  void write(FolderDeferredFile file);

  /// Takes no more work. Writes already under way are finished first.
  void dispose();
}

/// How many isolates write small files side by side on this machine.
int defaultFolderWriteWorkers() =>
    math.max(0, math.min(4, Platform.numberOfProcessors - 2));

/// Writes small files from a few isolates at once.
///
/// A folder of small files spends its time creating files, and most of that
/// is waiting on the system rather than work. On an Android 13 phone, where
/// shared storage goes through a FUSE daemon, 1,500 files of 4 KiB took
/// 4.1 ms each written one after another and 0.75 ms each from four isolates.
/// On Windows 11 with real-time protection on it depends on the machine:
/// 14,797 source files took 40 to 45 s without the pool and 15 to 16 s with
/// it on one, 17.3 to 18.8 s against 16.3 s on a faster one.
final class FolderWritePool implements FolderDeferredWrites {
  FolderWritePool({
    required int workers,
    required this.onSettled,
    required this.onBroken,
    this.maxFileBytes = 1024 * 1024,
  }) : _workerCount = workers;

  /// A worker is given this many files at a time, so that it never waits
  /// for the next one and stopping never waits for long.
  static const int _depth = 2;

  final int _workerCount;

  /// Called for every file handed over, once it is on disk or has failed.
  final void Function(int file, FolderWriteFailure? failure) onSettled;

  /// Called when a worker is lost; nothing more gets written after that.
  final void Function(String description) onBroken;

  @override
  final int maxFileBytes;

  final Queue<FolderDeferredFile> _queue = Queue<FolderDeferredFile>();
  final List<_PoolWorker> _workers = <_PoolWorker>[];
  ReceivePort? _results;
  int _alive = 0;
  bool _disposed = false;
  bool _broken = false;

  @override
  void write(FolderDeferredFile file) {
    if (_disposed || _broken) return;
    _queue.add(file);
    _start();
    _dispatch();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _queue.clear();
    for (final worker in _workers) {
      worker.commands?.send(null);
    }
    _closeWhenDone();
  }

  void _start() {
    if (_results != null) return;
    final results = _results = ReceivePort();
    results.listen(_handle);
    for (var index = 0; index < _workerCount; index += 1) {
      _workers.add(_PoolWorker());
      _alive += 1;
      unawaited(
        Isolate.spawn<(SendPort, int)>(
          _folderWriteWorker,
          (results.sendPort, index),
          onError: results.sendPort,
          onExit: results.sendPort,
          errorsAreFatal: true,
        ).then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {
            _alive -= 1;
            _break('folder write worker did not start');
          },
        ),
      );
    }
  }

  void _dispatch() {
    while (_queue.isNotEmpty) {
      _PoolWorker? idlest;
      for (final worker in _workers) {
        if (worker.commands == null || worker.inFlight >= _depth) continue;
        if (idlest == null || worker.inFlight < idlest.inFlight) {
          idlest = worker;
        }
      }
      if (idlest == null) return;
      final file = _queue.removeFirst();
      idlest.inFlight += 1;
      idlest.commands!.send(<Object?>[
        file.file,
        file.path,
        TransferableTypedData.fromList(<TypedData>[file.bytes]),
        file.modifiedMs,
      ]);
    }
  }

  void _handle(Object? message) {
    if (message == null) {
      // A worker has left.
      _alive -= 1;
      if (_disposed) {
        _closeWhenDone();
      } else {
        _break('folder write worker stopped');
      }
      return;
    }
    final fields = message as List<Object?>;
    final index = fields.first;
    if (index is! int) {
      // An uncaught error; the worker is on its way out.
      _break('folder write worker failed');
      return;
    }
    final worker = _workers[index];
    final second = fields[1];
    if (second is SendPort) {
      worker.commands = second;
      if (_disposed || _broken) {
        second.send(null);
      } else {
        _dispatch();
      }
      return;
    }
    worker.inFlight -= 1;
    if (_disposed || _broken) return;
    final failure = fields[2] as List<Object?>?;
    onSettled(
      second! as int,
      failure == null
          ? null
          : FolderWriteFailure(
              diskFull: failure[0]! as bool,
              description: failure[1]! as String,
            ),
    );
    _dispatch();
  }

  void _break(String description) {
    if (_disposed || _broken) return;
    _broken = true;
    _queue.clear();
    onBroken(description);
  }

  void _closeWhenDone() {
    if (_alive > 0) return;
    _results?.close();
  }
}

final class _PoolWorker {
  SendPort? commands;
  int inFlight = 0;
}

void _folderWriteWorker((SendPort, int) bootstrap) {
  final (results, index) = bootstrap;
  final commands = ReceivePort();
  final files = FolderFileWriter();
  results.send(<Object?>[index, commands.sendPort]);
  commands.listen((message) {
    if (message == null) {
      files.dispose();
      commands.close();
      return;
    }
    final job = message as List<Object?>;
    final path = job[1]! as String;
    List<Object?>? failure;
    try {
      final bytes = (job[2]! as TransferableTypedData)
          .materialize()
          .asUint8List();
      final output = files.create(path);
      try {
        if (bytes.isNotEmpty) output.write(bytes, 0, bytes.length);
      } on FileSystemException {
        try {
          output.close();
        } on FileSystemException {
          // The write is what gets reported.
        }
        rethrow;
      }
      output.close(modifiedMs: job[3]! as int);
    } on FileSystemException catch (error) {
      failure = <Object?>[
        folderWriteHitFullDisk(error),
        error.osError?.message ?? error.message,
      ];
      try {
        final type = FileSystemEntity.typeSync(path, followLinks: false);
        if (type == FileSystemEntityType.file) File(path).deleteSync();
      } on FileSystemException {
        // Left behind at worst; it is still reported as not transferred.
      }
    }
    results.send(<Object?>[index, job[0], failure]);
  });
}
