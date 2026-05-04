import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/page/conversation.dart';

void main() {
  group('resolveConversationDeviceSnapshot', () {
    test('uses the selected peer when it has not been persisted yet', () {
      final self = _device(uid: 'self', name: 'Ubuntu');
      final selectedPeer = _device(
        uid: 'peer',
        name: 'Nearby Mac',
        host: '192.168.31.245',
      );

      final resolved = resolveConversationDeviceSnapshot(
        localDevice: self,
        selectedDevice: selectedPeer,
        storedDevice: null,
      );

      expect(resolved.uid, 'peer');
      expect(resolved.name, 'Nearby Mac');
      expect(resolved.host, '192.168.31.245');
    });

    test('uses the local device snapshot for localhost conversations', () {
      final self = _device(uid: 'self', name: 'Ubuntu');
      final selectedSelf = _device(uid: 'self', name: 'Stale local name');

      final resolved = resolveConversationDeviceSnapshot(
        localDevice: self,
        selectedDevice: selectedSelf,
        storedDevice: null,
      );

      expect(resolved.name, 'Ubuntu');
    });
  });
}

DeviceData _device({
  required String uid,
  required String name,
  String host = '127.0.0.1',
}) {
  return DeviceData(
    id: 0,
    uid: uid,
    name: name,
    host: host,
    port: 10002,
    platform: 'linux',
    isServer: false,
    online: true,
    clipboard: true,
    auth: false,
    lastTime: 0,
  );
}
