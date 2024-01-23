import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';
import 'device.dart';
import 'message.dart';

part 'LocalDatabase.g.dart';

@DriftDatabase(tables: [Device, Message])
class LocalDatabase extends _$LocalDatabase {
  static final LocalDatabase _singleton = LocalDatabase._internal();

  // 私有构造函数，阻止类被直接实例化
  LocalDatabase._internal() : super(_openConnection());

  // 工厂构造函数，返回单例实例
  factory LocalDatabase() {
    return _singleton;
  }

  @override
  // TODO: implement schemaVersion
  int get schemaVersion => 1;

  Future<void> insertMessage(MessageData data) {
    return into(message).insert(MessageCompanion.insert(sender: Value(data.sender), receiver: Value(data.receiver), content: Value(data.content), message: Value(data.message), name: Value(data.name), clipboard: Value(data.clipboard), size: Value(data.size), type: Value(data.type), timestamp: Value(data.timestamp), acked: const Value(false), uuid: Value(data.uuid), path: Value(data.path), md5: Value(data.md5)));
  }

  Future<MessageData?> ackMessage(MessageData data) async {
    if (data.uuid.isEmpty) {
      return null;
    }
    (update(message)..where((t) => t.uuid.equals(data.uuid))).write(
      const MessageCompanion(
          acked: Value(true),
      ),
    );
    return await (select(message)..where((t) => t.uuid.equals(data.uuid))).getSingleOrNull();
  }

  Future<void> upsertDevice(DeviceData data) async {
    if (data.uid.isEmpty) {
      return;
    }
    var temp = await (select(device)..where((t) => t.uid.equals(data.uid))).getSingleOrNull();
    if (temp == null) {
      into(device).insert(DeviceCompanion.insert(uid: Value(data.uid), name: Value(data.name), host: data.host, port: data.port, platform: Value(data.platform), isServer: Value(data.isServer), online: Value(data.online), clipboard: const Value(true), auth: const Value(false), lastTime: Value(data.lastTime)));
      return;
    }
    (update(device)..where((t) => t.uid.equals(data.uid))).write(
      DeviceCompanion(
          host: Value(data.host),
          port: Value(data.port),
          name: Value(data.name),
          online: Value(data.online),
          lastTime: Value(DateTime.now().second)
      ),
    );
  }

  Future<void> authDevice(String uid, bool auth) async {
    if (uid.isEmpty) {
      return;
    }
    (update(device)..where((t) => t.uid.equals(uid))).write(
      DeviceCompanion(
        auth: Value(auth),
      ),
    );
  }

  Future<void> clipboardDevice(String uid, bool clipboard) async {
    if (uid.isEmpty) {
      return;
    }
    (update(device)..where((t) => t.uid.equals(uid))).write(
      DeviceCompanion(
        clipboard: Value(clipboard),
      ),
    );
  }

  Future<DeviceData?> fetchDevice(String uid) {
    return (select(device)..where((t) => t.uid.equals(uid))).getSingleOrNull();
  }

  Future<List<DeviceData>> fetchAllDevice() {
    return (select(device)
          ..orderBy(
              [(t) => OrderingTerm(expression: t.lastTime, mode: OrderingMode.desc)]))
        .get();
  }

  Future<List<MessageData>> fetchMessageList(String uid, {int beforeId=0}) {
    print("device: $uid, msgid: $beforeId");
    if (beforeId > 0) {
      return (select(message)
        ..where((t) => (t.sender.equals(uid) | t.receiver.equals(uid)) & t.id.isSmallerThanValue(beforeId))
        ..orderBy([(t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc)])
        ..limit(8)
      ).get();
    }else {
      return (select(message)
        ..where((t) => t.sender.equals(uid) | t.receiver.equals(uid))
        ..orderBy([(t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc)])
        ..limit(8)
      ).get();
    }
  }
}

LazyDatabase _openConnection() {
  // the LazyDatabase util lets us find the right location for the file async.
  return LazyDatabase(() async {
    // put the database file, called db.sqlite here, into the documents folder
    // for your app.
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File('${dbFolder.path}db.sqlite');

    print('数据库: ${dbFolder.path}db.sqlite');

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
