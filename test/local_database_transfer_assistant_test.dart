import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('transfer assistant database', () {
    late LocalDatabase database;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '_uuid': 'local',
      });
      database = LocalDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => database.close());

    test('searches all text for one peer and paginates newest first', () async {
      final oldest = await database.insertMessageReturning(
        _message(content: 'alpha project archive', timestamp: 1),
      );
      await database.insertMessageReturning(
        _message(content: '周末采购清单', timestamp: 2),
      );
      await database.insertMessageReturning(
        _message(
          content: 'alpha from another peer',
          sender: 'peer-b',
          timestamp: 3,
        ),
      );
      await database.insertMessageReturning(
        _message(
          content: 'alpha file metadata',
          type: MessageEnum.File,
          timestamp: 4,
        ),
      );
      final quoted = await database.insertMessageReturning(
        _message(content: 'a "quoted" reminder', timestamp: 5),
      );
      final newest = await database.insertMessageReturning(
        _message(content: 'latest note', timestamp: 6),
      );
      await database.insertMessageReturning(
        _message(
          content: 'clipboard sync artifact',
          timestamp: 7,
          clipboard: true,
        ),
      );

      final recent = await database.searchTextMessagesForPeer('peer-a');
      expect(
        recent.map((result) => result.message.id),
        <int>[newest.id, quoted.id, 2, oldest.id],
      );
      expect(
        await database.searchTextMessagesForPeer(
          'peer-a',
          query: 'clipboard sync artifact',
        ),
        isEmpty,
      );
      expect(
        (await database.searchTextMessagesForPeer(
          'peer-a',
          query: 'project',
        ))
            .single
            .message
            .id,
        oldest.id,
      );
      expect(
        (await database.searchTextMessagesForPeer(
          'peer-a',
          query: '周末采',
        ))
            .single
            .message
            .content,
        '周末采购清单',
      );
      expect(
        (await database.searchTextMessagesForPeer(
          'peer-a',
          query: '采购',
        ))
            .single
            .message
            .content,
        '周末采购清单',
      );
      expect(
        (await database.searchTextMessagesForPeer(
          'peer-a',
          query: '"quoted"',
        ))
            .single
            .message
            .id,
        quoted.id,
      );
      expect(
        (await database.searchTextMessagesForPeer(
          'peer-a',
          beforeId: quoted.id,
          limit: 1,
        ))
            .single
            .message
            .id,
        2,
      );
    });

    test('favorites are snapshots and never enter the message wire model',
        () async {
      final source = await database.insertMessageReturning(
        _message(content: 'keep this text', timestamp: 12),
      );

      await database.favoriteTextMessage(source, peerUid: 'peer-a');
      await database.favoriteTextMessage(source, peerUid: 'peer-a');

      var favorites = await database.fetchFavoriteTextsForPeer('peer-a');
      expect(favorites, hasLength(1));
      expect(favorites.single.sourceMessageId, source.id);
      expect(favorites.single.content, 'keep this text');
      expect(
        (await database.searchTextMessagesForPeer('peer-a')).single.isFavorite,
        isTrue,
      );

      await database.deleteMessage(source.id);
      favorites = await database.fetchFavoriteTextsForPeer('peer-a');
      expect(favorites.single.content, 'keep this text');

      await database.unfavoriteTextMessage(source.id);
      expect(await database.fetchFavoriteTextsForPeer('peer-a'), isEmpty);
    });

    test('rejects non-text, empty, missing, and wrong-peer favorites',
        () async {
      final file = await database.insertMessageReturning(
        _message(content: '{}', type: MessageEnum.File),
      );
      final empty = await database.insertMessageReturning(
        _message(content: '   '),
      );
      final text = await database.insertMessageReturning(
        _message(content: 'peer scoped'),
      );

      await expectLater(
        database.favoriteTextMessage(file, peerUid: 'peer-a'),
        throwsArgumentError,
      );
      await expectLater(
        database.favoriteTextMessage(empty, peerUid: 'peer-a'),
        throwsArgumentError,
      );
      await expectLater(
        database.favoriteTextMessage(text, peerUid: 'peer-b'),
        throwsArgumentError,
      );
      await expectLater(
        database.favoriteTextMessage(text.copyWith(id: 9999),
            peerUid: 'peer-a'),
        throwsStateError,
      );
    });
  });

  test('v10 migration adds favorites and rebuilds text search', () async {
    final directory =
        await Directory.systemTemp.createTemp('whisper-v9-search-');
    final file = File('${directory.path}/messages.sqlite');
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('''
      CREATE TABLE message (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        device_id INTEGER,
        sender TEXT NOT NULL DEFAULT '', receiver TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL DEFAULT '', clipboard INTEGER NOT NULL DEFAULT 0,
        size INTEGER NOT NULL DEFAULT 0, type INTEGER NOT NULL DEFAULT 0,
        content TEXT DEFAULT '', message TEXT DEFAULT '',
        timestamp INTEGER NOT NULL DEFAULT 0, uuid TEXT NOT NULL DEFAULT '',
        acked INTEGER NOT NULL DEFAULT 0, path TEXT NOT NULL DEFAULT '',
        md5 TEXT NOT NULL DEFAULT '', file_timestamp INTEGER DEFAULT 0
      )
    ''');
    raw.execute('''
      INSERT INTO message (sender, receiver, type, content, timestamp, uuid)
      VALUES ('peer-a', 'local', ${MessageEnum.Text.index},
              '迁移后的历史文本', 10, 'old-text')
    ''');
    raw.execute('PRAGMA user_version = 9');
    raw.dispose();

    final database = LocalDatabase.forTesting(NativeDatabase(file));
    try {
      final results = await database.searchTextMessagesForPeer(
        'peer-a',
        query: '历史文本',
      );
      expect(database.schemaVersion, 10);
      expect(results.single.message.content, '迁移后的历史文本');
      await database.favoriteTextMessage(
        results.single.message,
        peerUid: 'peer-a',
      );
      expect(await database.fetchFavoriteTextsForPeer('peer-a'), hasLength(1));
      final columns =
          await database.customSelect('PRAGMA table_info(favorite_text)').get();
      expect(
        columns.map((row) => row.read<String>('name')),
        containsAll(<String>[
          'source_message_id',
          'peer_uid',
          'content',
          'source_timestamp',
          'created_at',
        ]),
      );
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });
}

MessageData _message({
  required String content,
  String sender = 'peer-a',
  String receiver = 'local',
  MessageEnum type = MessageEnum.Text,
  int timestamp = 1,
  bool clipboard = false,
}) {
  return MessageData(
    id: 0,
    sender: sender,
    receiver: receiver,
    name: '',
    clipboard: clipboard,
    size: 0,
    type: type,
    content: content,
    message: '',
    timestamp: timestamp,
    uuid: '$sender-$timestamp-$content',
    acked: true,
    path: '',
    md5: '',
  );
}
