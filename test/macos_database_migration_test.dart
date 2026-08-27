import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:whisper/model/LocalDatabase.dart';

void main() {
  test('migrates the legacy macOS database into application support', () async {
    final root = await Directory.systemTemp.createTemp(
      'whisper-macos-database-migration-',
    );
    addTearDown(() => root.delete(recursive: true));
    final legacyDirectory = Directory('${root.path}/legacy')..createSync();
    final destinationDirectory = Directory('${root.path}/current');
    final legacyDatabase = File('${legacyDirectory.path}/db.sqlite');

    final source = sqlite3.open(legacyDatabase.path);
    source.execute('CREATE TABLE message (content TEXT NOT NULL)');
    source.execute("INSERT INTO message VALUES ('preserved')");
    source.dispose();

    final migrated = await migrateLegacyMacOSDatabase(
      legacyDatabase: legacyDatabase,
      destinationDirectory: destinationDirectory,
    );

    expect(migrated, isTrue);
    final copied = sqlite3.open('${destinationDirectory.path}/db.sqlite');
    addTearDown(copied.dispose);
    expect(
      copied.select('SELECT content FROM message').single['content'],
      'preserved',
    );
  });

  test('does not overwrite an existing current database', () async {
    final root = await Directory.systemTemp.createTemp(
      'whisper-macos-database-existing-',
    );
    addTearDown(() => root.delete(recursive: true));
    final legacyDirectory = Directory('${root.path}/legacy')..createSync();
    final destinationDirectory = Directory('${root.path}/current')
      ..createSync();
    final legacyDatabase = File('${legacyDirectory.path}/db.sqlite');
    final currentDatabase = File('${destinationDirectory.path}/db.sqlite');

    for (final entry in <(File, String)>[
      (legacyDatabase, 'legacy'),
      (currentDatabase, 'current'),
    ]) {
      final database = sqlite3.open(entry.$1.path);
      database.execute('CREATE TABLE value_store (value TEXT NOT NULL)');
      database.execute('INSERT INTO value_store VALUES (?)', [entry.$2]);
      database.dispose();
    }

    final migrated = await migrateLegacyMacOSDatabase(
      legacyDatabase: legacyDatabase,
      destinationDirectory: destinationDirectory,
    );

    expect(migrated, isTrue);
    final current = sqlite3.open(currentDatabase.path);
    addTearDown(current.dispose);
    expect(
      current.select('SELECT value FROM value_store').single['value'],
      'current',
    );
  });
}
