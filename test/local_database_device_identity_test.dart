import 'dart:io';

import 'package:drift/drift.dart' show DataClass, Insertable, Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:whisper/model/LocalDatabase.dart';

DeviceData _device(
  String uid, {
  String name = 'Peer',
  String host = '192.168.1.2',
  int port = 10002,
  bool auth = false,
  bool clipboard = true,
  String identityPublicKey = '',
}) {
  return DeviceData(
    id: 0,
    uid: uid,
    name: name,
    host: host,
    port: port,
    password: '',
    platform: 'test',
    isServer: false,
    online: true,
    clipboard: clipboard,
    auth: auth,
    lastTime: 1,
    around: true,
    identityPublicKey: identityPublicKey,
  );
}

Future<bool> _hasUniqueUidIndex(LocalDatabase database) async {
  final indexes =
      await database.customSelect('PRAGMA index_list(device)').get();
  return indexes.any((row) => row.read<int>('unique') == 1);
}

void main() {
  group('device identity schema', () {
    late LocalDatabase database;

    setUp(() {
      database = LocalDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test('fresh schema has a non-null pin and unique uid index', () async {
      await database.upsertDevice(_device('peer-a'));

      final row = await database.fetchDevice('peer-a');
      expect(row, isNotNull);
      expect(row!.identityPublicKey, isEmpty);
      expect(await _hasUniqueUidIndex(database), isTrue);
      expect(
        () => database.into(database.device).insert(
              DeviceCompanion.insert(
                uid: const Value('peer-a'),
                host: '192.168.1.3',
                port: 10003,
              ),
            ),
        throwsA(anything),
      );
    });

    test('pin APIs distinguish legacy trust from a pinned identity', () async {
      await database.upsertDevice(_device('legacy'));
      await database.authDevice('legacy', true);

      expect(await database.fetchPinnedIdentityKey('legacy'), isNull);
      expect(await database.hasPinnedIdentity('legacy', 'public-key'), isFalse);
      expect(await database.fetchTrustedPeerIds(), isNot(contains('legacy')));

      expect(
        await database.pinDeviceIdentity('legacy', 'public-key'),
        DeviceIdentityPinResult.pinned,
      );

      expect(await database.fetchPinnedIdentityKey('legacy'), 'public-key');
      expect(await database.hasPinnedIdentity('legacy', 'public-key'), isTrue);
      expect(await database.hasPinnedIdentity('legacy', 'different'), isFalse);
      expect(await database.fetchTrustedPeerIds(), contains('legacy'));
    });

    test('concurrent discovery upserts retain auth and pinned key', () async {
      await database.upsertDevice(_device('peer-a'));
      await database.authDevice('peer-a', true);
      expect(
        await database.pinDeviceIdentity('peer-a', 'pinned-key'),
        DeviceIdentityPinResult.pinned,
      );

      await Future.wait(List<Future<void>>.generate(
        20,
        (index) => database.upsertDevice(
          _device(
            'peer-a',
            name: 'Peer $index',
            host: '192.168.1.${index + 10}',
            port: 11000 + index,
          ),
        ),
      ));

      final rows = await database.fetchAllDevice();
      expect(rows.where((row) => row.uid == 'peer-a'), hasLength(1));
      final stored = await database.fetchDevice('peer-a');
      expect(stored!.auth, isTrue);
      expect(stored.identityPublicKey, 'pinned-key');
    });

    test('DeviceData retains generated Drift row contracts', () async {
      final row = _device(
        'row-contract',
        identityPublicKey: 'identity-key',
      );

      expect(row, isA<DataClass>());
      expect(row, isA<Insertable<DeviceData>>());
      expect(
        (row as Insertable<DeviceData>).toColumns(true).keys,
        containsAll(<String>[
          'uid',
          'identity_public_key',
          'host',
          'port',
        ]),
      );
      final companion = row.toCompanion(true);
      expect(companion.identityPublicKey.value, 'identity-key');
      final copied = row.copyWithCompanion(
        const DeviceCompanion(
          name: Value<String>('Renamed'),
          password: Value<String?>(null),
        ),
      );
      expect(copied.name, 'Renamed');
      expect(copied.password, isNull);

      final nullable = row.copyWith(
        password: const Value<String?>(null),
        around: const Value<bool?>(null),
      );
      expect(nullable.toColumns(true), isNot(contains('password')));
      expect(nullable.toColumns(true), isNot(contains('around')));
      final explicitNulls = nullable.toColumns(false);
      expect(
        (explicitNulls['password']! as Variable<String>).value,
        isNull,
      );
      expect(
        (explicitNulls['around']! as Variable<bool>).value,
        isNull,
      );
      final nullableCompanion = nullable.toCompanion(false);
      expect(nullableCompanion.password.present, isTrue);
      expect(nullableCompanion.password.value, isNull);
      expect(nullableCompanion.around.present, isTrue);
      expect(nullableCompanion.around.value, isNull);

      await database.into(database.device).insert(row);
      expect(
        (await database.fetchDevice('row-contract'))?.identityPublicKey,
        'identity-key',
      );
    });

    test('pin and replacement APIs use compare-and-set semantics', () async {
      await database.upsertDevice(_device('peer-race'));

      final results = await Future.wait(<Future<DeviceIdentityPinResult>>[
        database.pinDeviceIdentity('peer-race', 'first-key'),
        database.pinDeviceIdentity('peer-race', 'second-key'),
      ]);
      expect(results, contains(DeviceIdentityPinResult.pinned));
      expect(results, contains(DeviceIdentityPinResult.conflict));
      final current = await database.fetchPinnedIdentityKey('peer-race');
      expect(current, isNotNull);
      expect(
        await database.pinDeviceIdentity('peer-race', current!),
        DeviceIdentityPinResult.alreadyPinned,
      );
      expect(
        await database.replaceDeviceIdentity(
          'peer-race',
          expectedPublicKey: 'stale-key',
          newPublicKey: 'replacement-key',
        ),
        DeviceIdentityPinResult.conflict,
      );
      expect(
        await database.replaceDeviceIdentity(
          'peer-race',
          expectedPublicKey: current,
          newPublicKey: 'replacement-key',
        ),
        DeviceIdentityPinResult.replaced,
      );
      expect(
        await database.pinDeviceIdentity('missing', 'key'),
        DeviceIdentityPinResult.missingDevice,
      );
      expect(
        await database.replaceDeviceIdentity(
          'missing',
          expectedPublicKey: 'old',
          newPublicKey: 'new',
        ),
        DeviceIdentityPinResult.missingDevice,
      );
    });
  });

  test('schema 5 upgrade deduplicates identities and is reopen-idempotent',
      () async {
    final directory = await Directory.systemTemp.createTemp('whisper-db-test-');
    final file = File('${directory.path}/legacy.sqlite');
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('''
      CREATE TABLE device (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        uid TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL DEFAULT '',
        host TEXT NOT NULL,
        port INTEGER NOT NULL,
        password TEXT DEFAULT '',
        platform TEXT NOT NULL DEFAULT '',
        is_server INTEGER NOT NULL DEFAULT 0,
        online INTEGER NOT NULL DEFAULT 0,
        clipboard INTEGER NOT NULL DEFAULT 0,
        auth INTEGER NOT NULL DEFAULT 0,
        last_time INTEGER NOT NULL DEFAULT 0,
        around INTEGER DEFAULT 0
      )
    ''');
    raw.execute('''
      INSERT INTO device
        (uid, name, host, port, auth, clipboard, last_time)
      VALUES
        ('', 'invalid', '127.0.0.1', 1, 1, 1, 99),
        ('peer-a', 'old', '192.168.1.2', 10002, 0, 1, 5),
        ('peer-a', 'trusted', '192.168.1.3', 10003, 1, 0, 4),
        ('peer-a', 'latest', '192.168.1.4', 10004, 0, 0, 9)
    ''');
    raw.execute('''
      CREATE TABLE message (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        device_id INTEGER REFERENCES device(id)
      )
    ''');
    raw.execute('''
      INSERT INTO message (device_id) VALUES (2), (3), (4)
    ''');
    raw.execute('PRAGMA user_version = 5');
    raw.dispose();

    var database = LocalDatabase.forTesting(NativeDatabase(file));
    try {
      final rows = await database.fetchAllDevice();
      expect(rows, hasLength(1));
      expect(rows.single.uid, 'peer-a');
      expect(rows.single.name, 'latest');
      expect(rows.single.host, '192.168.1.4');
      expect(rows.single.port, 10004);
      expect(rows.single.auth, isTrue);
      expect(rows.single.clipboard, isTrue);
      expect(rows.single.identityPublicKey, isEmpty);
      final messageRows = await database
          .customSelect('SELECT device_id FROM message ORDER BY id')
          .get();
      expect(
        messageRows.map((row) => row.read<int>('device_id')),
        everyElement(rows.single.id),
      );
      expect(await _hasUniqueUidIndex(database), isTrue);
      expect(database.schemaVersion, 6);
    } finally {
      await database.close();
    }

    database = LocalDatabase.forTesting(NativeDatabase(file));
    try {
      expect(await database.fetchAllDevice(), hasLength(1));
      expect(await _hasUniqueUidIndex(database), isTrue);
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });
}
