import 'package:flutter/services.dart';

const int androidSystemShareMaxItemsPerEvent = 64;
const int androidSystemShareMaxTextLength = 256 * 1024;
const int androidSystemShareMaxPendingEvents = 16;
const String androidSystemShareFileProviderAuthority =
    'com.vireen.whisper.system_share_files';

const MethodChannel _androidSystemShareChannel = MethodChannel(
  'com.vireen.whisper/android_system_share',
);

typedef AndroidSystemShareIntentHandler =
    Future<void> Function(AndroidSystemShareFailure? failure);

enum AndroidSystemShareFailureReason {
  queueFull,
  tooManyItems,
  textTooLarge,
  itemTooLarge,
  itemUnavailable,
  invalidContent,
  unknown,
}

class AndroidSystemShareFailure {
  const AndroidSystemShareFailure({
    required this.reason,
    required this.receivedAt,
  });

  final AndroidSystemShareFailureReason reason;
  final int receivedAt;

  static AndroidSystemShareFailure? fromMap(Map<Object?, Object?> map) {
    final code = (map['code'] as String?)?.trim() ?? '';
    final reason = switch (code) {
      'queue_full' => AndroidSystemShareFailureReason.queueFull,
      'too_many_items' => AndroidSystemShareFailureReason.tooManyItems,
      'text_too_large' => AndroidSystemShareFailureReason.textTooLarge,
      'item_too_large' => AndroidSystemShareFailureReason.itemTooLarge,
      'item_unavailable' => AndroidSystemShareFailureReason.itemUnavailable,
      'invalid_content' => AndroidSystemShareFailureReason.invalidContent,
      '' => null,
      _ => AndroidSystemShareFailureReason.unknown,
    };
    if (reason == null) {
      return null;
    }
    return AndroidSystemShareFailure(
      reason: reason,
      receivedAt: (map['receivedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class AndroidSystemShareItem {
  const AndroidSystemShareItem({
    required this.uri,
    required this.displayName,
    required this.mimeType,
    required this.size,
  });

  final String uri;
  final String displayName;
  final String mimeType;
  final int? size;

  static AndroidSystemShareItem? fromMap(Map<Object?, Object?> map) {
    final uri = map['uri'] as String? ?? '';
    final parsedUri = Uri.tryParse(uri);
    if (parsedUri == null || parsedUri.scheme != 'content') {
      return null;
    }
    final rawSize = (map['size'] as num?)?.toInt();
    return AndroidSystemShareItem(
      uri: uri,
      displayName: (map['displayName'] as String?)?.trim().isNotEmpty == true
          ? (map['displayName'] as String).trim()
          : (parsedUri.pathSegments.isEmpty
                ? 'shared-item'
                : parsedUri.pathSegments.last),
      mimeType: map['mimeType'] as String? ?? '',
      size: rawSize != null && rawSize >= 0 ? rawSize : null,
    );
  }
}

class AndroidSystemShareEvent {
  const AndroidSystemShareEvent({
    required this.id,
    required this.action,
    required this.mimeType,
    required this.text,
    required this.items,
    required this.receivedAt,
    this.targetPeerId = '',
    this.targetPublicKeyHash = '',
    this.textSent = false,
    this.waitingForConnection = false,
    this.sentItemUris = const <String>[],
  });

  final String id;
  final String action;
  final String mimeType;
  final String text;
  final List<AndroidSystemShareItem> items;
  final int receivedAt;
  final String targetPeerId;
  final String targetPublicKeyHash;
  final bool textSent;
  final bool waitingForConnection;
  final List<String> sentItemUris;

  bool get hasContent => text.isNotEmpty || items.isNotEmpty;

  static AndroidSystemShareEvent? fromMap(Map<Object?, Object?> map) {
    final id = (map['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) {
      return null;
    }
    final rawItems = (map['items'] as List<Object?>?) ?? const <Object?>[];
    final rawText = map['text'] as String? ?? '';
    if (rawItems.length > androidSystemShareMaxItemsPerEvent ||
        rawText.length > androidSystemShareMaxTextLength) {
      return null;
    }
    final itemsByUri = <String, AndroidSystemShareItem>{};
    for (final value in rawItems) {
      if (value is! Map<Object?, Object?>) {
        continue;
      }
      final item = AndroidSystemShareItem.fromMap(value);
      if (item != null) {
        itemsByUri.putIfAbsent(item.uri, () => item);
      }
    }
    final validItemUris = itemsByUri.keys.toSet();
    final rawSentItemUris =
        (map['sentItemUris'] as List<Object?>?) ?? const <Object?>[];
    if (rawSentItemUris.length > androidSystemShareMaxItemsPerEvent) {
      return null;
    }
    final sentItemUris = <String>[];
    for (final value in rawSentItemUris) {
      if (value is String &&
          validItemUris.contains(value) &&
          !sentItemUris.contains(value)) {
        sentItemUris.add(value);
      }
    }
    final targetPeerId = (map['targetPeerId'] as String? ?? '').trim();
    final targetPublicKeyHash = (map['targetPublicKeyHash'] as String? ?? '')
        .trim();
    if ((targetPeerId.isEmpty && targetPublicKeyHash.isNotEmpty) ||
        (targetPublicKeyHash.isNotEmpty &&
            !_isCanonicalIdentityHash(targetPublicKeyHash))) {
      return null;
    }
    final event = AndroidSystemShareEvent(
      id: id,
      action: map['action'] as String? ?? '',
      mimeType: map['mimeType'] as String? ?? '',
      text: rawText,
      items: List<AndroidSystemShareItem>.unmodifiable(itemsByUri.values),
      receivedAt: (map['receivedAt'] as num?)?.toInt() ?? 0,
      targetPeerId: targetPeerId,
      targetPublicKeyHash: targetPublicKeyHash,
      textSent: map['textSent'] as bool? ?? false,
      waitingForConnection: map['waitingForConnection'] as bool? ?? false,
      sentItemUris: List<String>.unmodifiable(sentItemUris),
    );
    return event.hasContent ? event : null;
  }

  AndroidSystemShareEvent copyWithProgress({
    required String targetPeerId,
    required String targetPublicKeyHash,
    required bool textSent,
    required bool waitingForConnection,
    required Iterable<String> sentItemUris,
  }) {
    final validItemUris = items.map((item) => item.uri).toSet();
    return AndroidSystemShareEvent(
      id: id,
      action: action,
      mimeType: mimeType,
      text: text,
      items: items,
      receivedAt: receivedAt,
      targetPeerId: targetPeerId.trim(),
      targetPublicKeyHash: targetPublicKeyHash.trim(),
      textSent: textSent,
      waitingForConnection: waitingForConnection,
      sentItemUris: List<String>.unmodifiable(
        sentItemUris.where(validItemUris.contains).toSet(),
      ),
    );
  }
}

abstract class AndroidSystemSharePlatform {
  void setShareIntentHandler(AndroidSystemShareIntentHandler? handler);

  Future<List<AndroidSystemShareEvent>> consumePendingShares();

  Future<List<AndroidSystemShareFailure>> consumePendingShareFailures() async =>
      const <AndroidSystemShareFailure>[];

  Future<void> updatePendingShareProgress({
    required String eventId,
    required String peerId,
    required String publicKeyHash,
    required bool textSent,
    required bool waitingForConnection,
    required Iterable<String> sentItemUris,
  }) async {}

  Future<void> completePendingShare(String eventId) async {}

  Future<void> discardPendingShare(String eventId) async {}
}

class MethodChannelAndroidSystemSharePlatform
    implements AndroidSystemSharePlatform {
  MethodChannelAndroidSystemSharePlatform({
    MethodChannel channel = _androidSystemShareChannel,
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  void setShareIntentHandler(AndroidSystemShareIntentHandler? handler) {
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shareIntentReceived') {
        await handler(null);
      } else if (call.method == 'shareIntentRejected') {
        final arguments = call.arguments;
        final failure = arguments is Map<Object?, Object?>
            ? AndroidSystemShareFailure.fromMap(arguments)
            : null;
        await handler(failure);
      }
    });
  }

  @override
  Future<List<AndroidSystemShareEvent>> consumePendingShares() async {
    final values = await _channel.invokeListMethod<Object?>(
      'consumePendingShares',
    );
    if (values == null) {
      return const <AndroidSystemShareEvent>[];
    }
    return values
        .whereType<Map<Object?, Object?>>()
        .map(AndroidSystemShareEvent.fromMap)
        .whereType<AndroidSystemShareEvent>()
        .toList(growable: false);
  }

  @override
  Future<List<AndroidSystemShareFailure>> consumePendingShareFailures() async {
    final values = await _channel.invokeListMethod<Object?>(
      'consumePendingShareFailures',
    );
    if (values == null) {
      return const <AndroidSystemShareFailure>[];
    }
    return values
        .whereType<Map<Object?, Object?>>()
        .map(AndroidSystemShareFailure.fromMap)
        .whereType<AndroidSystemShareFailure>()
        .toList(growable: false);
  }

  @override
  Future<void> updatePendingShareProgress({
    required String eventId,
    required String peerId,
    required String publicKeyHash,
    required bool textSent,
    required bool waitingForConnection,
    required Iterable<String> sentItemUris,
  }) {
    return _channel
        .invokeMethod<void>('updatePendingShareProgress', <String, Object?>{
          'eventId': eventId,
          'peerId': peerId,
          'publicKeyHash': publicKeyHash,
          'textSent': textSent,
          'waitingForConnection': waitingForConnection,
          'sentItemUris': sentItemUris.toList(growable: false),
        });
  }

  @override
  Future<void> completePendingShare(String eventId) {
    return _channel.invokeMethod<void>(
      'completePendingShare',
      <String, Object?>{'eventId': eventId},
    );
  }

  @override
  Future<void> discardPendingShare(String eventId) {
    return _channel.invokeMethod<void>('discardPendingShare', <String, Object?>{
      'eventId': eventId,
    });
  }
}

bool _isCanonicalIdentityHash(String value) {
  return value.length == 43 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
}

bool isAndroidSystemShareStagedUri(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'content' &&
      uri.authority == androidSystemShareFileProviderAuthority &&
      uri.pathSegments.length == 3 &&
      uri.pathSegments.first == 'android_system_shares';
}

Future<void> releaseAndroidSystemShareStagedItem(String uri) async {
  if (!isAndroidSystemShareStagedUri(uri)) {
    return;
  }
  try {
    await _androidSystemShareChannel.invokeMethod<void>(
      'releaseStagedShareItem',
      <String, Object?>{'uri': uri},
    );
  } on MissingPluginException {
    // Unit tests and non-Android builds do not register the native share plugin.
  } on PlatformException {
    // Staging cleanup is best-effort after a terminal transfer state.
  }
}
