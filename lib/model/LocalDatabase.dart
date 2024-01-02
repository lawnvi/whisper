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
class LocalDatabase extends _$LocalDatabase{
  LocalDatabase(): super(_openConnection());

  @override
  // TODO: implement schemaVersion
  int get schemaVersion => 1;

  Future<List<DeviceData>> fetchAllDevice() {
    return (select(device)
      ..orderBy([(t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc)]))
        .get();
  }
}

LazyDatabase _openConnection() {
  // the LazyDatabase util lets us find the right location for the file async.
  return LazyDatabase(() async {
    // put the database file, called db.sqlite here, into the documents folder
    // for your app.
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File('${dbFolder.path}db.sqlite');

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