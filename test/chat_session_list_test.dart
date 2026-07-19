import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/state/chat_session_list.dart';

DeviceData buildDevice(
  String uid, {
  required String name,
  required String host,
  bool around = false,
  bool auth = false,
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
    auth: auth,
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
        connectedPeerIds: const {'connected'},
        strings: strings,
      );

      expect(sessions.map((item) => item.device.uid).toList(), [
        'connected',
        'nearby',
        'history',
      ]);
    });

    test('marks multiple connected peers at the same time', () {
      final sessions = ChatSessionListBuilder.build(
        devices: [
          buildDevice(
            'peer-b',
            name: 'Peer B',
            host: '192.168.1.10',
            around: true,
          ),
          buildDevice(
            'peer-c',
            name: 'Peer C',
            host: '192.168.1.11',
            around: true,
          ),
          buildDevice(
            'nearby',
            name: 'Nearby',
            host: '192.168.1.12',
            around: true,
          ),
        ],
        latestMessages: const {},
        connectedPeerIds: const {'peer-b', 'peer-c'},
        selectedPeerId: 'nearby',
        strings: strings,
      );

      expect(
        sessions
            .where((item) => item.isConnected)
            .map((item) => item.device.uid),
        unorderedEquals(['peer-b', 'peer-c']),
      );
      expect(sessions.take(2).map((item) => item.device.uid), [
        'peer-b',
        'peer-c',
      ]);
      expect(
          sessions.singleWhere((item) => item.device.uid == 'nearby').preview,
          'Available nearby');
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
            auth: true,
          ),
        ],
        latestMessages: const {},
        connectedPeerIds: const {'connected'},
        strings: strings,
      );

      expect(sessions[0].preview, 'Connected now');
      expect(sessions[1].preview, 'Available nearby');
      expect(sessions[2].preview, 'No messages yet');
    });

    test('hides offline untrusted discoveries that have no history', () {
      final sessions = ChatSessionListBuilder.build(
        devices: [
          buildDevice('stale', name: 'Phone', host: '192.168.1.20'),
          buildDevice(
            'trusted',
            name: 'Trusted Phone',
            host: '192.168.1.21',
            auth: true,
          ),
          buildDevice('history', name: 'Old Phone', host: '192.168.1.22'),
        ],
        latestMessages: {
          'history': buildMessage(
            'history',
            content: 'kept history',
            timestamp: 100,
          ),
        },
        strings: strings,
      );

      expect(
        sessions.map((item) => item.device.uid),
        unorderedEquals(<String>['trusted', 'history']),
      );
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
        connectedPeerIds: const {'connected'},
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
