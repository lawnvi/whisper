import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/svrmanager.dart';

class _RecordingSocketEvent implements ISocketEvent {
  final List<MessageData> messages = [];

  @override
  void afterAuth(bool allow, DeviceData? device) {}

  @override
  void onAuth(DeviceData? deviceData, bool asServer, String msg, callback) {}

  @override
  void onClose() {}

  @override
  void onConnect() {}

  @override
  void onError(String message) {}

  @override
  void onMessage(MessageData messageData) {
    messages.add(messageData);
  }

  @override
  void onProgress(int size, length) {}
}

MessageData _buildMessage() {
  return MessageData(
    id: 1,
    deviceId: null,
    sender: 'peer-a',
    receiver: 'peer-b',
    name: '',
    clipboard: false,
    size: 0,
    type: MessageEnum.Text,
    content: 'hello',
    message: '',
    timestamp: 1,
    uuid: 'msg-1',
    acked: true,
    path: '',
    md5: '',
    fileTimestamp: 0,
  );
}

void main() {
  test('broadcasts message events to all registered listeners', () {
    final manager = WsSvrManager();
    final listListener = _RecordingSocketEvent();
    final chatListener = _RecordingSocketEvent();

    manager.debugResetListeners();
    manager.registerEvent(listListener, primary: true);
    manager.registerEvent(chatListener);
    manager.debugDispatchMessage(_buildMessage());

    expect(listListener.messages, hasLength(1));
    expect(chatListener.messages, hasLength(1));
  });
}
