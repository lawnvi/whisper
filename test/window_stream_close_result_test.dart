import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/core/window_source.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';
import 'package:whisper/window_stream/remote/remote_peer_source.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';
import 'package:whisper/window_stream/window_stream_support.dart';

/// Closing a window from the recents waits for the host to say how it went.
void main() {
  const host = 'host-peer';
  const viewerId = 'viewer-peer';
  late WindowStreamViewer viewer;
  late List<WindowStreamControlMessage> sent;

  void reply(
    WindowStreamControlMessage to,
    WindowStreamControlAction action,
    Map<String, Object?> payload,
  ) {
    viewer.handleControl(
      to.reply(action, payload: payload),
      remotePeerId: host,
      remoteHost: '127.0.0.1',
      sendKey: Uint8List(32),
      receiveKey: Uint8List(32),
    );
  }

  Map<String, Object?> window(int id) => {
    'id': id,
    'appId': 'notepad',
    'appName': 'Notepad',
    'title': 'Untitled',
    'width': 800,
    'height': 600,
    'pid': 42,
  };

  Future<RemotePeerSource> listed(List<int> ids) async {
    final source = viewer.sourceFor(host)!;
    final tasks = source.tasks();
    await Future<void>.delayed(Duration.zero);
    final browse = sent.lastWhere(
      (m) => m.action == WindowStreamControlAction.browse,
    );
    reply(browse, WindowStreamControlAction.catalog, {
      'windows': [for (final id in ids) window(id)],
      'apps': const [],
    });
    await tasks;
    return source;
  }

  setUp(() {
    viewer = WindowStreamViewer.shared;
    sent = [];
    viewer.sender = (peerId, message) async {
      sent.add(message);
      return true;
    };
    viewer.localPeerId = (_) => viewerId;
    viewer.peerGone(host);
    viewer.peerAvailable(
      peerId: host,
      name: 'PC',
      platform: windowStreamPlatformOf('windows'),
      host: '127.0.0.1',
      port: 1,
    );
  });

  tearDown(() => viewer.peerGone(host));

  TaskEntry task(int id) =>
      TaskEntry(id: id, appId: 'notepad', label: 'Notepad — Untitled');

  test('closed only once the host says the window is gone', () async {
    final source = await listed([7, 8]);
    var settled = false;
    final outcome = source.closeTaskAndWait(task(7))
      ..then((_) => settled = true);
    await Future<void>.delayed(Duration.zero);
    final close = sent.last;
    expect(close.action, WindowStreamControlAction.closeWindow);
    expect(close.payload['windowId'], 7);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(settled, isFalse, reason: 'no answer yet: still closing');
    // Asking again while it closes does not send a second close.
    final again = source.closeTaskAndWait(task(7));
    await Future<void>.delayed(Duration.zero);
    expect(
      sent.where((m) => m.action == WindowStreamControlAction.closeWindow),
      hasLength(1),
    );
    reply(close, WindowStreamControlAction.closeResult, {
      'windowId': 7,
      'outcome': 'closed',
    });
    expect(await outcome, TaskCloseOutcome.closed);
    expect(await again, TaskCloseOutcome.closed);
    expect((await source.tasks()).map((t) => t.id), [8]);
  });

  test('a list sent before the host noticed does not bring it back', () async {
    final source = await listed([7, 8]);
    final outcome = source.closeTaskAndWait(task(7));
    await Future<void>.delayed(Duration.zero);
    reply(sent.last, WindowStreamControlAction.closeResult, {
      'windowId': 7,
      'outcome': 'closed',
    });
    await outcome;
    final stale = await listed([7, 8]);
    expect((await stale.tasks()).map((t) => t.id), [8]);
  });

  test('a window asking whether to save stays, and says so', () async {
    final source = await listed([7]);
    final outcome = source.closeTaskAndWait(task(7));
    await Future<void>.delayed(Duration.zero);
    reply(sent.last, WindowStreamControlAction.closeResult, {
      'windowId': 7,
      'outcome': 'open',
    });
    expect(await outcome, TaskCloseOutcome.stillOpen);
    expect((await source.tasks()).map((t) => t.id), [7]);
  });

  test('closing fails when the host goes away', () async {
    final source = await listed([7]);
    final outcome = source.closeTaskAndWait(task(7));
    await Future<void>.delayed(Duration.zero);
    viewer.peerGone(host);
    expect(await outcome, TaskCloseOutcome.failed);
  });

  test('the host watches the window and answers the viewer', () {
    final source = File(
      'lib/window_stream/remote/window_stream_host.dart',
    ).readAsStringSync();
    expect(source, contains('unawaited(_watchClose(message, send, window))'));
    expect(source, contains('WindowStreamControlAction.closeResult'));
    expect(source, contains("'outcome': closed ? 'closed' : 'open'"));
    expect(source, contains('still.modal'));
  });

  test('the recents card waits while its window closes', () {
    final page = File(
      'lib/page/window_stream/flow_space_page.dart',
    ).readAsStringSync();
    expect(page, contains('closeTaskAndWait(task)'));
    expect(page, contains('_closingTasks.contains(_taskKey(source, task))'));
    expect(page, contains('l10n.windowStreamCloseStillOpen('));
    final deck = File(
      'lib/page/window_stream/flow_recents_deck.dart',
    ).readAsStringSync();
    // The spinner exists only while closing (one hidden at zero opacity
    // kept turning and redrew the page every frame).
    expect(deck, contains('child: card.closing'));
    expect(deck, isNot(contains('opacity: card.closing ? 1 : 0')));
    expect(deck, contains('card.closing ||'));
  });
}
