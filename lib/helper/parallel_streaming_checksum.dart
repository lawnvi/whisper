import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:whisper/helper/native_streaming_sha256.dart';

final class ParallelStreamingChecksum {
  ParallelStreamingChecksum._({
    required Isolate isolate,
    required SendPort commandPort,
    required Completer<String> result,
    required Completer<void> exited,
    required _ChecksumBackpressure backpressure,
  }) : _isolate = isolate,
       _commandPort = commandPort,
       _result = result,
       _exited = exited,
       _backpressure = backpressure;

  static Future<ParallelStreamingChecksum> start({
    String algorithm = 'sha256',
    int maxPendingBytes = 8 * 1024 * 1024,
  }) async {
    if (algorithm != 'sha256') {
      throw ArgumentError.value(
        algorithm,
        'algorithm',
        'Unsupported parallel checksum algorithm',
      );
    }
    if (maxPendingBytes <= 0) {
      throw ArgumentError.value(maxPendingBytes, 'maxPendingBytes');
    }
    final backpressure = _ChecksumBackpressure(maxPendingBytes);
    final eventPort = ReceivePort();
    final exitPort = ReceivePort();
    final ready = Completer<SendPort>();
    final result = Completer<String>();
    final exited = Completer<void>();
    // Keep early worker failures observable through close(), without an
    // unhandled asynchronous error while the producer is still sending data.
    unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    late final StreamSubscription<Object?> eventSubscription;
    eventSubscription = eventPort.listen((message) {
      if (message is SendPort && !ready.isCompleted) {
        ready.complete(message);
        return;
      }
      if (message is List<Object?> && message.isNotEmpty) {
        switch (message.first) {
          case 'processed':
            backpressure.acknowledge(message[1]! as int);
          case 'result':
            if (!result.isCompleted) {
              result.complete(message[1]! as String);
            }
          case 'error':
            final error = StateError(message[1]! as String);
            final stackTrace = StackTrace.fromString(message[2]! as String);
            backpressure.stop(error, stackTrace);
            if (!ready.isCompleted) {
              ready.completeError(error, stackTrace);
            } else if (!result.isCompleted) {
              result.completeError(error, stackTrace);
            }
          default:
            if (message.length >= 2 && !ready.isCompleted) {
              ready.completeError(
                StateError('${message.first}'),
                StackTrace.fromString('${message[1]}'),
              );
            }
        }
      }
    });
    final exitSubscription = exitPort.listen((_) {
      backpressure.stop(StateError('Parallel checksum worker exited'));
      if (!exited.isCompleted) {
        exited.complete();
      }
      if (!ready.isCompleted) {
        ready.completeError(
          StateError('Parallel checksum worker exited before initialization'),
        );
      }
    });
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<(SendPort, String)>(
        _parallelChecksumWorker,
        (eventPort.sendPort, algorithm),
        onError: eventPort.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: true,
      );
      final commandPort = await ready.future;
      unawaited(
        exited.future.whenComplete(() async {
          await eventSubscription.cancel();
          await exitSubscription.cancel();
          eventPort.close();
          exitPort.close();
          if (!result.isCompleted) {
            result.completeError(
              StateError('Parallel checksum worker exited without a result'),
            );
          }
        }),
      );
      return ParallelStreamingChecksum._(
        isolate: isolate,
        commandPort: commandPort,
        result: result,
        exited: exited,
        backpressure: backpressure,
      );
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      await eventSubscription.cancel();
      await exitSubscription.cancel();
      eventPort.close();
      exitPort.close();
      rethrow;
    }
  }

  final Isolate _isolate;
  final SendPort _commandPort;
  final Completer<String> _result;
  final Completer<void> _exited;
  final _ChecksumBackpressure _backpressure;

  int get pendingBytes => _backpressure.pendingBytes;
  bool _closed = false;

  Future<void> add(List<int> bytes) async {
    if (_closed) {
      throw StateError('Cannot add bytes after checksum is closed');
    }
    if (bytes.isEmpty) {
      return;
    }
    final typed = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    _backpressure.pendingBytes += typed.length;
    _commandPort.send(<Object?>[
      'data',
      TransferableTypedData.fromList(<TypedData>[typed]),
    ]);
    await _backpressure.waitForCapacity();
  }

  Future<String> close() async {
    if (!_closed) {
      _closed = true;
      _commandPort.send(const <Object?>['close']);
    }
    final digest = await _result.future;
    await _exited.future;
    return digest;
  }

  Future<void> dispose() async {
    _backpressure.stop(StateError('Parallel checksum was disposed'));
    if (!_closed) {
      _closed = true;
      if (!_result.isCompleted) {
        _result.complete('');
      }
      _commandPort.send(const <Object?>['abort']);
    }
    try {
      await _exited.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      _isolate.kill(priority: Isolate.immediate);
    }
  }
}

void _parallelChecksumWorker((SendPort, String) bootstrap) {
  final (eventPort, algorithm) = bootstrap;
  final commands = ReceivePort();
  NativeStreamingSha256? checksum;
  try {
    if (algorithm != 'sha256') {
      throw ArgumentError.value(algorithm, 'algorithm');
    }
    checksum = NativeStreamingSha256();
    eventPort.send(commands.sendPort);
    commands.listen((message) {
      try {
        if (message is! List<Object?> || message.isEmpty) {
          throw const FormatException('Invalid checksum worker message');
        }
        switch (message.first) {
          case 'data':
            final data = message[1]! as TransferableTypedData;
            final bytes = data.materialize().asUint8List();
            checksum!.add(bytes);
            eventPort.send(<Object?>['processed', bytes.length]);
          case 'close':
            eventPort.send(<Object?>['result', checksum!.close()]);
            checksum = null;
            commands.close();
          case 'abort':
            checksum?.dispose();
            checksum = null;
            commands.close();
          default:
            throw const FormatException('Unknown checksum worker message');
        }
      } catch (error, stackTrace) {
        checksum?.dispose();
        checksum = null;
        eventPort.send(<Object?>['error', '$error', '$stackTrace']);
        commands.close();
      }
    });
  } catch (error, stackTrace) {
    checksum?.dispose();
    eventPort.send(<Object?>['error', '$error', '$stackTrace']);
    commands.close();
  }
}

/// A producer awaiting add() can get at most one chunk ahead of this limit.
final class _ChecksumBackpressure {
  _ChecksumBackpressure(this.limit);

  final int limit;
  int pendingBytes = 0;
  Completer<void>? _capacity;
  Object? _error;
  StackTrace? _stackTrace;

  Future<void> waitForCapacity() async {
    if (_error case final error?) {
      Error.throwWithStackTrace(error, _stackTrace ?? StackTrace.current);
    }
    if (pendingBytes >= limit) {
      await (_capacity ??= Completer<void>()).future;
    }
  }

  void acknowledge(int bytes) {
    pendingBytes -= bytes;
    if (pendingBytes < limit && _capacity != null) {
      _capacity!.complete();
      _capacity = null;
    }
  }

  void stop(Object error, [StackTrace? stackTrace]) {
    _error ??= error;
    _stackTrace ??= stackTrace;
    _capacity?.completeError(error, stackTrace ?? StackTrace.current);
    _capacity = null;
  }
}
