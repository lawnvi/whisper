import 'dart:async';

import 'package:uuid/uuid.dart';
import 'package:whisper/model/LocalDatabase.dart' show MessageData;
import 'package:whisper/socket/wire_message_replay.dart'
    show hasSameWireMessageIdentity;
import 'package:synchronized/synchronized.dart';

String stableQuickSendMessageId({
  required String source,
  required String intentId,
  required String peerId,
}) {
  if (source.trim().isEmpty ||
      intentId.trim().isEmpty ||
      peerId.trim().isEmpty) {
    throw ArgumentError('quick-send identity fields must not be empty');
  }
  return const Uuid().v5(
    Namespace.url.value,
    'https://whisper.local/quick-send/$source/$intentId/$peerId',
  );
}

final class OutgoingTextAcknowledgementTracker {
  final Map<
    _OutgoingTextAcknowledgementKey,
    Set<OutgoingTextAcknowledgementTicket>
  >
  _tickets =
      <
        _OutgoingTextAcknowledgementKey,
        Set<OutgoingTextAcknowledgementTicket>
      >{};

  int get pendingCount =>
      _tickets.values.fold(0, (total, values) => total + values.length);

  OutgoingTextAcknowledgementTicket waitFor({
    required String peerId,
    required String messageId,
    required Duration timeout,
  }) {
    if (peerId.isEmpty || messageId.isEmpty || timeout <= Duration.zero) {
      throw ArgumentError('invalid acknowledgement waiter');
    }
    final key = _OutgoingTextAcknowledgementKey(peerId, messageId);
    late final OutgoingTextAcknowledgementTicket ticket;
    ticket = OutgoingTextAcknowledgementTicket._(
      onCancel: () => _complete(key, ticket, false),
    );
    _tickets
        .putIfAbsent(key, () => <OutgoingTextAcknowledgementTicket>{})
        .add(ticket);
    ticket._timer = Timer(timeout, () => _complete(key, ticket, false));
    return ticket;
  }

  void acknowledge(String peerId, String messageId) {
    final key = _OutgoingTextAcknowledgementKey(peerId, messageId);
    for (final ticket in List<OutgoingTextAcknowledgementTicket>.of(
      _tickets[key] ?? const <OutgoingTextAcknowledgementTicket>{},
    )) {
      _complete(key, ticket, true);
    }
  }

  void disconnectPeer(String peerId) {
    final keys = _tickets.keys
        .where((key) => key.peerId == peerId)
        .toList(growable: false);
    for (final key in keys) {
      for (final ticket in List<OutgoingTextAcknowledgementTicket>.of(
        _tickets[key] ?? const <OutgoingTextAcknowledgementTicket>{},
      )) {
        _complete(key, ticket, false);
      }
    }
  }

  void clear() {
    final entries = _tickets.entries.toList(growable: false);
    for (final entry in entries) {
      for (final ticket in List<OutgoingTextAcknowledgementTicket>.of(
        entry.value,
      )) {
        _complete(entry.key, ticket, false);
      }
    }
  }

  void _complete(
    _OutgoingTextAcknowledgementKey key,
    OutgoingTextAcknowledgementTicket ticket,
    bool acknowledged,
  ) {
    final values = _tickets[key];
    if (values == null || !values.remove(ticket)) {
      return;
    }
    if (values.isEmpty) {
      _tickets.remove(key);
    }
    ticket._complete(acknowledged);
  }
}

final class OutgoingTextAcknowledgementTicket {
  OutgoingTextAcknowledgementTicket._({required void Function() onCancel})
    : _onCancel = onCancel;

  final Completer<bool> _completer = Completer<bool>();
  final void Function() _onCancel;
  Timer? _timer;

  Future<bool> get future => _completer.future;

  void cancel() => _onCancel();

  void _complete(bool acknowledged) {
    _timer?.cancel();
    _timer = null;
    if (!_completer.isCompleted) {
      _completer.complete(acknowledged);
    }
  }
}

final class _OutgoingTextAcknowledgementKey {
  const _OutgoingTextAcknowledgementKey(this.peerId, this.messageId);

  final String peerId;
  final String messageId;

  @override
  bool operator ==(Object other) =>
      other is _OutgoingTextAcknowledgementKey &&
      other.peerId == peerId &&
      other.messageId == messageId;

  @override
  int get hashCode => Object.hash(peerId, messageId);
}

typedef OutgoingTextPersist = Future<MessageData> Function(MessageData message);

final class PreparedOutgoingText {
  const PreparedOutgoingText({required this.message, required this.isNew});

  final MessageData message;
  final bool isNew;
}

final class OutgoingTextSendLocks {
  final Map<String, _OutgoingTextSendLockEntry> _entries =
      <String, _OutgoingTextSendLockEntry>{};

  Future<T> synchronized<T>(String peerId, Future<T> Function() action) async {
    final entry = _entries.putIfAbsent(peerId, _OutgoingTextSendLockEntry.new);
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

  void clearPeer(String peerId) {
    if (peerId.isEmpty) {
      return;
    }
    _entriesByIntent.removeWhere((intent, _) => intent.receiver == peerId);
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
  return PreparedOutgoingText(message: await persist(draft), isNew: true);
}
