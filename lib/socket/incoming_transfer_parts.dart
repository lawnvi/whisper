import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:whisper/socket/folder_transfer_sink.dart';

/// Writes what arrives for one transfer in order, without making the frame
/// that brought it wait for the disk. An error is kept and raised by
/// [drain].
final class IncomingWritePipeline {
  IncomingWritePipeline({required this.writtenOffset});

  Future<void> _tail = Future<void>.value();
  Object? _error;
  StackTrace? _stackTrace;
  int writtenOffset;

  void add(
    RandomAccessFile writer,
    Uint8List payload, {
    required int endOffset,
  }) {
    _tail = _tail.then((_) async {
      if (_error != null) {
        return;
      }
      try {
        await writer.writeFrom(payload);
        writtenOffset = endOffset;
      } catch (error, stackTrace) {
        _error = error;
        _stackTrace = stackTrace;
      }
    });
  }

  Future<void> drain() async {
    await _tail;
    final error = _error;
    if (error != null) {
      Error.throwWithStackTrace(error, _stackTrace ?? StackTrace.current);
    }
  }
}

/// When a receiver says how far it has got. By bytes alone (the interval
/// agreed with the sender, 32 MiB between computers) a slow link goes a long
/// time without a word, and the sender takes the silence for a peer that is
/// gone and disconnects. So while data keeps coming it also answers once
/// [every], which lets the sender see how fast the link really is.
final class IncomingAckClock {
  IncomingAckClock({
    this.every = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Receivers on this protocol version or later answer this way.
  static const sinceProtocolVersion = 13;

  final Duration every;
  final DateTime Function() _now;
  final Map<String, DateTime> _since = <String, DateTime>{};

  /// Whether [received] bytes, against [answered] when it last said so,
  /// call for an answer now.
  bool due(
    String transferId, {
    required int received,
    required int answered,
    required int interval,
  }) {
    if (received <= answered) return false;
    if (received - answered >= interval) return true;
    final since = _since.putIfAbsent(transferId, _now);
    return _now().difference(since) >= every;
  }

  final Map<String, Timer> _reminders = <String, Timer>{};

  /// Calls [answer] once [every] has passed since the last answer, unless
  /// one goes first: a sender holding back until it hears must not wait for
  /// a frame that will not come.
  void remind(String transferId, void Function() answer) {
    if (_reminders.containsKey(transferId)) return;
    final since = _since[transferId] ?? _now();
    final wait = every - _now().difference(since);
    _reminders[transferId] = Timer(wait.isNegative ? Duration.zero : wait, () {
      _reminders.remove(transferId);
      answer();
    });
  }

  void answered(String transferId) {
    _since[transferId] = _now();
    _reminders.remove(transferId)?.cancel();
  }

  void forget(String transferId) {
    _since.remove(transferId);
    _reminders.remove(transferId)?.cancel();
  }
}

/// A folder being received: its worker and what has been acknowledged.
final class IncomingFolder {
  IncomingFolder({required this.session, required this.ackedOffset});

  final FolderReceiveSession session;
  int ackedOffset;
  bool ackPending = false;

  /// Repeats the last acknowledgement while the worker is busy, see
  /// the engine.
  Timer? keepAlive;
  bool acknowledgedSinceKeepAlive = false;

  /// Whether the sender was told to send in this session. It was not if
  /// staging already held the whole folder.
  bool announced = false;
}
