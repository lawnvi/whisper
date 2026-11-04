import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/pairing_request.dart';

class _RecordingSocketEvent implements ISocketEvent {
  final List<MessageData> messages = [];
  final List<TransferSnapshot> transfers = [];

  @override
  void afterAuth(bool allow, DeviceData? device) {}

  @override
  void onPairing(PairingRequest request, void Function(bool) resolve) {}

  @override
  void onClose() {}

  @override
  void onConnect() {}

  @override
  void onError(String message) {}

  @override
  void onNotice(String message) {}

  @override
  void onMessage(MessageData messageData) {
    messages.add(messageData);
  }

  @override
  void onTransferUpdated(TransferSnapshot snapshot) {
    transfers.add(snapshot);
  }
}

class _ThrowingSocketEvent extends _RecordingSocketEvent {
  @override
  void onMessage(MessageData messageData) {
    throw StateError('listener failure');
  }
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
  test('a throwing listener does not break dispatch to later listeners', () {
    final manager = WsSvrManager();
    final throwingListener = _ThrowingSocketEvent();
    final chatListener = _RecordingSocketEvent();

    manager.debugResetListeners();
    manager.registerEvent(throwingListener, primary: true);
    manager.registerEvent(chatListener);

    expect(
      () => manager.debugDispatchMessage(_buildMessage()),
      returnsNormally,
    );
    expect(chatListener.messages, hasLength(1));
  });
}
