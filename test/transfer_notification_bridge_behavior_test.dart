import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/transfer_notifications.dart';
import 'package:whisper/model/file_transfer.dart';

TransferSnapshot _snap(
  String id, {
  FileTransferState state = FileTransferState.transferring,
  int size = 100,
  int committed = 0,
  FileTransferDirection direction = FileTransferDirection.outgoing,
}) {
  return TransferSnapshot(
    transferId: id,
    messageUuid: 'm-$id',
    peerUid: 'peer',
    direction: direction,
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

    // 停滞是可恢复状态:走 showStatus(前台服务保活,后台恢复仍能刷新),
    // 不得走 showTerminal(会 stopSelf,Android 12+ 后台无法再拉起)。
    final interrupted = calls.where((c) => c.method == 'showStatus').toList();
    expect(interrupted, hasLength(1), reason: '全员停滞只弹一条"已中断"');
    expect(calls.where((c) => c.method == 'showTerminal'), isEmpty,
        reason: '停滞不得停止前台服务');

    bridge.onTransferUpdated(
        _snap('t2', state: FileTransferState.negotiating, committed: 0));
    bridge.onTransferUpdated(
        _snap('t3', state: FileTransferState.negotiating, committed: 0));
    bridge.onTransferUpdated(
        _snap('t2', state: FileTransferState.completed, committed: 100));
    bridge.onTransferUpdated(
        _snap('t3', state: FileTransferState.completed, committed: 100));

    final terminals = calls.where((c) => c.method == 'showTerminal').toList();
    expect(terminals, hasLength(1), reason: '整代终结只有最终完成一条 showTerminal');
    final finalArgs =
        Map<Object?, Object?>.from(terminals.last.arguments as Map);
    expect(finalArgs['success'], isTrue);
    expect(
      finalArgs['text'],
      contains('3'),
      reason: '聚合器若在停滞时被丢弃,T1 会被漏算成 2 笔',
    );
  });

  test('completion during stall emits showStatus summary and keeps tracking',
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

    // s1 停滞 → s2 在停滞期间完成:完成播报走 showStatus(服务保活,
    // 僵尸 s1 继续被跟踪),不得走 showTerminal(停服务后 s1 的后续
    // 终态命令会以 startForegroundService 冷启动砸中已停服务 → 崩溃链)。
    bridge.onTransferUpdated(_snap('s1'));
    bridge.onTransferUpdated(
        _snap('s1', state: FileTransferState.waitingReconnect));
    bridge.onTransferUpdated(_snap('s2'));
    bridge.onTransferUpdated(
        _snap('s2', state: FileTransferState.completed, committed: 100));

    final statusCalls = calls.where((c) => c.method == 'showStatus').toList();
    expect(statusCalls, hasLength(2), reason: '一条"已中断" + 一条部分完成汇总');
    final summaryArgs =
        Map<Object?, Object?>.from(statusCalls.last.arguments as Map);
    expect(summaryArgs['success'], isTrue);
    expect(calls.where((c) => c.method == 'showTerminal'), isEmpty);

    // s1 最终取消 → 整代 cancel 收尾(单例状态清理)
    bridge.onTransferUpdated(
        _snap('s1', state: FileTransferState.canceled));
    expect(calls.where((c) => c.method == 'cancel'), hasLength(1));
  });

  test('progress says which way the files go, for the island over other apps',
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
    bridge.onTransferUpdated(
        _snap('in1', direction: FileTransferDirection.incoming));
    final progress = calls.where((c) => c.method == 'showProgress').toList();
    expect(progress, isNotEmpty);
    expect(
      Map<Object?, Object?>.from(progress.last.arguments as Map)['direction'],
      'in',
    );

    bridge.onTransferUpdated(_snap('in1',
        direction: FileTransferDirection.incoming,
        state: FileTransferState.completed,
        committed: 100));
    expect(calls.where((c) => c.method == 'showTerminal'), hasLength(1));
  });

  test('the island card stops what is still under way', () async {
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
    final canceled = <String>[];
    final cancelBefore = bridge.cancel;
    final peerBefore = bridge.peer;
    bridge.cancel = (id) async => canceled.add(id);
    bridge.peer = (peer) => (kind: 'computer', name: 'MacBook');
    addTearDown(() {
      bridge.cancel = cancelBefore;
      bridge.peer = peerBefore;
    });

    bridge.onTransferUpdated(_snap('s1'));
    bridge.onTransferUpdated(_snap('s2'));
    bridge.onTransferUpdated(
        _snap('s2', state: FileTransferState.completed, committed: 100));
    final progress = calls.where((c) => c.method == 'showProgress').toList();
    final args = Map<Object?, Object?>.from(progress.first.arguments as Map);
    expect(args['peer'], 'computer');
    expect(args['detail'], startsWith('To MacBook'));
    expect(args['stopLabel'], isNotEmpty);
    expect(args['openLabel'], isNotEmpty);

    await bridge.onNative(const MethodCall('stop'));
    expect(canceled, ['s1']);

    bridge.onTransferUpdated(_snap('s1', state: FileTransferState.canceled));
  });
}
