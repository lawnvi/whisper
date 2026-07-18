import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/android_system_share.dart';
import 'package:whisper/state/android_system_share_inbox.dart';

const _hashA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _hashB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

void main() {
  test('recognizes only Whisper private staged share uris', () {
    expect(
      isAndroidSystemShareStagedUri(
        'content://com.vireen.whisper.system_share_files/'
        'android_system_shares/123/item-00.bin',
      ),
      isTrue,
    );
    expect(
      isAndroidSystemShareStagedUri('content://provider/items/1'),
      isFalse,
    );
    expect(
      isAndroidSystemShareStagedUri(
        'content://com.vireen.whisper.system_share_files/'
        'android_system_shares/123/extra/item.bin',
      ),
      isFalse,
    );
  });

  test('parses text and unique content uri metadata defensively', () {
    final event = AndroidSystemShareEvent.fromMap(<Object?, Object?>{
      'id': 'share-1',
      'action': 'android.intent.action.SEND',
      'mimeType': 'image/png',
      'text': 'caption',
      'receivedAt': 123,
      'items': <Object?>[
        <Object?, Object?>{
          'uri': 'content://provider/items/1',
          'displayName': 'photo.png',
          'mimeType': 'image/png',
          'size': 42,
        },
        <Object?, Object?>{
          'uri': 'content://provider/items/1',
          'displayName': 'duplicate.png',
          'size': 42,
        },
        <Object?, Object?>{
          'uri': 'file:///tmp/not-accepted.png',
          'displayName': 'not-accepted.png',
          'size': 3,
        },
      ],
    });

    expect(event, isNotNull);
    expect(event!.text, 'caption');
    expect(event.items, hasLength(1));
    expect(event.items.single.uri, 'content://provider/items/1');
    expect(event.items.single.displayName, 'photo.png');
    expect(event.items.single.size, 42);
  });

  test('drops empty or unidentified platform events', () {
    expect(
      AndroidSystemShareEvent.fromMap(<Object?, Object?>{
        'id': '',
        'text': 'hello',
      }),
      isNull,
    );
    expect(
      AndroidSystemShareEvent.fromMap(<Object?, Object?>{
        'id': 'empty',
        'text': '',
        'items': const <Object?>[],
      }),
      isNull,
    );
  });

  test('rejects oversized text and item lists instead of truncating', () {
    expect(
      AndroidSystemShareEvent.fromMap(<Object?, Object?>{
        'id': 'large-text',
        'text': 'x' * (androidSystemShareMaxTextLength + 1),
      }),
      isNull,
    );
    expect(
      AndroidSystemShareEvent.fromMap(<Object?, Object?>{
        'id': 'many-items',
        'items': List<Object?>.generate(
          androidSystemShareMaxItemsPerEvent + 1,
          (index) => <Object?, Object?>{
            'uri': 'content://provider/items/$index',
            'displayName': '$index.bin',
          },
        ),
      }),
      isNull,
    );
  });

  test('cold-start initialize consumes native pending shares', () async {
    final platform = _FakeAndroidSystemSharePlatform()
      ..enqueue(<AndroidSystemShareEvent>[_event('cold')]);
    final inbox = AndroidSystemShareInbox(platform: platform);
    addTearDown(inbox.dispose);

    await inbox.initialize();

    expect(platform.consumeCount, 1);
    expect(inbox.pendingEvents.map((event) => event.id), <String>['cold']);
  });

  test('warm share notification consumes the next native batch', () async {
    final platform = _FakeAndroidSystemSharePlatform();
    final inbox = AndroidSystemShareInbox(platform: platform);
    addTearDown(inbox.dispose);
    await inbox.initialize();
    platform.enqueue(<AndroidSystemShareEvent>[_event('warm')]);

    await platform.notifyShareIntentReceived();

    expect(inbox.pendingEvents.map((event) => event.id), <String>['warm']);
  });

  test(
    'queue limit rejects new events and preserves existing content',
    () async {
      final duplicate = _event('same');
      final platform = _FakeAndroidSystemSharePlatform()
        ..enqueue(<AndroidSystemShareEvent>[
          duplicate,
          duplicate,
          _event('second'),
          _event('third'),
        ]);
      final inbox = AndroidSystemShareInbox(
        platform: platform,
        maxPendingEvents: 2,
        maxRecentEventIds: 4,
      );
      addTearDown(inbox.dispose);

      await inbox.initialize();

      expect(inbox.pendingEvents.map((event) => event.id), <String>[
        'same',
        'second',
      ]);
      expect(platform.discardedEventIds, contains('third'));
      expect(
        inbox.takeFailure()?.reason,
        AndroidSystemShareFailureReason.queueFull,
      );
      platform.enqueue(<AndroidSystemShareEvent>[duplicate]);
      await platform.notifyShareIntentReceived();
      expect(inbox.pendingEvents.map((event) => event.id), <String>[
        'same',
        'second',
      ]);
    },
  );

  test('take and takeAll consume Dart pending state', () async {
    final platform = _FakeAndroidSystemSharePlatform()
      ..enqueue(<AndroidSystemShareEvent>[_event('one'), _event('two')]);
    final inbox = AndroidSystemShareInbox(platform: platform);
    addTearDown(inbox.dispose);
    await inbox.initialize();

    expect(inbox.take('one')?.id, 'one');
    await Future<void>.delayed(Duration.zero);
    expect(platform.discardedEventIds, contains('one'));
    expect(inbox.takeAll().map((event) => event.id), <String>['two']);
    await Future<void>.delayed(Duration.zero);
    expect(platform.discardedEventIds, contains('two'));
    expect(inbox.hasPendingEvents, isFalse);
  });

  test('route progress is parsed, persisted, and completed durably', () async {
    final event = AndroidSystemShareEvent.fromMap(<Object?, Object?>{
      'id': 'progress',
      'text': 'caption',
      'targetPeerId': 'peer-a',
      'targetPublicKeyHash': _hashA,
      'textSent': true,
      'waitingForConnection': true,
      'items': <Object?>[
        <Object?, Object?>{
          'uri': 'content://provider/items/1',
          'displayName': 'one.bin',
          'mimeType': 'application/octet-stream',
          'size': 4,
        },
      ],
      'sentItemUris': <Object?>[
        'content://provider/items/1',
        'content://provider/not-part-of-event',
      ],
    });
    expect(event, isNotNull);
    expect(event!.targetPeerId, 'peer-a');
    expect(event.targetPublicKeyHash, _hashA);
    expect(event.textSent, isTrue);
    expect(event.waitingForConnection, isTrue);
    expect(event.sentItemUris, <String>['content://provider/items/1']);

    final platform = _FakeAndroidSystemSharePlatform()
      ..enqueue(<AndroidSystemShareEvent>[event]);
    final inbox = AndroidSystemShareInbox(platform: platform);
    addTearDown(inbox.dispose);
    await inbox.initialize();

    await inbox.persistProgress(
      eventId: 'progress',
      peerId: 'peer-b',
      publicKeyHash: _hashB,
      textSent: true,
      waitingForConnection: false,
      sentItemUris: event.sentItemUris,
    );
    expect(platform.progressPeerIds['progress'], 'peer-b');
    expect(inbox.event('progress')?.targetPeerId, 'peer-b');
    expect(inbox.event('progress')?.targetPublicKeyHash, _hashB);

    expect((await inbox.complete('progress'))?.id, 'progress');
    expect(platform.completedEventIds, contains('progress'));
    expect(inbox.event('progress'), isNull);
  });

  test('surfaces a persisted native rejection to the inbox', () async {
    final platform = _FakeAndroidSystemSharePlatform()
      ..enqueueFailures(<AndroidSystemShareFailure>[
        const AndroidSystemShareFailure(
          reason: AndroidSystemShareFailureReason.tooManyItems,
          receivedAt: 123,
        ),
      ]);
    final inbox = AndroidSystemShareInbox(platform: platform);
    addTearDown(inbox.dispose);

    await inbox.initialize();

    expect(
      inbox.takeFailure()?.reason,
      AndroidSystemShareFailureReason.tooManyItems,
    );
  });
}

AndroidSystemShareEvent _event(String id) {
  return AndroidSystemShareEvent(
    id: id,
    action: 'android.intent.action.SEND',
    mimeType: 'text/plain',
    text: id,
    items: const <AndroidSystemShareItem>[],
    receivedAt: 1,
  );
}

class _FakeAndroidSystemSharePlatform implements AndroidSystemSharePlatform {
  final Queue<List<AndroidSystemShareEvent>> _batches =
      Queue<List<AndroidSystemShareEvent>>();
  final Queue<List<AndroidSystemShareFailure>> _failureBatches =
      Queue<List<AndroidSystemShareFailure>>();
  AndroidSystemShareIntentHandler? _handler;
  int consumeCount = 0;
  final Set<String> discardedEventIds = <String>{};
  final Set<String> completedEventIds = <String>{};
  final Map<String, String> progressPeerIds = <String, String>{};

  void enqueue(List<AndroidSystemShareEvent> events) {
    _batches.add(events);
  }

  void enqueueFailures(List<AndroidSystemShareFailure> failures) {
    _failureBatches.add(failures);
  }

  Future<void> notifyShareIntentReceived() async {
    await _handler?.call(null);
  }

  @override
  Future<List<AndroidSystemShareEvent>> consumePendingShares() async {
    consumeCount += 1;
    return _batches.isEmpty
        ? const <AndroidSystemShareEvent>[]
        : _batches.removeFirst();
  }

  @override
  Future<List<AndroidSystemShareFailure>> consumePendingShareFailures() async {
    return _failureBatches.isEmpty
        ? const <AndroidSystemShareFailure>[]
        : _failureBatches.removeFirst();
  }

  @override
  void setShareIntentHandler(AndroidSystemShareIntentHandler? handler) {
    _handler = handler;
  }

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
    progressPeerIds[eventId] = peerId;
  }
}
