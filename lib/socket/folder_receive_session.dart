import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:whisper/socket/folder_transfer_manifest.dart';
import 'package:whisper/socket/folder_transfer_sink.dart';
import 'package:whisper/socket/folder_write_pool.dart';

/// The receiving end of a folder transfer as the engine sees it. Payloads go
/// to a worker isolate that does the writing; progress and the outcome come
/// back as events.
final class FolderReceiveSession {
  FolderReceiveSession._({
    required Isolate isolate,
    required SendPort commands,
    required ReceivePort events,
    required this.resume,
    required int maxQueuedBytes,
  }) : _isolate = isolate,
       _commands = commands,
       _events = events,
       _latest = resume,
       _maxQueuedBytes = maxQueuedBytes {
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

  /// Hard cap on bytes buffered on the main isolate waiting for the worker.
  /// Matches the desktop transfer window so compliant peers never hit it,
  /// while misbehaving peers or stalled disks cannot exhaust memory.
  static const int defaultMaxQueuedBytes = 64 * 1024 * 1024;

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
        maxQueuedBytes: config.maxQueuedBytes,
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
  final int _maxQueuedBytes;
  final Queue<Uint8List> _queued = Queue<Uint8List>();
  final Completer<FolderReceiveSummary> _finished =
      Completer<FolderReceiveSummary>();
  final Completer<void> _exited = Completer<void>();
  FolderReceiveProgress _latest;
  int _queuedBytes = 0;
  int _inFlight = 0;
  bool _closing = false;

  void Function(FolderReceiveProgress progress)? onProgress;

  FolderReceiveProgress get latest => _latest;

  /// Completes once the whole stream has been written, or fails with a
  /// [FolderReceiveException] when the transfer cannot go on.
  Future<FolderReceiveSummary> get finished => _finished.future;

  void add(Uint8List payload) {
    if (_closing || payload.isEmpty) return;
    if (_queuedBytes + payload.length > _maxQueuedBytes) {
      _closing = true;
      _queued.clear();
      _queuedBytes = 0;
      _commands.send(const <Object?>['close']);
      if (!_finished.isCompleted) {
        _finished.completeError(
          const FolderReceiveException(
            FolderReceiveFailureKind.io,
            'folder receive buffer overflow',
          ),
        );
      }
      return;
    }
    for (var start = 0; start < payload.length; start += _sliceBytes) {
      final slice = Uint8List.sublistView(
        payload,
        start,
        math.min(payload.length, start + _sliceBytes),
      );
      _queued.add(slice);
      _queuedBytes += slice.length;
    }
    _pump();
  }

  /// Stops the worker and waits for it to let go of its files. Staging stays
  /// as it is, ready to be continued or removed by the caller.
  Future<void> close() async {
    if (!_closing) {
      _closing = true;
      _queued.clear();
      _queuedBytes = 0;
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
      _queuedBytes -= slice.length;
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
