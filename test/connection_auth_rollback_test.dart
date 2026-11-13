import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/device_pruning.dart';

DeviceData _device(
  String uid, {
  String key = '',
  bool auth = false,
  String name = 'Peer',
}) {
  return DeviceData(
    id: 0,
    uid: uid,
    identityPublicKey: key,
    name: name,
    host: '192.168.1.10',
    port: 10002,
    password: '',
    platform: 'test',
    isServer: false,
    online: true,
    clipboard: true,
    auth: auth,
    lastTime: 1,
    around: true,
  );
}

void main() {
  late LocalDatabase database;

  setUp(() {
    database = LocalDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  // Every advertised id became a device row for good, so anyone on the
  // network could grow the database without end. Only strangers go.
  test('only the oldest never-trusted devices are forgotten', () async {
    Future<int> idOf(String uid) async =>
        (await database.fetchDevice(uid))!.id;
    await database.upsertDevice(_device('trusted'));
    await database.authDevice('trusted', true);
    await database.upsertDevice(_device('pinned'));
    await database.customStatement(
      "UPDATE device SET identity_public_key = 'key' WHERE uid = 'pinned'",
    );
    await database.upsertDevice(_device('web-visitor'));
    await database.upsertDevice(_device('talked'));
    await database.customStatement(
      'INSERT INTO message (device_id) VALUES (?)',
      [await idOf('talked')],
    );
    for (var i = 0; i < 10; i++) {
      await database.upsertDevice(_device('stranger-$i'));
    }
    await database.pruneStrangers(keep: 3);
    final left = (await database.select(database.device).get())
        .map((row) => row.uid)
        .toSet();
    expect(left, {
      'trusted',
      'pinned',
      'talked',
      'web-visitor',
      'stranger-7',
      'stranger-8',
      'stranger-9',
    });
  });

  test('rolls back a newly pinned row after auth registration is cancelled',
      () async {
    final committed = await database.commitAuthenticatedDevice(
      candidate: _device('peer-a'),
      publicKey: 'new-key',
      replaceIdentity: false,
      expectedPublicKey: '',
      requireCurrent: () {},
    );
    expect(committed.auth, isTrue);

    final rolledBack = await database.rollbackAuthenticatedDevice(
      peerId: 'peer-a',
      attemptedPublicKey: 'new-key',
      previous: null,
    );

    expect(rolledBack, isTrue);
    expect(await database.fetchDevice('peer-a'), isNull);
  });

  test('restores the exact previous row with a compare-and-set guard',
      () async {
    await database.upsertDevice(_device('peer-a'));
    final previous = await database.fetchDevice('peer-a');
    await database.commitAuthenticatedDevice(
      candidate: _device('peer-a', name: 'Changed'),
      publicKey: 'new-key',
      replaceIdentity: false,
      expectedPublicKey: '',
      requireCurrent: () {},
    );

    expect(
      await database.rollbackAuthenticatedDevice(
        peerId: 'peer-a',
        attemptedPublicKey: 'other-key',
        previous: previous,
      ),
      isFalse,
    );
    expect((await database.fetchDevice('peer-a'))?.auth, isTrue);

    expect(
      await database.rollbackAuthenticatedDevice(
        peerId: 'peer-a',
        attemptedPublicKey: 'new-key',
        previous: previous,
      ),
      isTrue,
    );
    final restored = await database.fetchDevice('peer-a');
    expect(restored?.identityPublicKey, isEmpty);
    expect(restored?.auth, isFalse);
    expect(restored?.name, previous?.name);
  });
}
