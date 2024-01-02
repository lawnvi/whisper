import 'package:drift/drift.dart';

class Device extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uid => text().withDefault(const Constant(""))();
  TextColumn get name => text()();
  TextColumn get host => text().withDefault(const Constant(""))();
  IntColumn get port => integer().withDefault(const Constant(0))();
  TextColumn get platform => text().withDefault(const Constant(""))();
  BoolColumn get isServer => boolean().withDefault(const Constant(false))();
  BoolColumn get online => boolean().nullable().withDefault(const Constant(false))();
  IntColumn get lastTime => integer().withDefault(const Constant(0))();
}