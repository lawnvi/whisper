import 'dart:async';

typedef ClipboardSuppressionClock = DateTime Function();
typedef ClipboardTextWriter = Future<void> Function(String content);

class ClipboardWriteSuppression {
  const ClipboardWriteSuppression({
    required this.generation,
    required this.sourcePeerId,
    required this.content,
    required this.registeredAt,
  });

  final int generation;
  final String sourcePeerId;
  final String content;
  final DateTime registeredAt;
}

class ClipboardWriteSuppressionQueue {
  ClipboardWriteSuppressionQueue({
    this.capacity = 8,
    this.lifetime = const Duration(seconds: 2),
    ClipboardSuppressionClock? clock,
  }) : _clock = clock ?? DateTime.now {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be positive');
    }
  }

  final int capacity;
  final Duration lifetime;
  final ClipboardSuppressionClock _clock;
  final List<ClipboardWriteSuppression> _entries =
      <ClipboardWriteSuppression>[];
  var _nextGeneration = 0;

  ClipboardWriteSuppression register({
    required String content,
    required String sourcePeerId,
  }) {
    if (sourcePeerId.isEmpty) {
      throw ArgumentError.value(
        sourcePeerId,
        'sourcePeerId',
        'must identify the authenticated remote peer',
      );
    }
    final now = _clock();
    _removeExpired(now);
    final entry = ClipboardWriteSuppression(
      generation: ++_nextGeneration,
      sourcePeerId: sourcePeerId,
      content: content,
      registeredAt: now,
    );
    _entries.add(entry);
    while (_entries.length > capacity) {
      _entries.removeAt(0);
    }
    return entry;
  }

  void cancel(ClipboardWriteSuppression entry) {
    _entries.removeWhere(
      (candidate) => candidate.generation == entry.generation,
    );
  }

  ClipboardWriteSuppression? takeExact(String content) {
    _removeExpired(_clock());
    ClipboardWriteSuppression? match;
    for (var index = _entries.length - 1; index >= 0; index--) {
      final candidate = _entries[index];
      if (candidate.content == content) {
        match = candidate;
        break;
      }
    }
    if (match == null) {
      return null;
    }

    // Observing a newer write makes every older unobserved write stale. This
    // prevents an old value from suppressing a later user copy of that value.
    _entries.removeWhere(
      (candidate) => candidate.generation <= match!.generation,
    );
    return match;
  }

  void _removeExpired(DateTime now) {
    _entries.removeWhere(
      (entry) => now.difference(entry.registeredAt) > lifetime,
    );
  }
}

class ClipboardWriteCoordinator {
  ClipboardWriteCoordinator({
    required ClipboardTextWriter writer,
    ClipboardWriteSuppressionQueue? suppressions,
  }) : _writer = writer,
       suppressions = suppressions ?? ClipboardWriteSuppressionQueue();

  final ClipboardTextWriter _writer;
  final ClipboardWriteSuppressionQueue suppressions;
  Future<void> _writeTail = Future<void>.value();

  Future<void> write(String content, {String? sourcePeerId}) {
    final operation = _writeTail.then((_) async {
      final suppression = sourcePeerId == null
          ? null
          : suppressions.register(content: content, sourcePeerId: sourcePeerId);
      try {
        await _writer(content);
      } catch (_) {
        if (suppression != null) {
          suppressions.cancel(suppression);
        }
        rethrow;
      }
    });
    _writeTail = operation.catchError((Object _) {});
    return operation;
  }
}
