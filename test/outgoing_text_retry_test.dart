import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/outgoing_text_retry.dart';
import 'package:whisper/socket/wire_message_replay.dart';

MessageData _message({
  required String uuid,
  String sender = 'self',
  String receiver = 'peer',
  String content = 'retry me',
  bool clipboard = false,
  int timestamp = 1,
  bool acked = false,
  int id = 0,
  MessageEnum type = MessageEnum.Text,
}) {
  return MessageData(
    id: id,
    sender: sender,
    receiver: receiver,
    name: '',
    clipboard: clipboard,
    size: 0,
    type: type,
    content: content,
    message: '',
    timestamp: timestamp,
    uuid: uuid,
    acked: acked,
    path: '',
    md5: '',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('prepareOutgoingTextWithRetryIdentity', () {
    test('reuses one persisted UUID only for an explicit retry', () async {
      MessageData? pending;
      var inserts = 0;

      Future<PreparedOutgoingText> prepare(MessageData draft) {
        return prepareOutgoingTextWithRetryIdentity(
          draft: draft,
          retry: pending,
          persist: (message) async {
            inserts++;
            pending = message.copyWith(id: 17);
            return pending!;
          },
        );
      }

      final first = await prepare(_message(uuid: 'first-uuid'));
      final retry = await prepare(_message(uuid: 'new-draft-uuid'));

      expect(inserts, 1);
      expect(first.message.uuid, 'first-uuid');
      expect(first.message.id, 17);
      expect(first.isNew, isTrue);
      expect(retry.message.uuid, 'first-uuid');
      expect(retry.isNew, isFalse);
    });

    test('does not mark an unpersisted draft as prepared', () async {
      final draft = _message(uuid: 'storage-error');

      await expectLater(
        prepareOutgoingTextWithRetryIdentity(
          draft: draft,
          persist: (_) =>
              Future<MessageData>.error(StateError('storage failed')),
        ),
        throwsStateError,
      );
    });
  });

  group('OutgoingTextRetryRegistry', () {
    test('short-circuits a retry whose original UUID was acknowledged',
        () async {
      final registry = OutgoingTextRetryRegistry();
      final failed = _message(uuid: 'stable-uuid');
      registry.rememberFailure(failed);
      final acknowledged = failed.copyWith(acked: true, id: 9);

      final resolution = await registry.resolve(
        _message(uuid: 'new-uuid'),
        fetchByUuid: (_) async => <MessageData>[acknowledged],
      );

      expect(resolution.message?.uuid, failed.uuid);
      expect(resolution.alreadyAcknowledged, isTrue);
      expect(registry.hasRetryForPeer(failed.receiver), isFalse);
    });

    test('keeps independent failed intents for the same peer', () async {
      final registry = OutgoingTextRetryRegistry();
      final failedA = _message(uuid: 'stable-a', content: 'intent a');
      final failedB = _message(uuid: 'stable-b', content: 'intent b');
      registry.rememberFailure(failedA);
      registry.rememberFailure(failedB);

      final retryA = await registry.resolve(
        _message(uuid: 'new-a', content: 'intent a'),
        fetchByUuid: (_) async => <MessageData>[failedA.copyWith(id: 8)],
      );
      final retryB = await registry.resolve(
        _message(uuid: 'new-b', content: 'intent b'),
        fetchByUuid: (_) async => <MessageData>[failedB.copyWith(id: 9)],
      );

      expect(retryA.message?.uuid, failedA.uuid);
      expect(retryB.message?.uuid, failedB.uuid);
      expect(retryA.alreadyAcknowledged, isFalse);
      expect(retryB.alreadyAcknowledged, isFalse);
      expect(registry.hasRetryForPeer(failedA.receiver), isTrue);
    });

    test('selects the exact historical wire identity for a cached retry',
        () async {
      final registry = OutgoingTextRetryRegistry();
      final failed = _message(uuid: 'shared', timestamp: 1);
      registry.rememberFailure(failed);

      final resolution = await registry.resolve(
        _message(uuid: 'draft'),
        fetchByUuid: (_) async => <MessageData>[
          _message(uuid: 'shared', timestamp: 2, id: 9),
          failed.copyWith(id: 8),
        ],
      );

      expect(resolution.message?.id, 8);
      expect(resolution.message?.timestamp, 1);
    });
  });

  group('OutgoingTextSendLocks', () {
    test('serializes one peer without blocking a different peer', () async {
      final locks = OutgoingTextSendLocks();
      final releaseA = Completer<void>();
      final enteredA = Completer<void>();
      final events = <String>[];

      final sendA = locks.synchronized('peer-a', () async {
        events.add('a-start');
        enteredA.complete();
        await releaseA.future;
        events.add('a-end');
        return true;
      });
      await enteredA.future;
      final sendB = locks.synchronized('peer-b', () async {
        events.add('b');
        return true;
      });

      expect(await sendB, isTrue);
      expect(events, <String>['a-start', 'b']);
      releaseA.complete();
      expect(await sendA, isTrue);
      expect(events, <String>['a-start', 'b', 'a-end']);
    });

    test('keeps sends for the same peer ordered', () async {
      final locks = OutgoingTextSendLocks();
      final releaseFirst = Completer<void>();
      final enteredFirst = Completer<void>();
      var secondEntered = false;

      final first = locks.synchronized('peer', () async {
        enteredFirst.complete();
        await releaseFirst.future;
      });
      await enteredFirst.future;
      final second = locks.synchronized('peer', () async {
        secondEntered = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(secondEntered, isFalse);

      releaseFirst.complete();
      await Future.wait(<Future<void>>[first, second]);
      expect(secondEntered, isTrue);
    });
  });

  group('outgoing message identities', () {
    late LocalDatabase database;

    setUp(() {
      database = LocalDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => database.close());

    test('keeps intentional identical sends on distinct UUIDs', () async {
      final prepared = <PreparedOutgoingText>[];

      Future<void> send(MessageData draft) async {
        prepared.add(
          await prepareOutgoingTextWithRetryIdentity(
            draft: draft,
            persist: database.insertMessageReturning,
          ),
        );
      }

      await send(_message(uuid: 'first-intent'));
      await send(_message(uuid: 'second-intent'));

      expect(
        prepared.map((result) => result.message.uuid),
        <String>['first-intent', 'second-intent'],
      );
      expect(prepared.every((result) => result.isNew), isTrue);
      expect(prepared.every((result) => result.message.id > 0), isTrue);
      expect(
        (await database.fetchMessageList('peer'))
            .map((message) => message.uuid),
        containsAll(<String>['first-intent', 'second-intent']),
      );
    });

    test('acknowledges historical duplicate UUID rows without throwing',
        () async {
      final duplicate = _message(uuid: 'legacy-duplicate');
      await database.insertMessage(duplicate);
      await database.insertMessage(duplicate.copyWith(timestamp: 2));

      final acknowledged = await database.ackMessage(duplicate);

      expect(acknowledged?.uuid, duplicate.uuid);
      expect(acknowledged?.timestamp, 1);
      expect(acknowledged?.acked, isTrue);
      expect(
        await database.fetchMessagesByUuid(duplicate.uuid),
        hasLength(2),
      );
      expect(
        (await database.fetchMessageByUuid(duplicate.uuid))?.acked,
        isTrue,
      );
    });

    test('returning insert preserves explicit local acknowledgement', () async {
      final local = _message(
        uuid: 'local-message',
        receiver: '',
        acked: true,
      );

      final persisted = await database.insertMessageReturning(local);

      expect(persisted.id, greaterThan(0));
      expect(persisted.acked, isTrue);
      expect(
        (await database.fetchMessageByUuid(local.uuid))?.acked,
        isTrue,
      );

      await database.deleteMessage(persisted.id);
      expect(await database.fetchMessageByUuid(local.uuid), isNull);
    });

    test('legacy insert keeps untrusted wire acknowledgement pending',
        () async {
      final remote = _message(uuid: 'remote-message', acked: true);

      await database.insertMessage(remote);

      expect(
        (await database.fetchMessageByUuid(remote.uuid))?.acked,
        isFalse,
      );
    });

    test('UUID replay lookups use the message index', () async {
      final indexes =
          await database.customSelect('PRAGMA index_list(message)').get();
      expect(
        indexes.map((row) => row.read<String>('name')),
        contains('message_uuid_lookup'),
      );

      final plan = await database.customSelect(
        'EXPLAIN QUERY PLAN SELECT * FROM message WHERE uuid = ?',
        variables: <Variable<Object>>[
          const Variable<String>('indexed-uuid'),
        ],
      ).get();
      expect(
        plan.map((row) => row.read<String>('detail')).join('\n'),
        contains('message_uuid_lookup'),
      );
    });
  });

  group('wire message replay classification', () {
    test('accepts a new UUID and deduplicates the same wire message', () {
      final incoming = _message(uuid: 'same');
      final stored = incoming.copyWith(id: 42, acked: true);

      expect(
        classifyWireMessageReplay(existing: null, incoming: incoming),
        WireMessageReplayDecision.accept,
      );
      expect(
        classifyWireMessageReplay(existing: stored, incoming: incoming),
        WireMessageReplayDecision.duplicate,
      );
    });

    test('rejects an empty UUID before persistence', () {
      expect(
        classifyWireMessageReplay(
          existing: null,
          incoming: _message(uuid: ''),
        ),
        WireMessageReplayDecision.conflict,
      );
    });

    test('treats reused UUID with changed signed content as a conflict', () {
      final existing = _message(uuid: 'collision');

      for (final conflicting in <MessageData>[
        _message(uuid: 'collision', sender: 'other'),
        _message(uuid: 'collision', content: 'changed'),
        _message(uuid: 'collision', timestamp: 2),
      ]) {
        expect(
          classifyWireMessageReplay(
            existing: existing,
            incoming: conflicting,
          ),
          WireMessageReplayDecision.conflict,
        );
      }
    });

    test('matches any exact historical candidate before declaring conflict',
        () {
      final incoming = _message(uuid: 'history', timestamp: 1);
      expect(
        classifyWireMessageReplayCandidates(
          existing: <MessageData>[
            incoming.copyWith(timestamp: 2, id: 2),
            incoming.copyWith(id: 1),
          ],
          incoming: incoming,
        ),
        WireMessageReplayDecision.duplicate,
      );
    });
  });

  group('WireMessageReplayGuard', () {
    late LocalDatabase database;

    setUp(() {
      database = LocalDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => database.close());

    test('atomically persists one of two concurrent identical claims',
        () async {
      final guard = WireMessageReplayGuard();
      final incoming = _message(uuid: 'concurrent');

      final claims = await Future.wait(
        List<Future<WireMessageReplayClaim>>.generate(
          2,
          (_) => guard.claim(
            incoming,
            fetchExisting: database.fetchMessagesByUuid,
            persist: database.insertMessageReturning,
          ),
        ),
      );

      expect(
        claims.map((claim) => claim.decision),
        contains(WireMessageReplayDecision.accept),
      );
      expect(
        claims.map((claim) => claim.decision),
        contains(WireMessageReplayDecision.duplicate),
      );
      expect(claims.every((claim) => claim.message!.id > 0), isTrue);
      expect(await database.fetchMessagesByUuid(incoming.uuid), hasLength(1));
    });

    test('does not persist an empty UUID', () async {
      var persists = 0;
      final decision = await WireMessageReplayGuard().claim(
        _message(uuid: ''),
        fetchExisting: (_) async => const <MessageData>[],
        persist: (message) async {
          persists++;
          return message;
        },
      );

      expect(decision.decision, WireMessageReplayDecision.conflict);
      expect(persists, 0);
    });

    test('file claims can ignore receiver-local path when matching replay',
        () async {
      final guard = WireMessageReplayGuard();
      final incoming = _message(uuid: 'shared').copyWith(
        type: MessageEnum.File,
        path: '',
      );
      final persisted = incoming.copyWith(id: 7, path: '/downloads/file.bin');

      var persists = 0;
      final claim = await guard.claim(
        incoming,
        fetchExisting: (_) async => <MessageData>[persisted],
        isDuplicate: (existing, message) =>
            existing.uuid == message.uuid &&
            existing.sender == message.sender &&
            existing.receiver == message.receiver &&
            existing.type == message.type &&
            existing.content == message.content,
        persist: (message) async {
          persists++;
          return message;
        },
      );

      expect(claim.decision, WireMessageReplayDecision.duplicate);
      expect(claim.message?.id, 7);
      expect(persists, 0);
    });

    test('durable non-message UUID claims reject text persistence', () async {
      var persists = 0;
      final claim = await WireMessageReplayGuard().claim(
        _message(uuid: 'transfer-owned'),
        fetchExisting: (_) async => const <MessageData>[],
        hasExternalClaim: (_) async => true,
        persist: (message) async {
          persists++;
          return message;
        },
      );

      expect(claim.decision, WireMessageReplayDecision.conflict);
      expect(persists, 0);
    });
  });

  test('acknowledgement failures are contained for local side effects',
      () async {
    Object? captured;
    final sent = await sendAcknowledgementBestEffort(
      send: () => Future<bool>.error(StateError('socket closed')),
      onError: (error, _) => captured = error,
    );

    expect(sent, isFalse);
    expect(captured, isA<StateError>());
  });

  test('socket manager wires persistent retry identity and replay guard', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('prepareOutgoingTextWithRetryIdentity('));
    expect(source, isNot(contains('fetchPendingOutgoingText(')));
    expect(source, contains('_wireMessageReplayGuard.claim('));
    expect(source, contains('message = replay.message!'));
    expect(source, contains('fetchMessagesByUuid'));
    expect(source, contains('WireMessageReplayDecision.duplicate'));
    expect(source, contains("'message_uuid_conflict'"));
    expect(source, contains('_outgoingTextRetries.rememberFailure('));
    expect(source, contains('alreadyAcknowledged'));
    expect(source, contains('_outgoingTextSendLocks.synchronized('));

    final textMessageCase = source.substring(
      source.indexOf('case MessageEnum.Text:'),
      source.indexOf('case MessageEnum.Notification:'),
    );
    expect(
      textMessageCase.indexOf('_dispatchToAll('),
      lessThan(textMessageCase.indexOf('await _ackMessage(message)')),
    );

    final duplicateReplayCase = source.substring(
      source.indexOf('case WireMessageReplayDecision.duplicate:'),
      source.indexOf('case WireMessageReplayDecision.conflict:'),
    );
    expect(duplicateReplayCase, contains('message = replay.message!'));
    expect(
      duplicateReplayCase.indexOf('_dispatchToAll('),
      lessThan(duplicateReplayCase.indexOf('await _ackMessage(message)')),
    );

    final textCase = source.substring(
      source.indexOf('case MessageEnum.Text:'),
      source.indexOf('case MessageEnum.File:'),
    );
    expect(textCase, isNot(contains('insertMessage(message)')));

    final transferSource =
        File('lib/socket/file_transfer_engine.dart').readAsStringSync();
    expect(transferSource, contains('await _ackMessage(message);'));
    expect(
      RegExp(r'insertMessageReturning\(').allMatches(transferSource),
      hasLength(3),
    );
  });
}
