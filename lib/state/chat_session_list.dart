import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/web_transfer/web_transfer_visitor.dart';

class ChatSessionPreviewStrings {
  const ChatSessionPreviewStrings({
    required this.connectedNow,
    required this.nearbyAvailable,
    required this.noMessagesYet,
    required this.sharedFile,
    required this.connectedByWeb,
  });

  final String connectedNow;
  final String nearbyAvailable;
  final String noMessagesYet;
  final String sharedFile;
  final String connectedByWeb;
}

class ChatSessionItem {
  const ChatSessionItem({
    required this.device,
    required this.latestMessage,
    required this.preview,
    required this.lastTimestamp,
    required this.isConnected,
    required this.isNearby,
    required this.hasHistory,
    this.isSelf = false,
    this.isWebOnline = false,
  });

  final DeviceData device;
  final MessageData? latestMessage;
  final String preview;
  final int lastTimestamp;
  final bool isConnected;
  final bool isNearby;
  final bool hasHistory;

  /// 本机: this device itself, which nothing connects to.
  final bool isSelf;

  /// A browser's visit (web transfer) whose page is open now. Not
  /// [isConnected], which is for Whisper devices and what they can do.
  final bool isWebOnline;

  /// A browser that visited through web transfer: only a conversation.
  bool get isWeb => isWebVisitorUid(device.uid);

  bool matches(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return true;
    }
    final fields = <String>[
      device.label,
      device.name,
      device.host,
      preview,
      latestMessage?.content ?? '',
      latestMessage?.name ?? '',
    ];
    return fields.any((field) => field.toLowerCase().contains(normalized));
  }
}

class ChatSessionListBuilder {
  const ChatSessionListBuilder._();

  static List<ChatSessionItem> build({
    required List<DeviceData> devices,
    required Map<String, MessageData> latestMessages,
    String? activePeerId,
    Set<String> connectedPeerIds = const <String>{},
    String? selectedPeerId,
    String? selfUid,
    Set<String> webOnline = const <String>{},
    required ChatSessionPreviewStrings strings,
  }) {
    final connected = <String>{
      ...connectedPeerIds,
      if (activePeerId?.isNotEmpty ?? false) activePeerId!,
    };
    final sessions = devices
        .where(
          (device) =>
              device.uid == selfUid ||
              connected.contains(device.uid) ||
              webOnline.contains(device.uid) ||
              device.around == true ||
              device.auth ||
              latestMessages.containsKey(device.uid),
        )
        .map(
          (device) => _buildItem(
            device: device,
            latestMessage: latestMessages[device.uid],
            connectedPeerIds: connected,
            strings: strings,
            isSelf: device.uid == selfUid,
            isWebOnline: webOnline.contains(device.uid),
          ),
        )
        .toList(growable: false);

    final sorted = sessions.toList(growable: false)
      ..sort((a, b) {
        final statusCompare = _rank(a).compareTo(_rank(b));
        if (statusCompare != 0) {
          return statusCompare;
        }
        final timestampCompare = b.lastTimestamp.compareTo(a.lastTimestamp);
        if (timestampCompare != 0) {
          return timestampCompare;
        }
        return a.device.label.toLowerCase().compareTo(
          b.device.label.toLowerCase(),
        );
      });
    return sorted;
  }

  static List<ChatSessionItem> filter(
    List<ChatSessionItem> sessions,
    String query,
  ) {
    return sessions
        .where((item) => item.matches(query))
        .toList(growable: false);
  }

  static ChatSessionItem _buildItem({
    required DeviceData device,
    required MessageData? latestMessage,
    required Set<String> connectedPeerIds,
    required ChatSessionPreviewStrings strings,
    bool isSelf = false,
    bool isWebOnline = false,
  }) {
    final isConnected = connectedPeerIds.contains(device.uid);
    final isNearby = device.around == true;
    final hasHistory = latestMessage != null;
    final lastTimestamp = latestMessage?.timestamp ?? device.lastTime;

    return ChatSessionItem(
      device: device,
      latestMessage: latestMessage,
      preview: _previewFor(
        latestMessage: latestMessage,
        isConnected: isConnected,
        isNearby: isNearby,
        isWebOnline: isWebOnline,
        strings: strings,
      ),
      lastTimestamp: lastTimestamp,
      isConnected: isConnected,
      isNearby: isNearby,
      hasHistory: hasHistory,
      isSelf: isSelf,
      isWebOnline: isWebOnline,
    );
  }

  static int _rank(ChatSessionItem item) {
    if (item.isConnected || item.isWebOnline) {
      return 0;
    }
    if (item.isNearby || item.isSelf) {
      return 1;
    }
    return 2;
  }

  static String _previewFor({
    required MessageData? latestMessage,
    required bool isConnected,
    required bool isNearby,
    required bool isWebOnline,
    required ChatSessionPreviewStrings strings,
  }) {
    if (latestMessage != null) {
      if (latestMessage.type == MessageEnum.File) {
        return latestMessage.name.isNotEmpty
            ? latestMessage.name
            : strings.sharedFile;
      }
      final content = (latestMessage.content ?? '').trim();
      if (content.isNotEmpty) {
        return content.replaceAll('\n', ' ');
      }
    }
    if (isConnected) {
      return strings.connectedNow;
    }
    if (isWebOnline) {
      return strings.connectedByWeb;
    }
    if (isNearby) {
      return strings.nearbyAvailable;
    }
    return strings.noMessagesYet;
  }
}
