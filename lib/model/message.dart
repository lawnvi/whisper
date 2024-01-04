import 'package:drift/drift.dart';
import 'package:whisper/model/device.dart';

class Message extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get deviceId => integer().named("device_id").nullable().references(Device, #id)();
  TextColumn get sender => text().withDefault(const Constant(""))();
  TextColumn get receiver => text().withDefault(const Constant(""))();
  TextColumn get name => text().withDefault(const Constant(""))();
  BoolColumn get clipboard => boolean().withDefault(const Constant(false))();
  IntColumn get size => integer().withDefault(const Constant(0))();
  IntColumn get type => intEnum<MessageEnum>().withDefault(const Constant(0))();
  TextColumn get content => text().nullable().withDefault(const Constant(""))();
  TextColumn get message => text().nullable().withDefault(const Constant(""))();
  IntColumn get timestamp => integer().withDefault(const Constant(0))();
}

enum MessageEnum {
  UNKONWN,
  Auth,
  Heartbeat,
  Text,
  File
}