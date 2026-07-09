import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';

import '../helper/helper.dart';
import 'device.dart';
import 'file_transfer.dart';
import 'message.dart';

export 'device.dart' show DeviceData;

part 'LocalDatabase.g.dart';

@DriftDatabase(tables: [Device, Message, FileTransfer, RemoteInputLayout])
class LocalDatabase extends _$LocalDatabase {
  static final LocalDatabase _singleton = LocalDatabase._internal();

  // 私有构造函数，阻止类被直接实例化
  LocalDatabase._internal() : super(_openConnection());

  LocalDatabase.forTesting(super.executor);

  // 工厂构造函数，返回单例实例
  factory LocalDatabase() {
    return _singleton;
  }

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            await m.createTable(fileTransfer);
          }
          if (from < 3) {
            await m.createTable(remoteInputLayout);
          }
          if (from < 5) {
            await _repairRemoteInputLayoutColumns();
          }
          if (from < 6) {
            await _migrateDeviceIdentitySchema(m);
          }
        },
        beforeOpen: (_) async {
          await _repairRemoteInputLayoutColumns();
        },
      );

  Future<void> _migrateDeviceIdentitySchema(Migrator migrator) async {
    final existingColumns =
        await customSelect('PRAGMA table_info(device)').get();
    if (existingColumns.isEmpty) {
      await migrator.createTable(device);
      return;
    }
    final hasIdentityColumn = existingColumns.any(
      (row) => row.read<String>('name') == 'identity_public_key',
    );
    if (!hasIdentityColumn) {
      await migrator.addColumn(device, device.identityPublicKey);
    }
    await customStatement("DELETE FROM device WHERE uid = ''");

    final duplicateUids = await customSelect(
      'SELECT uid FROM device GROUP BY uid HAVING COUNT(*) > 1',
    ).get();
    for (final duplicate in duplicateUids) {
      final uid = duplicate.read<String>('uid');
      final rows = await customSelect(
        'SELECT id, auth, clipboard FROM device WHERE uid = ? '
        'ORDER BY auth DESC, last_time DESC, id DESC',
        variables: <Variable<Object>>[Variable<String>(uid)],
      ).get();
      final keeperId = rows.first.read<int>('id');
      final mergedAuth = rows.any((row) => row.read<int>('auth') == 1);
      final mergedClipboard =
          rows.any((row) => row.read<int>('clipboard') == 1);
      await customUpdate(
        'UPDATE device SET auth = ?, clipboard = ? WHERE id = ?',
        variables: <Variable<Object>>[
          Variable<bool>(mergedAuth),
          Variable<bool>(mergedClipboard),
          Variable<int>(keeperId),
        ],
        updates: <TableInfo<Table, Object?>>{device},
      );
      await customUpdate(
        'DELETE FROM device WHERE uid = ? AND id <> ?',
        variables: <Variable<Object>>[
          Variable<String>(uid),
          Variable<int>(keeperId),
        ],
        updates: <TableInfo<Table, Object?>>{device},
      );
    }

    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS device_uid_unique ON device(uid)',
    );
  }

  Future<void> _repairRemoteInputLayoutColumns() async {
    final columns =
        await customSelect('PRAGMA table_info(remote_input_layout)').get();
    if (columns.isEmpty) {
      return;
    }
    final hasAutoRole = columns.any((row) => row.data['name'] == 'auto_role');
    final hasLayoutVersion =
        columns.any((row) => row.data['name'] == 'layout_version');
    final hasLayoutJson =
        columns.any((row) => row.data['name'] == 'layout_json');
    if (!hasAutoRole) {
      await customStatement(
        "ALTER TABLE remote_input_layout ADD COLUMN auto_role TEXT DEFAULT '${RemoteInputAutoRole.source.name}'",
      );
    }
    if (!hasLayoutVersion) {
      await customStatement(
        'ALTER TABLE remote_input_layout ADD COLUMN layout_version INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (!hasLayoutJson) {
      await customStatement(
        "ALTER TABLE remote_input_layout ADD COLUMN layout_json TEXT NOT NULL DEFAULT ''",
      );
    }
    await customUpdate(
      'UPDATE remote_input_layout SET auto_role = ? '
      'WHERE auto_role IS NULL OR auto_role = ?',
      variables: [
        Variable<String>(RemoteInputAutoRole.source.name),
        const Variable<String>(''),
      ],
      updates: {remoteInputLayout},
    );
    await customUpdate(
      'UPDATE remote_input_layout SET layout_version = ? '
      'WHERE layout_version IS NULL',
      variables: [
        const Variable<int>(1),
      ],
      updates: {remoteInputLayout},
    );
    await customUpdate(
      'UPDATE remote_input_layout SET layout_json = ? '
      'WHERE layout_json IS NULL',
      variables: [
        const Variable<String>(''),
      ],
      updates: {remoteInputLayout},
    );
  }

  Future<void> insertMessage(MessageData data) {
    return into(message).insert(MessageCompanion.insert(
        sender: Value(data.sender),
        receiver: Value(data.receiver),
        content: Value(data.content),
        message: Value(data.message),
        name: Value(data.name),
        clipboard: Value(data.clipboard),
        size: Value(data.size),
        type: Value(data.type),
        timestamp: Value(data.timestamp),
        acked: const Value(false),
        uuid: Value(data.uuid),
        path: Value(data.path),
        md5: Value(data.md5),
        fileTimestamp: Value(data.fileTimestamp)));
  }

  Future<MessageData?> ackMessage(MessageData data) async {
    if (data.uuid.isEmpty) {
      return null;
    }
    await (update(message)..where((t) => t.uuid.equals(data.uuid))).write(
      const MessageCompanion(
        acked: Value(true),
      ),
    );
    return await (select(message)..where((t) => t.uuid.equals(data.uuid)))
        .getSingleOrNull();
  }

  Future<void> upsertDevice(DeviceData data) async {
    if (data.uid.isEmpty) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await customInsert(
      'INSERT INTO device '
      '(uid, identity_public_key, name, host, port, platform, is_server, '
      'online, clipboard, auth, last_time, around) '
      "VALUES (?, '', ?, ?, ?, ?, ?, ?, 1, 0, ?, ?) "
      'ON CONFLICT(uid) DO UPDATE SET '
      'name = excluded.name, host = excluded.host, port = excluded.port, '
      'online = excluded.online, last_time = excluded.last_time',
      variables: <Variable<Object>>[
        Variable<String>(data.uid),
        Variable<String>(data.name),
        Variable<String>(data.host),
        Variable<int>(data.port),
        Variable<String>(data.platform),
        Variable<bool>(data.isServer),
        Variable<bool>(data.online),
        Variable<int>(now),
        Variable<bool>(data.around ?? false),
      ],
      updates: <TableInfo<Table, Object?>>{device},
    );
  }

  Future<void> authDevice(String uid, bool auth) async {
    if (uid.isEmpty) {
      return;
    }
    await (update(device)..where((t) => t.uid.equals(uid))).write(
      DeviceCompanion(
        auth: Value(auth),
      ),
    );
  }

  Future<void> clipboardDevice(String uid, bool clipboard) async {
    if (uid.isEmpty) {
      return;
    }
    await (update(device)..where((t) => t.uid.equals(uid))).write(
      DeviceCompanion(
        clipboard: Value(clipboard),
      ),
    );
  }

  Future<List<String>> fetchTrustedPeerIds() async {
    final trustedDevices = await (select(device)
          ..where(
              (t) => t.auth.equals(true) & t.identityPublicKey.isNotValue('')))
        .get();
    return trustedDevices.map((item) => item.uid).toList(growable: false);
  }

  Future<String?> fetchPinnedIdentityKey(String uid) async {
    if (uid.isEmpty) {
      return null;
    }
    final stored = await (selectOnly(device)
          ..addColumns(<Expression<Object>>[device.identityPublicKey])
          ..where(device.uid.equals(uid))
          ..limit(1))
        .getSingleOrNull();
    final key = stored?.read(device.identityPublicKey) ?? '';
    return key.isEmpty ? null : key;
  }

  Future<void> pinDeviceIdentity(String uid, String publicKey) async {
    if (uid.isEmpty || publicKey.isEmpty) {
      throw ArgumentError('uid and publicKey must not be empty');
    }
    await (update(device)..where((table) => table.uid.equals(uid))).write(
      DeviceCompanion(identityPublicKey: Value<String>(publicKey)),
    );
  }

  Future<bool> hasPinnedIdentity(String uid, String publicKey) async {
    if (uid.isEmpty || publicKey.isEmpty) {
      return false;
    }
    final match = await (selectOnly(device)
          ..addColumns(<Expression<Object>>[device.id])
          ..where(device.uid.equals(uid) &
              device.identityPublicKey.equals(publicKey))
          ..limit(1))
        .getSingleOrNull();
    return match != null;
  }

  Future<DeviceData?> fetchDevice(String uid) {
    return (select(device)
          ..where((t) => t.uid.equals(uid))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<List<DeviceData>> fetchAllDevice() {
    return (select(device)
          ..orderBy([
            (t) => OrderingTerm(expression: t.lastTime, mode: OrderingMode.desc)
          ]))
        .get();
  }

  Future<List<MessageData>> fetchMessageList(String uid,
      {int beforeId = 0, int limit = 8}) {
    logger.i("device: $uid, msgid: $beforeId");
    if (beforeId > 0) {
      return (select(message)
            ..where((t) =>
                (t.sender.equals(uid) | t.receiver.equals(uid)) &
                t.id.isSmallerThanValue(beforeId))
            ..orderBy([
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc)
            ])
            ..limit(limit))
          .get();
    } else {
      return (select(message)
            ..where((t) => t.sender.equals(uid) | t.receiver.equals(uid))
            ..orderBy([
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc)
            ])
            ..limit(limit))
          .get();
    }
  }

  Future<Map<String, MessageData>> fetchLatestMessagesByPeers(
    List<String> uids,
  ) async {
    final latestMessages = <String, MessageData>{};
    final selfUid = await localUUID();
    for (final uid in uids.toSet()) {
      if (uid.isEmpty) {
        continue;
      }
      final latest = await (select(message)
            ..where(
              (t) => uid == selfUid
                  ? t.sender.equals(selfUid) & t.receiver.equals('')
                  : t.sender.equals(uid) | t.receiver.equals(uid),
            )
            ..orderBy([
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc)
            ])
            ..limit(1))
          .getSingleOrNull();
      if (latest != null) {
        latestMessages[uid] = latest;
      }
    }
    return latestMessages;
  }

  Future<void> clearDevices(List<String> uids) async {
    if (uids.isEmpty) {
      return;
    }
    final selfUid = await localUUID();
    final targetIds = List<String>.from(uids);
    if (targetIds.contains(selfUid)) {
      targetIds.remove(selfUid);
      await (delete(message)
            ..where((t) => t.sender.equals(selfUid) & t.receiver.equals("")))
          .go();
      await (delete(device)..where((t) => t.uid.equals(selfUid))).go();
    }
    if (targetIds.isNotEmpty) {
      await (delete(message)
            ..where(
                (t) => t.sender.isIn(targetIds) | t.receiver.isIn(targetIds)))
          .go();
    }
    await (delete(device)..where((t) => t.uid.isIn(targetIds))).go();
  }

  Future<void> deleteMessage(int id) async {
    await (delete(message)..where((t) => t.id.equals(id))).go();
  }

  Future<void> upsertFileTransfer(FileTransferData data) {
    return into(fileTransfer).insertOnConflictUpdate(data);
  }

  Future<void> updateFileTransfer(
    String transferId, {
    Value<FileTransferState> state = const Value.absent(),
    Value<int> committedBytes = const Value.absent(),
    Value<String> lastError = const Value.absent(),
    Value<String> finalPath = const Value.absent(),
    Value<String> tempPath = const Value.absent(),
    Value<String> checksumValue = const Value.absent(),
    Value<int> updatedAt = const Value.absent(),
  }) {
    return (update(fileTransfer)..where((t) => t.transferId.equals(transferId)))
        .write(
      FileTransferCompanion(
        state: state,
        committedBytes: committedBytes,
        lastError: lastError,
        finalPath: finalPath,
        tempPath: tempPath,
        checksumValue: checksumValue,
        updatedAt: updatedAt,
      ),
    );
  }

  Future<FileTransferData?> fetchFileTransfer(String transferId) {
    return (select(fileTransfer)
          ..where((t) => t.transferId.equals(transferId))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<Map<String, FileTransferData>> fetchFileTransfersByIds(
    Iterable<String> transferIds,
  ) async {
    final ids = transferIds.where((item) => item.isNotEmpty).toSet().toList();
    if (ids.isEmpty) {
      return const <String, FileTransferData>{};
    }
    final items = await (select(fileTransfer)
          ..where((t) => t.transferId.isIn(ids)))
        .get();
    return <String, FileTransferData>{
      for (final item in items) item.transferId: item,
    };
  }

  Future<MessageData?> fetchMessageByUuid(String uuid) {
    return (select(message)..where((t) => t.uuid.equals(uuid)))
        .getSingleOrNull();
  }

  Future<List<FileTransferData>> fetchRecoverableFileTransfers() {
    return (select(fileTransfer)
          ..where((t) => t.state.isNotIn(const <String>[
                'completed',
                'failed',
                'canceled',
              ]))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc)
          ]))
        .get();
  }

  Future<List<FileTransferData>> fetchRecoverableFileTransfersForPeer(
    String peerUid, {
    FileTransferDirection? direction,
  }) async {
    final items = await fetchRecoverableFileTransfers();
    return items.where((item) {
      if (item.peerUid != peerUid) {
        return false;
      }
      if (direction != null && item.direction != direction) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  Future<void> upsertRemoteInputLayout(RemoteInputLayoutData data) {
    return into(remoteInputLayout).insertOnConflictUpdate(data);
  }

  Future<RemoteInputLayoutData?> fetchRemoteInputLayout(String peerId) {
    return (select(remoteInputLayout)
          ..where((t) => t.peerId.equals(peerId))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<List<RemoteInputLayoutData>> fetchRemoteInputLayouts() {
    return (select(remoteInputLayout)
          ..orderBy([
            (t) => OrderingTerm(
                  expression: t.updatedAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .get();
  }

  TransferSnapshot snapshotForTransfer(FileTransferData data) {
    return TransferSnapshot(
      transferId: data.transferId,
      messageUuid: data.messageUuid,
      peerUid: data.peerUid,
      direction: data.direction,
      state: data.state,
      finalPath: data.finalPath,
      tempPath: data.tempPath,
      size: data.size,
      committedBytes: data.committedBytes,
      lastError: data.lastError,
      updatedAt: data.updatedAt,
    );
  }
}

extension RemoteInputLayoutDataAutoRoleX on RemoteInputLayoutData {
  RemoteInputAutoRole get autoRoleValue {
    for (final role in RemoteInputAutoRole.values) {
      if (role.name == autoRole) {
        return role;
      }
    }
    return RemoteInputAutoRole.source;
  }

  RemoteInputSavedLayout? get savedLayout {
    if (layoutJson.isEmpty) {
      return null;
    }
    try {
      return RemoteInputSavedLayout.fromJsonString(layoutJson);
    } catch (_) {
      return null;
    }
  }
}

LazyDatabase _openConnection() {
  // the LazyDatabase util lets us find the right location for the file async.
  return LazyDatabase(() async {
    // put the database file, called db.sqlite here, into the documents folder
    // for your app.
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File('${dbFolder.path}/db.sqlite');

    logger.i('数据库: ${dbFolder.path}/db.sqlite');

    // Also work around limitations on old Android versions
    if (Platform.isAndroid) {
      await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
    }

    // Make sqlite3 pick a more suitable location for temporary files - the
    // one from the system may be inaccessible due to sandboxing.
    final cachebase = (await getTemporaryDirectory()).path;
    // We can't access /tmp on Android, which sqlite3 would try by default.
    // Explicitly tell it about the correct temporary directory.
    sqlite3.tempDirectory = cachebase;

    return NativeDatabase.createInBackground(file);
  });
}
