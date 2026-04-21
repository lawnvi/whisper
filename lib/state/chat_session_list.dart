import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';

class ChatSessionPreviewStrings {
  const ChatSessionPreviewStrings({
    required this.connectedNow,
    required this.nearbyAvailable,
    required this.noMessagesYet,
    required this.sharedFile,
  });

  final String connectedNow;
  final String nearbyAvailable;
  final String noMessagesYet;
  final String sharedFile;
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
    required this.avatarLabel,
  });

  final DeviceData device;
  final MessageData? latestMessage;
  final String preview;
  final int lastTimestamp;
  final bool isConnected;
  final bool isNearby;
  final bool hasHistory;
  final String avatarLabel;

  bool matches(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return true;
    }
    final fields = <String>[
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
    required String? activePeerId,
    required ChatSessionPreviewStrings strings,
  }) {
    final sessions = devices
        .map(
          (device) => _buildItem(
            device: device,
            latestMessage: latestMessages[device.uid],
            activePeerId: activePeerId,
            strings: strings,
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
        return a.device.name
            .toLowerCase()
            .compareTo(b.device.name.toLowerCase());
      });
    return sorted;
  }

  static List<ChatSessionItem> filter(
      List<ChatSessionItem> sessions, String query) {
    return sessions
        .where((item) => item.matches(query))
        .toList(growable: false);
  }

  static ChatSessionItem _buildItem({
    required DeviceData device,
    required MessageData? latestMessage,
    required String? activePeerId,
    required ChatSessionPreviewStrings strings,
  }) {
    final isConnected = device.uid == activePeerId;
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
        strings: strings,
      ),
      lastTimestamp: lastTimestamp,
      isConnected: isConnected,
      isNearby: isNearby,
      hasHistory: hasHistory,
      avatarLabel: _avatarLabel(device.name),
    );
  }

  static int _rank(ChatSessionItem item) {
    if (item.isConnected) {
      return 0;
    }
    if (item.isNearby) {
      return 1;
    }
    return 2;
  }

  static String _previewFor({
    required MessageData? latestMessage,
    required bool isConnected,
    required bool isNearby,
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
    if (isNearby) {
      return strings.nearbyAvailable;
    }
    return strings.noMessagesYet;
  }

  static String _avatarLabel(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return '?';
    }
    return trimmed.substring(0, 1).toUpperCase();
  }
}
