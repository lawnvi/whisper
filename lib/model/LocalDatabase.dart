import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';
import 'package:whisper/helper/local.dart';
import '../helper/helper.dart';
import 'device.dart';
import 'file_transfer.dart';
import 'message.dart';

part 'LocalDatabase.g.dart';

@DriftDatabase(tables: [Device, Message, FileTransfer])
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
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            await m.createTable(fileTransfer);
          }
        },
      );

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
    var temp = await (select(device)..where((t) => t.uid.equals(data.uid)))
        .getSingleOrNull();
    if (temp == null) {
      await into(device).insert(DeviceCompanion.insert(
          uid: Value(data.uid),
          name: Value(data.name),
          host: data.host,
          port: data.port,
          platform: Value(data.platform),
          isServer: Value(data.isServer),
          online: Value(data.online),
          clipboard: const Value(true),
          auth: const Value(false),
          lastTime: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000)));
      return;
    }
    await (update(device)..where((t) => t.uid.equals(data.uid))).write(
      DeviceCompanion(
          host: Value(data.host),
          port: Value(data.port),
          name: Value(data.name),
          online: Value(data.online),
          lastTime: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000)),
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
    final trustedDevices =
        await (select(device)..where((t) => t.auth.equals(true))).get();
    return trustedDevices.map((item) => item.uid).toList(growable: false);
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
    for (final uid in uids.toSet()) {
      if (uid.isEmpty) {
        continue;
      }
      final latest = await (select(message)
            ..where((t) => t.sender.equals(uid) | t.receiver.equals(uid))
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
    var localhost = await LocalSetting().instance();
    final targetIds = List<String>.from(uids);
    if (targetIds.contains(localhost.uid)) {
      targetIds.remove(localhost.uid);
      await (delete(message)
            ..where(
                (t) => t.sender.equals(localhost.uid) & t.receiver.equals("")))
          .go();
      await (delete(device)..where((t) => t.uid.equals(localhost.uid))).go();
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
