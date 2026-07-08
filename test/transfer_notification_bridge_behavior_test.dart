import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/transfer_notifications.dart';
import 'package:whisper/model/file_transfer.dart';

TransferSnapshot _snap(
  String id, {
  FileTransferState state = FileTransferState.transferring,
  int size = 100,
  int committed = 0,
}) {
  return TransferSnapshot(
    transferId: id,
    messageUuid: 'm-$id',
    peerUid: 'peer',
    direction: FileTransferDirection.outgoing,
    state: state,
    finalPath: '/tmp/$id',
    tempPath: '/tmp/$id.part',
    size: size,
    committedBytes: committed,
    lastError: '',
    updatedAt: 0,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.vireen.whisper/transfer_notifications');

  test('stalled interrupted keeps aggregator: final completed count is exact',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final bridge = TransferNotificationBridge();

    // R3 复现序列:T1 完成后 T2/T3 分批停滞 → 一条"已中断";
    // 恢复并全部完成后,最终计数必须包含 T1(共 3 笔)。
    bridge.onTransferUpdated(_snap('t1'));
    bridge.onTransferUpdated(_snap('t2'));
    bridge.onTransferUpdated(_snap('t3'));
    bridge.onTransferUpdated(
        _snap('t1', state: FileTransferState.completed, committed: 100));
    bridge.onTransferUpdated(
        _snap('t2', state: FileTransferState.waitingReconnect));
    bridge.onTransferUpdated(
        _snap('t3', state: FileTransferState.waitingReconnect));

    final interrupted =
        calls.where((c) => c.method == 'showTerminal').toList();
    expect(interrupted, hasLength(1), reason: '全员停滞只弹一条"已中断"');

    bridge.onTransferUpdated(
        _snap('t2', state: FileTransferState.negotiating, committed: 0));
    bridge.onTransferUpdated(
        _snap('t3', state: FileTransferState.negotiating, committed: 0));
    bridge.onTransferUpdated(
        _snap('t2', state: FileTransferState.completed, committed: 100));
    bridge.onTransferUpdated(
        _snap('t3', state: FileTransferState.completed, committed: 100));

    final terminals = calls.where((c) => c.method == 'showTerminal').toList();
    expect(terminals, hasLength(2), reason: '中断一条 + 最终完成一条');
    final finalArgs =
        Map<Object?, Object?>.from(terminals.last.arguments as Map);
    expect(finalArgs['success'], isTrue);
    expect(
      finalArgs['text'],
      contains('3'),
      reason: '聚合器若在停滞时被丢弃,T1 会被漏算成 2 笔',
    );
  });
}
