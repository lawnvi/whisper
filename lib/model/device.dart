import 'package:drift/drift.dart';

class Device extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uid => text().withDefault(const Constant(""))();
  TextColumn get name => text().withDefault(const Constant(""))();
  TextColumn get host => text()();
  IntColumn get port => integer()();
  TextColumn get password => text().nullable().withDefault(const Constant(""))();
  TextColumn get platform => text().withDefault(const Constant(""))();
  BoolColumn get isServer => boolean().withDefault(const Constant(false))();
  BoolColumn get online => boolean().withDefault(const Constant(false))();
  BoolColumn get clipboard => boolean().withDefault(const Constant(false))();
  BoolColumn get auth => boolean().withDefault(const Constant(false))();
  IntColumn get lastTime => integer().withDefault(const Constant(0))();
}