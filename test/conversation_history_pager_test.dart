import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/state/conversation_history_pager.dart';

MessageData message(int id, {String? uuid}) => MessageData(
  id: id,
  sender: 'peer',
  receiver: 'self',
  name: '',
  clipboard: false,
  size: 0,
  type: MessageEnum.Text,
  timestamp: id,
  uuid: uuid ?? 'message-$id',
  acked: true,
  path: '',
  md5: '',
);

void main() {
  test(
    'rapid scroll requests only read one page and stop at history end',
    () async {
      final pending = Completer<List<MessageData>>();
      var reads = 0;
      final pager = ConversationHistoryPager((cursor, limit) {
        reads++;
        expect(cursor, 21);
        expect(limit, 12);
        return pending.future;
      });
      addTearDown(pager.dispose);
      final first = pager.load(beforeId: 21);
      expect(await pager.load(beforeId: 21), isEmpty);
      expect(pager.loading, isTrue);
      pending.complete([message(20)]);
      expect((await first).single.id, 20);
      expect(pager.hasMore, isFalse);
      expect(await pager.load(beforeId: 20), isEmpty);
      expect(reads, 1);
    },
  );

  test('failed history read remains retryable with the same cursor', () async {
    var reads = 0;
    final pager = ConversationHistoryPager((cursor, limit) async {
      if (++reads == 1) throw const FileSystemException('unavailable');
      return [message(9)];
    });
    addTearDown(pager.dispose);
    expect(await pager.load(beforeId: 10), isEmpty);
    expect(pager.failed, isTrue);
    expect(pager.loading, isFalse);
    expect((await pager.load(beforeId: 10)).single.id, 9);
    expect(pager.failed, isFalse);
  });

  test('clear or disposal discards an outstanding page', () async {
    for (final dispose in [false, true]) {
      final pending = Completer<List<MessageData>>();
      final pager = ConversationHistoryPager((_, _) => pending.future);
      final page = pager.load();
      if (dispose) {
        pager.dispose();
      } else {
        pager.reset();
      }
      pending.complete([message(1)]);
      expect(await page, isEmpty);
      if (!dispose) {
        expect(pager.hasMore, isTrue);
        pager.dispose();
      }
    }
  });

  test(
    'history merge preserves live arrivals and removes overlapping rows',
    () {
      final existing = [message(22), message(21)];
      final page = unseenHistoryMessages(existing, [
        message(21),
        message(20),
        message(20),
        message(19, uuid: ''),
      ]);
      expect(page.map((m) => m.id), [20, 19]);
      expect(
        unseenHistoryMessages([message(19, uuid: '')], page).map((m) => m.id),
        [20],
      );
    },
  );

  test('conversation restores transfer metadata after every loaded page', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final load = source.substring(
      source.indexOf('  Future<void> _loadMoreMessages()'),
      source.indexOf('  _insertItem('),
    );
    expect(load, contains('await _loadTransferSnapshotsForMessages(page)'));
    expect(load, contains('!mounted ||'));
    expect(load, contains('generation != _history.generation'));
  });
}
