import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/page/window_stream/flow_offer_banner.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/sources/copy_source.dart';
import 'package:whisper/widget/island/sources/streamed_source.dart';
import 'package:whisper/widget/island/sources/transfer_source.dart';
import 'package:whisper/widget/island/transfer_names.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';
import 'package:whisper/window_stream/remote/remote_peer_source.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';

import 'island_test_support.dart';

TransferSnapshot _snap(
  String id, {
  FileTransferState state = FileTransferState.transferring,
  FileTransferDirection direction = FileTransferDirection.incoming,
  int size = 1000,
  int committed = 0,
  String peer = 'mac',
}) => TransferSnapshot(
  transferId: id,
  messageUuid: id,
  peerUid: peer,
  direction: direction,
  state: state,
  finalPath: '',
  tempPath: '',
  size: size,
  committedBytes: committed,
  lastError: '',
  updatedAt: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('conversation transfers', () {
    late StreamController<TransferSnapshot> updates;
    late TransferIslandSource source;
    late List<String> canceled;
    late List<String> retried;

    setUp(() {
      updates = StreamController<TransferSnapshot>.broadcast(sync: true);
      canceled = [];
      retried = [];
      source = TransferIslandSource(
        updates: updates.stream,
        isCopy: (id) => id.startsWith('copy'),
        names: TransferNames(lookup: (uuid) async => 'photo-$uuid.jpg'),
        deviceName: (peer) => peer == 'mac' ? 'MacBook' : null,
        cancel: (id) async => canceled.add(id),
        retry: (id) async => retried.add(id),
        clock: FakeIslandClock(),
      );
    });

    tearDown(() async {
      source.dispose();
      await updates.close();
    });

    TransferStats stats() =>
        (source.activities.single.presenter as TransferPresenter).stats;

    test('file manager copies are left to their own activities', () {
      updates.add(_snap('copy-1'));
      expect(source.activities, isEmpty);
    });

    test('one round of transfers is one quiet activity', () async {
      updates.add(_snap('a', committed: 250));
      updates.add(_snap('b', size: 3000, committed: 750));
      final activity = source.activities.single;
      expect(activity.kind, IslandKind.transfer);
      expect(activity.arrival, IslandArrival.quiet);
      expect(activity.showAfter, TransferIslandSource.showAfter);
      expect(activity.status, IslandStatus.live);
      expect(stats().count, 2);
      expect(stats().fraction, 0.25);
      expect(stats().device, 'MacBook');
      expect(stats().receiving, isTrue);
      expect(stats().name, isNull, reason: 'two files have no one name');

      updates.add(_snap('a', state: FileTransferState.completed));
      expect(source.activities.single.status, IslandStatus.live);
      updates.add(_snap('b', size: 3000, state: FileTransferState.completed));
      expect(source.activities.single.status, IslandStatus.done);
      expect(stats().fraction, 1);

      final id = source.activities.single.id;
      source.retired(id);
      expect(source.activities, isEmpty);

      // The next one is a new round.
      updates.add(_snap('c'));
      expect(source.activities.single.id, isNot(id));
    });

    test('a single file goes by its name once known', () async {
      updates.add(_snap('a'));
      await Future<void>.delayed(Duration.zero);
      updates.add(_snap('a', committed: 10));
      expect(stats().name, 'photo-a.jpg');
    });

    test('trouble, failure, and what the buttons do', () async {
      updates.add(
        _snap('out', direction: FileTransferDirection.outgoing, peer: 'pc'),
      );
      updates.add(_snap('in'));
      expect(stats().device, isNull, reason: 'two devices');
      updates.add(
        _snap(
          'out',
          direction: FileTransferDirection.outgoing,
          peer: 'pc',
          state: FileTransferState.waitingReconnect,
        ),
      );
      updates.add(_snap('in', state: FileTransferState.waitingReconnect));
      expect(source.activities.single.status, IslandStatus.waiting);
      expect(stats().canRetry, isTrue);

      final presenter = source.activities.single.presenter as TransferPresenter;
      await presenter.stop();
      expect(canceled, ['out', 'in']);
      await presenter.retry!();
      expect(retried, ['out']);

      updates.add(_snap('in', state: FileTransferState.failed));
      updates.add(
        _snap(
          'out',
          direction: FileTransferDirection.outgoing,
          peer: 'pc',
          state: FileTransferState.completed,
        ),
      );
      expect(source.activities.single.status, IslandStatus.failed);
    });

    test('all stopped is over without a result', () {
      updates.add(_snap('a'));
      updates.add(_snap('a', state: FileTransferState.canceled));
      expect(source.activities.single.status, IslandStatus.ended);
    });

    test('an update for something long over is ignored', () {
      updates.add(_snap('old', state: FileTransferState.completed));
      expect(source.activities, isEmpty);
    });
  });

  group('this phone being streamed', () {
    const channel = MethodChannel('island-test/window_stream_phone');
    late List<MethodCall> calls;
    late StreamedIslandSource source;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'state') {
              return {'windows': 0, 'viewer': '', 'stopping': false};
            }
            return null;
          });
      source = StreamedIslandSource(channel: channel, enabled: true);
    });

    tearDown(() {
      source.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('streamed, stopped from the island, then over', () async {
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method), ['state']);
      expect(source.activities, isEmpty);

      source.apply({'windows': 2, 'viewer': 'MacBook', 'stopping': false});
      final live = source.activities.single;
      expect(live.kind, IslandKind.streamed);
      expect(live.status, IslandStatus.live);
      expect(live.urgent, isTrue);
      final presenter = live.presenter as StreamedPresenter;
      expect(presenter.windows, 2);
      expect(presenter.viewer, 'MacBook');

      await presenter.stop();
      expect(calls.last.method, 'stop');
      expect(
        (source.activities.single.presenter as StreamedPresenter).stopping,
        isTrue,
      );

      source.apply({'windows': 0, 'viewer': 'MacBook', 'stopping': false});
      expect(source.activities.single.status, IslandStatus.ended);
      source.retired(live.id);
      expect(source.activities, isEmpty);

      source.apply({'windows': 1, 'viewer': 'PC', 'stopping': false});
      expect(source.activities.single.id, isNot(live.id));
    });
  });

  group('windows sent here', () {
    late WindowStreamViewer viewer;
    late OfferIslandSource source;
    late List<String> notified;
    late int cancels;
    var foreground = true;

    setUp(() {
      viewer = WindowStreamViewer.shared;
      viewer.peerAvailable(
        peerId: 'mac',
        name: 'MacBook',
        platform: WindowStreamPlatform.macos,
        host: '127.0.0.1',
        port: 1,
      );
      notified = [];
      cancels = 0;
      foreground = true;
      source = OfferIslandSource(
        viewer: viewer,
        inForeground: () => foreground,
        notify: (title, body) async => notified.add('$title|$body'),
        cancelNotification: () async => cancels++,
      );
    });

    tearDown(() {
      source.dispose();
      viewer.peerGone('mac');
    });

    void offer(int id, String title) => viewer.handleControl(
      WindowStreamControlMessage(
        action: WindowStreamControlAction.offer,
        sessionId: 's$id',
        viewerPeerId: 'phone',
        hostPeerId: 'mac',
        payload: {
          'window': {
            'id': id,
            'appName': 'Notes',
            'title': title,
            'bundleId': 'com.apple.Notes',
          },
        },
      ),
      remotePeerId: 'mac',
      remoteHost: '127.0.0.1',
      sendKey: Uint8List(32),
      receiveKey: Uint8List(32),
    );

    test('on the island in the app, timed like before', () {
      offer(7, 'Groceries');
      final activity = source.activities.single;
      expect(activity.kind, IslandKind.offer);
      expect(activity.openFor, const Duration(seconds: 8));
      expect(activity.waitsFor, const Duration(seconds: 12));
      expect(notified, isEmpty);

      source.dismissed(activity);
      expect(viewer.offers.value, isEmpty);
      expect(source.activities, isEmpty);
    });

    test('in the background a notification of its own, gone when settled', () {
      foreground = false;
      offer(8, 'Budget');
      expect(notified, ['MacBook sent you a window|Budget']);
      expect(OfferIslandSource.notificationId, isNot(1));
      source.expired(source.activities.single);
      expect(cancels, 1);
    });
  });

  test('the file manager lends the island its buttons while open', () {
    expect(IslandCopyHooks.showAll, isNull);
    var shown = 0;
    final detach = IslandCopyHooks.attach(showAll: () => shown++);
    IslandCopyHooks.showAll!();
    expect(shown, 1);
    detach();
    expect(IslandCopyHooks.showAll, isNull);
  });
}
