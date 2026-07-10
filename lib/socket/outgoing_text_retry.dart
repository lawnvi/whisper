import 'package:whisper/model/LocalDatabase.dart' show MessageData;
import 'package:whisper/socket/wire_message_replay.dart'
    show hasSameWireMessageIdentity;
import 'package:synchronized/synchronized.dart';

typedef OutgoingTextPersist = Future<MessageData> Function(
  MessageData message,
);

final class PreparedOutgoingText {
  const PreparedOutgoingText({
    required this.message,
    required this.isNew,
  });

  final MessageData message;
  final bool isNew;
}

final class OutgoingTextSendLocks {
  final Map<String, _OutgoingTextSendLockEntry> _entries =
      <String, _OutgoingTextSendLockEntry>{};

  Future<T> synchronized<T>(String peerId, Future<T> Function() action) async {
    final entry = _entries.putIfAbsent(
      peerId,
      _OutgoingTextSendLockEntry.new,
    );
    entry.users++;
    try {
      return await entry.lock.synchronized(action);
    } finally {
      entry.users--;
      if (entry.users == 0 && identical(_entries[peerId], entry)) {
        _entries.remove(peerId);
      }
    }
  }
}

final class _OutgoingTextSendLockEntry {
  final Lock lock = Lock();
  int users = 0;
}

final class OutgoingTextRetryResolution {
  const OutgoingTextRetryResolution({
    required this.message,
    required this.alreadyAcknowledged,
  });

  const OutgoingTextRetryResolution.none()
      : message = null,
        alreadyAcknowledged = false;

  final MessageData? message;
  final bool alreadyAcknowledged;
}

final class OutgoingTextRetryRegistry {
  OutgoingTextRetryRegistry({this.maxEntries = 128}) : assert(maxEntries > 0);

  final int maxEntries;
  final Map<_OutgoingTextIntent, _OutgoingTextRetryEntry> _entriesByIntent =
      <_OutgoingTextIntent, _OutgoingTextRetryEntry>{};

  bool hasRetryForPeer(String peerId) {
    return _entriesByIntent.keys.any((intent) => intent.receiver == peerId);
  }

  void rememberFailure(MessageData message) {
    if (message.receiver.isEmpty || message.uuid.isEmpty) {
      return;
    }
    final intent = _OutgoingTextIntent.fromMessage(message);
    if (!_entriesByIntent.containsKey(intent) &&
        _entriesByIntent.length >= maxEntries) {
      _entriesByIntent.remove(_entriesByIntent.keys.first);
    }
    _entriesByIntent[intent] = _OutgoingTextRetryEntry(message);
  }

  void clearAccepted(MessageData message) {
    final intent = _OutgoingTextIntent.fromMessage(message);
    final entry = _entriesByIntent[intent];
    if (entry?.uuid == message.uuid) {
      _entriesByIntent.remove(intent);
    }
  }

  Future<OutgoingTextRetryResolution> resolve(
    MessageData draft, {
    required Future<List<MessageData>> Function(String uuid) fetchByUuid,
  }) async {
    final intent = _OutgoingTextIntent.fromMessage(draft);
    final entry = _entriesByIntent[intent];
    if (entry == null) {
      return const OutgoingTextRetryResolution.none();
    }
    final candidates = await fetchByUuid(entry.uuid);
    MessageData? stored;
    for (final candidate in candidates) {
      if (entry.matchesStored(candidate)) {
        stored = candidate;
        break;
      }
    }
    if (!identical(_entriesByIntent[intent], entry)) {
      return const OutgoingTextRetryResolution.none();
    }
    if (stored == null) {
      _entriesByIntent.remove(intent);
      return const OutgoingTextRetryResolution.none();
    }
    if (stored.acked) {
      _entriesByIntent.remove(intent);
    }
    return OutgoingTextRetryResolution(
      message: stored,
      alreadyAcknowledged: stored.acked,
    );
  }
}

final class _OutgoingTextIntent {
  const _OutgoingTextIntent({
    required this.sender,
    required this.receiver,
    required this.content,
    required this.clipboard,
  });

  factory _OutgoingTextIntent.fromMessage(MessageData message) {
    return _OutgoingTextIntent(
      sender: message.sender,
      receiver: message.receiver,
      content: message.content ?? '',
      clipboard: message.clipboard,
    );
  }

  final String sender;
  final String receiver;
  final String content;
  final bool clipboard;

  @override
  bool operator ==(Object other) {
    return other is _OutgoingTextIntent &&
        other.sender == sender &&
        other.receiver == receiver &&
        other.content == content &&
        other.clipboard == clipboard;
  }

  @override
  int get hashCode => Object.hash(sender, receiver, content, clipboard);
}

final class _OutgoingTextRetryEntry {
  _OutgoingTextRetryEntry(this.original);

  final MessageData original;

  String get uuid => original.uuid;

  bool matchesStored(MessageData stored) {
    return hasSameWireMessageIdentity(original, stored);
  }
}

Future<PreparedOutgoingText> prepareOutgoingTextWithRetryIdentity({
  required MessageData draft,
  MessageData? retry,
  required OutgoingTextPersist persist,
}) async {
  if (retry != null) {
    return PreparedOutgoingText(message: retry, isNew: false);
  }
  return PreparedOutgoingText(
    message: await persist(draft),
    isNew: true,
  );
}
