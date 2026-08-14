import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:whisper/helper/native_streaming_sha256.dart';

final class ParallelStreamingChecksum {
  ParallelStreamingChecksum._({
    required Isolate isolate,
    required SendPort commandPort,
    required ReceivePort eventPort,
    required ReceivePort exitPort,
    required StreamSubscription<Object?> eventSubscription,
    required Completer<String> result,
    required Completer<void> exited,
  }) : _isolate = isolate,
       _commandPort = commandPort,
       _eventPort = eventPort,
       _exitPort = exitPort,
       _eventSubscription = eventSubscription,
       _result = result,
       _exited = exited;

  static Future<ParallelStreamingChecksum> start({
    String algorithm = 'sha256',
  }) async {
    if (algorithm != 'sha256') {
      throw ArgumentError.value(
        algorithm,
        'algorithm',
        'Unsupported parallel checksum algorithm',
      );
    }
    final eventPort = ReceivePort();
    final exitPort = ReceivePort();
    final ready = Completer<SendPort>();
    final result = Completer<String>();
    final exited = Completer<void>();
    late final StreamSubscription<Object?> eventSubscription;
    eventSubscription = eventPort.listen((message) {
      if (message is SendPort && !ready.isCompleted) {
        ready.complete(message);
        return;
      }
      if (message is List<Object?> && message.isNotEmpty) {
        switch (message.first) {
          case 'result':
            if (!result.isCompleted) {
              result.complete(message[1]! as String);
            }
          case 'error':
            final error = StateError(message[1]! as String);
            final stackTrace = StackTrace.fromString(message[2]! as String);
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
        eventPort: eventPort,
        exitPort: exitPort,
        eventSubscription: eventSubscription,
        result: result,
        exited: exited,
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
  final ReceivePort _eventPort;
  final ReceivePort _exitPort;
  final StreamSubscription<Object?> _eventSubscription;
  final Completer<String> _result;
  final Completer<void> _exited;
  bool _closed = false;

  void add(List<int> bytes) {
    if (_closed) {
      throw StateError('Cannot add bytes after checksum is closed');
    }
    if (bytes.isEmpty) {
      return;
    }
    final typed = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    _commandPort.send(<Object?>[
      'data',
      TransferableTypedData.fromList(<TypedData>[typed]),
    ]);
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
            checksum!.add(data.materialize().asUint8List());
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
