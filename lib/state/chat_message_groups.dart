import 'dart:convert';

import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';

class ChatMessageGroup {
  ChatMessageGroup({
    required this.startIndex,
    required List<MessageData> messages,
  }) : messages = List<MessageData>.unmodifiable(messages);

  final int startIndex;
  final List<MessageData> messages;

  int get endIndex => startIndex + messages.length - 1;

  // Message queries are newest-first, so the first item is the visual tail.
  int get tailIndex => startIndex;

  bool containsIndex(int index) => index >= startIndex && index <= endIndex;
}

List<ChatMessageGroup> groupChatMessages(
  List<MessageData> messages, {
  Duration threshold = const Duration(minutes: 5),
}) {
  assert(!threshold.isNegative);
  if (messages.isEmpty) {
    return const <ChatMessageGroup>[];
  }

  final groups = <ChatMessageGroup>[];
  var startIndex = 0;
  var currentMessages = <MessageData>[messages.first];

  for (var index = 1; index < messages.length; index++) {
    final previous = messages[index - 1];
    final current = messages[index];
    if (_canShareVisualGroup(previous, current, threshold)) {
      currentMessages.add(current);
      continue;
    }
    groups.add(
      ChatMessageGroup(startIndex: startIndex, messages: currentMessages),
    );
    startIndex = index;
    currentMessages = <MessageData>[current];
  }

  groups.add(
    ChatMessageGroup(startIndex: startIndex, messages: currentMessages),
  );
  return List<ChatMessageGroup>.unmodifiable(groups);
}

bool _canShareVisualGroup(
  MessageData first,
  MessageData second,
  Duration threshold,
) {
  if (first.type == MessageEnum.File || second.type == MessageEnum.File) {
    return false;
  }
  if (first.sender != second.sender) {
    return false;
  }
  return (first.timestamp - second.timestamp).abs() <= threshold.inSeconds;
}

String chatMessageDisplayText(MessageData message) {
  final content = message.content ?? '';
  if (message.type != MessageEnum.Notification) {
    return content;
  }
  try {
    final data = jsonDecode(content);
    if (data is! Map) {
      return content;
    }
    final app = data['app']?.toString() ?? '';
    final title = data['title']?.toString() ?? '';
    final text = data['text']?.toString() ?? '';
    return '【$app】$title\n$text';
  } on FormatException {
    return content;
  }
}

List<MessageData> uniqueChatMessagesForInsertion(
  List<MessageData> existing,
  Iterable<MessageData> incoming,
) {
  final seen = <String>{
    for (final message in existing)
      if (_messageIdentity(message) case final identity?) identity,
  };
  final unique = <MessageData>[];
  for (final message in incoming) {
    final identity = _messageIdentity(message);
    if (identity != null && !seen.add(identity)) {
      continue;
    }
    unique.add(message);
  }
  return List<MessageData>.unmodifiable(unique);
}

String? _messageIdentity(MessageData message) {
  if (message.uuid.isNotEmpty) {
    return 'uuid:${message.uuid}';
  }
  if (message.id > 0) {
    return 'id:${message.id}';
  }
  return null;
}
