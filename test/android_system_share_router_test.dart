import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/android_system_share.dart';
import 'package:whisper/state/android_system_share_inbox.dart';
import 'package:whisper/state/android_system_share_router.dart';

const _hashA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _hashB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

void main() {
  test(
    'offline target stays queued and sends after the connection returns',
    () async {
      final platform = _FakeSharePlatform(<AndroidSystemShareEvent>[
        _event('offline', text: 'hello', itemUris: const <String>['one']),
      ]);
      final inbox = AndroidSystemShareInbox(platform: platform);
      await inbox.initialize();
      var connected = false;
      final sent = <String>[];
      final router = AndroidSystemShareRouter(
        inbox: inbox,
        isConnected: (_) => connected,
        trustedIdentityHashFor: (_) => _hashA,
        sendText: (peerId, event) async {
          sent.add('text:$peerId:${event.text}');
          return true;
        },
        sendItem: (peerId, event, item) async {
          sent.add('file:$peerId:${item.uri}');
          return true;
        },
      );

      final waiting = await router.sendTo('offline', 'peer-a');
      expect(
        waiting.outcome,
        AndroidSystemShareRouteOutcome.waitingForConnection,
      );
      expect(router.targetPeerIdFor('offline'), 'peer-a');
      expect(inbox.event('offline'), isNotNull);
      expect(platform.progressSnapshots.single.publicKeyHash, _hashA);
      expect(sent, isEmpty);

      connected = true;
      final retried = await router.retryConnected();
      expect(retried.single.outcome, AndroidSystemShareRouteOutcome.completed);
      expect(sent, <String>[
        'text:peer-a:hello',
        'file:peer-a:content://provider/one',
      ]);
      expect(inbox.event('offline'), isNull);
      inbox.dispose();
    },
  );

  test(
    'failed item stays queued and retry skips content already sent',
    () async {
      final platform = _FakeSharePlatform(<AndroidSystemShareEvent>[
        _event('partial', text: 'once', itemUris: const <String>['one', 'two']),
      ]);
      final inbox = AndroidSystemShareInbox(platform: platform);
      await inbox.initialize();
      final sent = <String>[];
      var failSecondItem = true;
      final router = AndroidSystemShareRouter(
        inbox: inbox,
        isConnected: (_) => true,
        trustedIdentityHashFor: (_) => _hashA,
        sendText: (peerId, event) async {
          sent.add('text:${event.text}');
          return true;
        },
        sendItem: (peerId, event, item) async {
          sent.add(item.uri);
          if (item.uri.endsWith('/two') && failSecondItem) {
            return false;
          }
          return true;
        },
      );

      final failed = await router.sendTo('partial', 'peer-a');
      expect(failed.outcome, AndroidSystemShareRouteOutcome.failed);
      expect(inbox.event('partial'), isNotNull);
      expect(await router.retryConnected(), isEmpty);

      failSecondItem = false;
      final completed = await router.retry('partial');
      expect(completed.outcome, AndroidSystemShareRouteOutcome.completed);
      expect(sent.where((value) => value == 'text:once'), hasLength(1));
      expect(sent.where((value) => value.endsWith('/one')), hasLength(1));
      expect(sent.where((value) => value.endsWith('/two')), hasLength(2));
      expect(inbox.event('partial'), isNull);
      inbox.dispose();
    },
  );

  test('concurrent duplicate route requests share one send attempt', () async {
    final platform = _FakeSharePlatform(<AndroidSystemShareEvent>[
      _event('duplicate', text: 'hello'),
    ]);
    final inbox = AndroidSystemShareInbox(platform: platform);
    await inbox.initialize();
    final release = Completer<void>();
    var sendCount = 0;
    final router = AndroidSystemShareRouter(
      inbox: inbox,
      isConnected: (_) => true,
      trustedIdentityHashFor: (_) => _hashA,
      sendText: (peerId, event) async {
        sendCount++;
        await release.future;
        return true;
      },
      sendItem: (peerId, event, item) async => true,
    );

    final first = router.sendTo('duplicate', 'peer-a');
    final second = router.sendTo('duplicate', 'peer-a');
    await Future<void>.delayed(Duration.zero);
    expect(sendCount, 1);

    release.complete();
    expect((await first).outcome, AndroidSystemShareRouteOutcome.completed);
    expect((await second).outcome, AndroidSystemShareRouteOutcome.completed);
    expect(sendCount, 1);
    expect(inbox.event('duplicate'), isNull);
    inbox.dispose();
  });

  test('router rebuild in one session skips persisted sent content', () async {
    final original = _event(
      'restored',
      text: 'already sent',
      itemUris: const <String>['one', 'two'],
    );
    final restored = original.copyWithProgress(
      targetPeerId: 'peer-a',
      targetPublicKeyHash: _hashA,
      textSent: true,
      waitingForConnection: false,
      sentItemUris: <String>[original.items.first.uri],
    );
    final platform = _FakeSharePlatform(<AndroidSystemShareEvent>[restored]);
    final inbox = AndroidSystemShareInbox(platform: platform);
    await inbox.initialize();
    final sent = <String>[];
    final router = AndroidSystemShareRouter(
      inbox: inbox,
      isConnected: (_) => true,
      trustedIdentityHashFor: (_) => _hashA,
      sendText: (peerId, event) async {
        sent.add('text:${event.text}');
        return true;
      },
      sendItem: (peerId, event, item) async {
        sent.add(item.uri);
        return true;
      },
    );

    expect(router.targetPeerIdFor('restored'), 'peer-a');
    final results = await router.retryConnected();

    expect(results.single.outcome, AndroidSystemShareRouteOutcome.completed);
    expect(sent, <String>['content://provider/two']);
    expect(platform.completedEventIds, <String>{'restored'});
    expect(platform.progressSnapshots.last.sentItemUris, hasLength(2));
    inbox.dispose();
  });

  test('persisted route without a pinned identity never sends', () async {
    final restored = _event('legacy', text: 'do not send').copyWithProgress(
      targetPeerId: 'peer-a',
      targetPublicKeyHash: '',
      textSent: false,
      waitingForConnection: true,
      sentItemUris: const <String>[],
    );
    final platform = _FakeSharePlatform(<AndroidSystemShareEvent>[restored]);
    final inbox = AndroidSystemShareInbox(platform: platform);
    await inbox.initialize();
    var sends = 0;
    final router = AndroidSystemShareRouter(
      inbox: inbox,
      isConnected: (_) => true,
      trustedIdentityHashFor: (_) => _hashA,
      sendText: (peerId, event) async {
        sends++;
        return true;
      },
      sendItem: (peerId, event, item) async {
        sends++;
        return true;
      },
    );

    final results = await router.retryConnected();

    expect(
      results.single.outcome,
      AndroidSystemShareRouteOutcome.targetIdentityInvalid,
    );
    expect(sends, 0);
    expect(router.targetPeerIdFor('legacy'), isNull);
    expect(inbox.event('legacy')?.targetPeerId, isEmpty);
    expect(inbox.event('legacy')?.targetPublicKeyHash, isEmpty);
    inbox.dispose();
  });

  test('changed or deleted trusted identity blocks automatic retry', () async {
    for (final currentHash in <String?>[_hashB, null]) {
      final restored = _event('identity-$currentHash', text: 'blocked')
          .copyWithProgress(
            targetPeerId: 'peer-a',
            targetPublicKeyHash: _hashA,
            textSent: false,
            waitingForConnection: true,
            sentItemUris: const <String>[],
          );
      final platform = _FakeSharePlatform(<AndroidSystemShareEvent>[restored]);
      final inbox = AndroidSystemShareInbox(platform: platform);
      await inbox.initialize();
      var sends = 0;
      final router = AndroidSystemShareRouter(
        inbox: inbox,
        isConnected: (_) => true,
        trustedIdentityHashFor: (_) => currentHash,
        sendText: (peerId, event) async {
          sends++;
          return true;
        },
        sendItem: (peerId, event, item) async => true,
      );

      final results = await router.retryConnected();

      expect(
        results.single.outcome,
        AndroidSystemShareRouteOutcome.targetIdentityInvalid,
      );
      expect(sends, 0);
      expect(platform.progressSnapshots.last.peerId, isEmpty);
      expect(platform.progressSnapshots.last.publicKeyHash, isEmpty);
      inbox.dispose();
    }
  });

  test(
    'explicit reselection pins the current identity and restarts content',
    () async {
      final original = _event(
        'reselect',
        text: 'send again',
        itemUris: const <String>['one'],
      );
      final restored = original.copyWithProgress(
        targetPeerId: 'peer-a',
        targetPublicKeyHash: _hashA,
        textSent: true,
        waitingForConnection: true,
        sentItemUris: <String>[original.items.single.uri],
      );
      final platform = _FakeSharePlatform(<AndroidSystemShareEvent>[restored]);
      final inbox = AndroidSystemShareInbox(platform: platform);
      await inbox.initialize();
      final sent = <String>[];
      final router = AndroidSystemShareRouter(
        inbox: inbox,
        isConnected: (_) => true,
        trustedIdentityHashFor: (_) => _hashB,
        sendText: (peerId, event) async {
          sent.add(event.text);
          return true;
        },
        sendItem: (peerId, event, item) async {
          sent.add(item.uri);
          return true;
        },
      );

      expect(router.targetPeerIdFor('reselect'), isNull);
      final result = await router.sendTo('reselect', 'peer-a');

      expect(result.outcome, AndroidSystemShareRouteOutcome.completed);
      expect(sent, <String>['send again', 'content://provider/one']);
      expect(
        platform.progressSnapshots.any(
          (snapshot) => snapshot.publicKeyHash == _hashB,
        ),
        isTrue,
      );
      inbox.dispose();
    },
  );
}

AndroidSystemShareEvent _event(
  String id, {
  String text = '',
  List<String> itemUris = const <String>[],
}) {
  return AndroidSystemShareEvent(
    id: id,
    action: 'android.intent.action.SEND',
    mimeType: 'application/octet-stream',
    text: text,
    items: itemUris
        .map(
          (suffix) => AndroidSystemShareItem(
            uri: 'content://provider/$suffix',
            displayName: '$suffix.bin',
            mimeType: 'application/octet-stream',
            size: 4,
          ),
        )
        .toList(growable: false),
    receivedAt: 1,
  );
}

class _FakeSharePlatform implements AndroidSystemSharePlatform {
  _FakeSharePlatform(this.events);

  final List<AndroidSystemShareEvent> events;
  final Set<String> completedEventIds = <String>{};
  final Set<String> discardedEventIds = <String>{};
  final List<_ProgressSnapshot> progressSnapshots = <_ProgressSnapshot>[];

  @override
  Future<List<AndroidSystemShareEvent>> consumePendingShares() async {
    final result = List<AndroidSystemShareEvent>.of(events);
    events.clear();
    return result;
  }

  @override
  Future<List<AndroidSystemShareFailure>> consumePendingShareFailures() async =>
      const <AndroidSystemShareFailure>[];

  @override
  void setShareIntentHandler(AndroidSystemShareIntentHandler? handler) {}

  @override
  Future<void> completePendingShare(String eventId) async {
    completedEventIds.add(eventId);
  }

  @override
  Future<void> discardPendingShare(String eventId) async {
    discardedEventIds.add(eventId);
  }

  @override
  Future<void> updatePendingShareProgress({
    required String eventId,
    required String peerId,
    required String publicKeyHash,
    required bool textSent,
    required bool waitingForConnection,
    required Iterable<String> sentItemUris,
  }) async {
    progressSnapshots.add(
      _ProgressSnapshot(
        eventId: eventId,
        peerId: peerId,
        publicKeyHash: publicKeyHash,
        textSent: textSent,
        waitingForConnection: waitingForConnection,
        sentItemUris: sentItemUris.toSet(),
      ),
    );
  }
}

class _ProgressSnapshot {
  const _ProgressSnapshot({
    required this.eventId,
    required this.peerId,
    required this.publicKeyHash,
    required this.textSent,
    required this.waitingForConnection,
    required this.sentItemUris,
  });

  final String eventId;
  final String peerId;
  final String publicKeyHash;
  final bool textSent;
  final bool waitingForConnection;
  final Set<String> sentItemUris;
}
