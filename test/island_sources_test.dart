import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/page/window_stream/flow_offer_banner.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/sources/copy_source.dart';
import 'package:whisper/widget/island/sources/streamed_source.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';
import 'package:whisper/window_stream/remote/remote_peer_source.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';

import 'island_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
