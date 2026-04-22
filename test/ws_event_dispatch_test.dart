import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/svrmanager.dart';

class _RecordingSocketEvent implements ISocketEvent {
  final List<MessageData> messages = [];
  final List<TransferSnapshot> transfers = [];

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
  void onNotice(String message) {}

  @override
  void onMessage(MessageData messageData) {
    messages.add(messageData);
  }

  @override
  void onProgress(int size, length) {}

  @override
  void onTransferUpdated(TransferSnapshot snapshot) {
    transfers.add(snapshot);
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

  test('broadcasts transfer updates to all registered listeners', () {
    final manager = WsSvrManager();
    final listListener = _RecordingSocketEvent();
    final chatListener = _RecordingSocketEvent();

    manager.debugResetListeners();
    manager.registerEvent(listListener, primary: true);
    manager.registerEvent(chatListener);
    manager.debugDispatchTransfer(
      const TransferSnapshot(
        transferId: 'transfer-1',
        messageUuid: 'message-1',
        peerUid: 'peer-a',
        direction: FileTransferDirection.outgoing,
        state: FileTransferState.transferring,
        finalPath: '/tmp/archive.zip',
        tempPath: '/tmp/.whisper/transfers/transfer-1.part',
        size: 1024,
        committedBytes: 512,
        lastError: '',
        updatedAt: 1,
      ),
    );

    expect(listListener.transfers, hasLength(1));
    expect(chatListener.transfers, hasLength(1));
    expect(chatListener.transfers.single.transferId, 'transfer-1');
  });
}
