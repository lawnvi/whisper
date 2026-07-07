import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/transfer_notification_aggregator.dart';
import 'package:whisper/model/file_transfer.dart';

TransferSnapshot snap(
  String id, {
  FileTransferDirection direction = FileTransferDirection.outgoing,
  FileTransferState state = FileTransferState.transferring,
  int size = 100,
  int committed = 0,
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

TransferNotificationStrings strings() => TransferNotificationStrings(
      title: (count) => 'title:$count',
      bodySending: (percent, speed, remaining) => 'send:$percent:$speed',
      bodyReceiving: (percent, speed, remaining) => 'recv:$percent:$speed',
      bodyMixed: (percent, speed, remaining) => 'mixed:$percent:$speed',
      completed: (count) => 'done:$count',
      interrupted: () => 'interrupted',
    );

void main() {
  test('aggregates byte-weighted progress across transfers', () {
    var now = 0;
    final agg = TransferNotificationAggregator(
        nowMillis: () => now, strings: strings());
    expect(agg.onSnapshot(snap('a', size: 100, committed: 50))!.progress, 50);
    now += 2000;
    // a:50/100 + b:0/300 => 50/400 = 12%
    final cmd = agg.onSnapshot(snap('b', size: 300, committed: 0))!;
    expect(cmd.kind, TransferNotificationKind.progress);
    expect(cmd.progress, 50); // 单调:不允许从 50 回退到 12
  });

  test('throttles to 300ms updates but not terminal', () {
    var now = 0;
    final agg = TransferNotificationAggregator(
        nowMillis: () => now, strings: strings());
    expect(agg.onSnapshot(snap('a', committed: 10)), isNotNull);
    now += 100;
    expect(agg.onSnapshot(snap('a', committed: 20)), isNull); // 节流
    now += 250;
    expect(agg.onSnapshot(snap('a', committed: 30)), isNotNull);
    now += 100;
    final done = agg.onSnapshot(
        snap('a', state: FileTransferState.completed, committed: 100));
    expect(done!.kind, TransferNotificationKind.terminal); // 终态立即发
    expect(done.success, isTrue);
  });

  test('all canceled yields cancel command and resets generation', () {
    var now = 0;
    final agg = TransferNotificationAggregator(
        nowMillis: () => now, strings: strings());
    agg.onSnapshot(snap('a', committed: 90));
    final cmd = agg.onSnapshot(snap('a', state: FileTransferState.canceled));
    expect(cmd!.kind, TransferNotificationKind.cancel);
    // 新一代传输从 0 开始,不受上一代 90% 单调值影响
    now += 2000;
    expect(agg.onSnapshot(snap('b', committed: 10))!.progress, 10);
  });

  test('failure yields interrupted terminal', () {
    var now = 0;
    final agg = TransferNotificationAggregator(
        nowMillis: () => now, strings: strings());
    agg.onSnapshot(snap('a', committed: 10));
    final cmd = agg.onSnapshot(snap('a', state: FileTransferState.failed));
    expect(cmd!.kind, TransferNotificationKind.terminal);
    expect(cmd.success, isFalse);
    expect(cmd.text, 'interrupted');
  });

  test('waiting reconnect yields one interrupted terminal without reset', () {
    var now = 0;
    final agg = TransferNotificationAggregator(
        nowMillis: () => now, strings: strings());
    agg.onSnapshot(snap('a', committed: 10));
    now += 2000;

    final interrupted =
        agg.onSnapshot(snap('a', state: FileTransferState.waitingReconnect));

    expect(interrupted, isNotNull);
    expect(interrupted!.kind, TransferNotificationKind.terminal);
    expect(interrupted.success, isFalse);
    expect(interrupted.text, 'interrupted');

    now += 2000;
    expect(
      agg.onSnapshot(snap('a', state: FileTransferState.waitingReconnect)),
      isNull,
    );
  });

  test('stalled transfer resumes with forced progress', () {
    var now = 0;
    final agg = TransferNotificationAggregator(
        nowMillis: () => now, strings: strings());
    agg.onSnapshot(snap('a', committed: 10));
    now += 2000;
    expect(
      agg
          .onSnapshot(snap('a', state: FileTransferState.waitingReconnect))!
          .kind,
      TransferNotificationKind.terminal,
    );
    now += 100;

    final resumed = agg.onSnapshot(snap('a', committed: 20));

    expect(resumed, isNotNull);
    expect(resumed!.kind, TransferNotificationKind.progress);
    expect(resumed.progress, 20);
  });

  test('all failed still yields original interrupted terminal and resets', () {
    var now = 0;
    final agg = TransferNotificationAggregator(
        nowMillis: () => now, strings: strings());
    agg.onSnapshot(snap('a', committed: 90));
    final cmd = agg.onSnapshot(snap('a', state: FileTransferState.failed));
    expect(cmd!.kind, TransferNotificationKind.terminal);
    expect(cmd.success, isFalse);
    expect(cmd.text, 'interrupted');

    now += 2000;
    expect(agg.onSnapshot(snap('b', committed: 10))!.progress, 10);
  });

  test('formats speed from byte deltas', () {
    expect(formatBytesForNotification(0), '0 B');
    expect(formatBytesForNotification(1536), '1.5 KB');
    expect(formatBytesForNotification(3 * 1024 * 1024), '3.0 MB');
  });
}
