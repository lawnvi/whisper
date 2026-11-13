import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/web_transfer/web_transfer_visitor.dart'
    show webVisitorPrefix;

/// How many never-trusted devices seen nearby are kept.
const int maxStoredStrangers = 64;

extension StrangerPruning on LocalDatabase {
  /// Forgets the oldest devices that were only ever seen nearby. Anyone on
  /// the network can advertise new ids without end, and each became a row
  /// here for good. A device that was ever trusted, has a pinned key, or
  /// has messages, transfers or favorites is never removed, nor is a web
  /// transfer visitor (this device let it in).
  Future<void> pruneStrangers({int keep = maxStoredStrangers}) {
    return customStatement(
      'DELETE FROM device WHERE id IN ('
      ' SELECT id FROM device'
      " WHERE auth = 0 AND identity_public_key = '' AND uid NOT LIKE ?"
      ' AND id NOT IN (SELECT device_id FROM message WHERE device_id IS NOT NULL)'
      ' AND uid NOT IN (SELECT peer_uid FROM file_transfer)'
      ' AND uid NOT IN (SELECT peer_uid FROM favorite_text)'
      ' ORDER BY last_time DESC, id DESC LIMIT -1 OFFSET ?)',
      <Object>['$webVisitorPrefix%', keep],
    );
  }
}
