import 'package:drift/drift.dart';

class FavoriteText extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get sourceMessageId =>
      integer().named('source_message_id').unique()();

  TextColumn get peerUid => text().named('peer_uid')();

  TextColumn get content => text()();

  IntColumn get sourceTimestamp => integer().named('source_timestamp')();

  IntColumn get createdAt => integer().named('created_at')();
}
