import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/state/chat_session_list.dart';

DeviceData buildDevice(
  String uid, {
  required String name,
  required String host,
  bool around = false,
  int lastTime = 0,
}) {
  return DeviceData(
    id: 0,
    uid: uid,
    name: name,
    host: host,
    port: 10002,
    password: '',
    platform: 'linux',
    isServer: false,
    online: false,
    clipboard: false,
    auth: false,
    lastTime: lastTime,
    around: around,
  );
}

MessageData buildMessage(
  String peerId, {
  required String content,
  required int timestamp,
  MessageEnum type = MessageEnum.Text,
  String name = '',
}) {
  return MessageData(
    id: timestamp,
    deviceId: null,
    sender: peerId,
    receiver: '',
    name: name,
    clipboard: false,
    size: 0,
    type: type,
    content: content,
    message: '',
    timestamp: timestamp,
    uuid: 'uuid-$timestamp',
    acked: true,
    path: '',
    md5: '',
    fileTimestamp: 0,
  );
}

void main() {
  const strings = ChatSessionPreviewStrings(
    connectedNow: 'Connected now',
    nearbyAvailable: 'Available nearby',
    noMessagesYet: 'No messages yet',
    sharedFile: 'Shared a file',
  );

  group('ChatSessionListBuilder', () {
    test('sorts connected first, then nearby, then historical sessions', () {
      final sessions = ChatSessionListBuilder.build(
        devices: [
          buildDevice('history', name: 'History', host: '192.168.1.30'),
          buildDevice(
            'nearby',
            name: 'Nearby',
            host: '192.168.1.20',
            around: true,
          ),
          buildDevice(
            'connected',
            name: 'Connected',
            host: '192.168.1.10',
            around: true,
          ),
        ],
        latestMessages: {
          'history': buildMessage(
            'history',
            content: 'latest history message',
            timestamp: 300,
          ),
          'nearby': buildMessage(
            'nearby',
            content: 'latest nearby message',
            timestamp: 200,
          ),
        },
        activePeerId: 'connected',
        strings: strings,
      );

      expect(sessions.map((item) => item.device.uid).toList(), [
        'connected',
        'nearby',
        'history',
      ]);
    });

    test('uses short localized status preview when a device has no messages',
        () {
      final sessions = ChatSessionListBuilder.build(
        devices: [
          buildDevice(
            'connected',
            name: 'Connected',
            host: '192.168.1.10',
            around: true,
          ),
          buildDevice(
            'nearby',
            name: 'Nearby',
            host: '192.168.1.20',
            around: true,
          ),
          buildDevice(
            'history',
            name: 'History',
            host: '192.168.1.30',
          ),
        ],
        latestMessages: const {},
        activePeerId: 'connected',
        strings: strings,
      );

      expect(sessions[0].preview, 'Connected now');
      expect(sessions[1].preview, 'Available nearby');
      expect(sessions[2].preview, 'No messages yet');
    });

    test('filters by device name, host, and preview text', () {
      final sessions = ChatSessionListBuilder.build(
        devices: [
          buildDevice(
            'connected',
            name: 'Alpha',
            host: '192.168.1.10',
            around: true,
          ),
          buildDevice(
            'nearby',
            name: 'Beta',
            host: '192.168.1.20',
            around: true,
          ),
        ],
        latestMessages: const {},
        activePeerId: 'connected',
        strings: strings,
      );

      expect(
        ChatSessionListBuilder.filter(sessions, 'alpha')
            .map((item) => item.device.uid)
            .toList(),
        ['connected'],
      );
      expect(
        ChatSessionListBuilder.filter(sessions, '192.168.1.20')
            .map((item) => item.device.uid)
            .toList(),
        ['nearby'],
      );
      expect(
        ChatSessionListBuilder.filter(sessions, 'available')
            .map((item) => item.device.uid)
            .toList(),
        ['nearby'],
      );
    });
  });
}
