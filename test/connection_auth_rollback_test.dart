import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';

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
