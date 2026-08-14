import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:whisper/model/LocalDatabase.dart';

void main() {
  test('file database uses WAL with normal durability', () {
    final directory = Directory.systemTemp.createTempSync(
      'whisper-database-journal-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final database = sqlite3.open('${directory.path}/db.sqlite');
    addTearDown(database.dispose);

    configureWhisperDatabase(database);

    expect(database.select('PRAGMA journal_mode').single.values.single, 'wal');
    expect(database.select('PRAGMA synchronous').single.values.single, 1);
  });
}
