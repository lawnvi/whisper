import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/socket/file_transfer_v3.dart';

import '../helper/helper.dart';
import 'device.dart';
import 'favorite_text.dart';
import 'file_transfer.dart';
import 'message.dart';

export 'device.dart' show DeviceData;

part 'LocalDatabase.g.dart';

enum DeviceIdentityPinResult {
  pinned,
  alreadyPinned,
  replaced,
  conflict,
  missingDevice,
}

extension DeviceIdentityPinResultX on DeviceIdentityPinResult {
  bool get isSuccess =>
      this == DeviceIdentityPinResult.pinned ||
      this == DeviceIdentityPinResult.alreadyPinned ||
      this == DeviceIdentityPinResult.replaced;
}

const int maxNonterminalTransfersPerPeer = 32;
const int maxNonterminalTransfersGlobal = 128;

enum FileTransferAdmission {
  admitted,
  existing,
  peerLimit,
  globalLimit,
  missing,
}

final class FileTransferAdmissionResult {
  const FileTransferAdmissionResult({
    required this.decision,
    this.message,
    this.transfer,
  });

  final FileTransferAdmission decision;
  final MessageData? message;
  final FileTransferData? transfer;
}

final class TextMessageSearchResult {
  const TextMessageSearchResult({
    required this.message,
    required this.isFavorite,
  });

  final MessageData message;
  final bool isFavorite;

  TextMessageSearchResult copyWith({bool? isFavorite}) {
    return TextMessageSearchResult(
      message: message,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }
}

@DriftDatabase(
  tables: [Device, Message, FileTransfer, RemoteInputLayout, FavoriteText],
)
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
  int get schemaVersion => 10;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
      await _ensureMessageUuidIndex();
      await _ensureFileTransferMessageRowIndexes();
      await _ensureMessageSearchIndex(rebuild: true);
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
      if (from < 7) {
        await _ensureMessageUuidIndex();
      }
      if (from < 8) {
        await _migrateFileTransferHardeningSchema(m);
      }
      if (from < 9) {
        await _sanitizeFileTransferFailureReasons();
      }
      if (from < 10) {
        await m.createTable(favoriteText);
        await _ensureMessageSearchIndex(rebuild: true);
      }
    },
    beforeOpen: (_) async {
      await _repairRemoteInputLayoutColumns();
      await _ensureMessageUuidIndex();
      await _ensureFileTransferMessageRowIndexes();
      await _ensureMessageSearchIndex();
    },
  );

  Future<void> _ensureMessageSearchIndex({bool rebuild = false}) async {
    final messageColumns = await customSelect(
      'PRAGMA table_info(message)',
    ).get();
    if (!messageColumns.any((row) => row.data['name'] == 'content')) {
      return;
    }
    final existing = await customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'message_fts'",
    ).getSingleOrNull();
    await customStatement('''
      CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(
        content,
        content = 'message',
        content_rowid = 'id',
        tokenize = 'trigram'
      )
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS message_fts_after_insert
      AFTER INSERT ON message
      BEGIN
        INSERT INTO message_fts(rowid, content)
        VALUES (new.id, new.content);
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS message_fts_after_delete
      AFTER DELETE ON message
      BEGIN
        INSERT INTO message_fts(message_fts, rowid, content)
        VALUES ('delete', old.id, old.content);
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS message_fts_after_update
      AFTER UPDATE OF content ON message
      BEGIN
        INSERT INTO message_fts(message_fts, rowid, content)
        VALUES ('delete', old.id, old.content);
        INSERT INTO message_fts(rowid, content)
        VALUES (new.id, new.content);
      END
    ''');
    if (rebuild || existing == null) {
      await customStatement(
        "INSERT INTO message_fts(message_fts) VALUES ('rebuild')",
      );
    }
  }

  Future<void> _sanitizeFileTransferFailureReasons() async {
    final columns = await customSelect(
      'PRAGMA table_info(file_transfer)',
    ).get();
    if (!columns.any((row) => row.data['name'] == 'last_error')) {
      return;
    }
    final allowed = fileTransferFailureWireCodes.toList(growable: false)
      ..sort();
    final placeholders = List<String>.filled(allowed.length, '?').join(', ');
    await customUpdate(
      'UPDATE file_transfer SET last_error = ? '
      'WHERE last_error NOT IN ($placeholders)',
      variables: <Variable<Object>>[
        Variable<String>(FileTransferFailureReason.remoteFailure.wireCode),
        ...allowed.map(Variable<String>.new),
      ],
      updates: <TableInfo<Table, Object?>>{fileTransfer},
    );
  }

  Future<void> _migrateFileTransferHardeningSchema(Migrator migrator) async {
    final columns = await customSelect(
      'PRAGMA table_info(file_transfer)',
    ).get();
    if (columns.isEmpty) {
      await migrator.createTable(fileTransfer);
      await _ensureFileTransferMessageRowIndexes();
      return;
    }
    final names = columns.map((row) => row.read<String>('name')).toSet();
    if (!names.contains('message_row_id')) {
      await migrator.addColumn(fileTransfer, fileTransfer.messageRowId);
    }
    if (!names.contains('resume_proof_reset_count')) {
      await migrator.addColumn(
        fileTransfer,
        fileTransfer.resumeProofResetCount,
      );
    }
    await _backfillUncontestedFileTransferMessageRows();
    await customStatement('''
      UPDATE file_transfer
      SET state = '${FileTransferState.failed.name}',
          last_error = 'message_association_unresolved'
      WHERE message_row_id = 0
        AND state NOT IN (
          '${FileTransferState.completed.name}',
          '${FileTransferState.failed.name}',
          '${FileTransferState.canceled.name}'
        )
    ''');
    await _ensureFileTransferMessageRowIndexes();
  }

  Future<void> _backfillUncontestedFileTransferMessageRows() async {
    final rows = await customSelect('''
      SELECT file_transfer.transfer_id AS transfer_id,
             message.id AS message_id
      FROM file_transfer
      JOIN message
        ON message.uuid = file_transfer.message_uuid
       AND message.type = ${MessageEnum.File.index}
       AND message.size = file_transfer.size
       AND (
         (file_transfer.direction = '${FileTransferDirection.incoming.name}'
           AND message.sender = file_transfer.peer_uid)
         OR
         (file_transfer.direction = '${FileTransferDirection.outgoing.name}'
           AND message.receiver = file_transfer.peer_uid)
       )
      WHERE file_transfer.message_row_id = 0
        AND file_transfer.transfer_id = file_transfer.message_uuid
    ''').get();
    final candidatesByTransfer = <String, Set<int>>{};
    final transfersByCandidate = <int, Set<String>>{};
    for (final row in rows) {
      final transferId = row.read<String>('transfer_id');
      final messageId = row.read<int>('message_id');
      candidatesByTransfer
          .putIfAbsent(transferId, () => <int>{})
          .add(messageId);
      transfersByCandidate
          .putIfAbsent(messageId, () => <String>{})
          .add(transferId);
    }
    for (final entry in candidatesByTransfer.entries) {
      if (entry.value.length != 1) continue;
      final messageId = entry.value.single;
      if (transfersByCandidate[messageId]?.length != 1) continue;
      await customUpdate(
        'UPDATE file_transfer SET message_row_id = ? '
        'WHERE transfer_id = ? AND message_row_id = 0',
        variables: <Variable<Object>>[
          Variable<int>(messageId),
          Variable<String>(entry.key),
        ],
        updates: <TableInfo<Table, Object?>>{fileTransfer},
      );
    }
  }

  Future<void> _ensureFileTransferMessageRowIndexes() async {
    final columns = await customSelect(
      'PRAGMA table_info(file_transfer)',
    ).get();
    if (!columns.any((row) => row.data['name'] == 'message_row_id')) {
      return;
    }
    await customStatement(
      'CREATE INDEX IF NOT EXISTS file_transfer_message_row_lookup '
      'ON file_transfer(message_row_id)',
    );
    await customStatement('''
      UPDATE file_transfer
      SET state = '${FileTransferState.failed.name}',
          last_error = 'message_association_conflict'
      WHERE message_row_id > 0
        AND state NOT IN (
          '${FileTransferState.completed.name}',
          '${FileTransferState.failed.name}',
          '${FileTransferState.canceled.name}'
        )
        AND message_row_id IN (
          SELECT message_row_id
          FROM file_transfer
          WHERE message_row_id > 0
          GROUP BY message_row_id
          HAVING COUNT(*) > 1
        )
    ''');
    await customStatement('''
      UPDATE file_transfer
      SET message_row_id = 0
      WHERE message_row_id > 0
        AND message_row_id IN (
          SELECT message_row_id
          FROM file_transfer
          WHERE message_row_id > 0
          GROUP BY message_row_id
          HAVING COUNT(*) > 1
        )
    ''');
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS file_transfer_message_row_unique '
      'ON file_transfer(message_row_id) WHERE message_row_id > 0',
    );
  }

  Future<void> _ensureMessageUuidIndex() async {
    final columns = await customSelect('PRAGMA table_info(message)').get();
    final hasUuid = columns.any((row) => row.data['name'] == 'uuid');
    if (!hasUuid) {
      return;
    }
    await customStatement(
      'CREATE INDEX IF NOT EXISTS message_uuid_lookup ON message(uuid)',
    );
  }

  Future<void> _migrateDeviceIdentitySchema(Migrator migrator) async {
    final existingColumns = await customSelect(
      'PRAGMA table_info(device)',
    ).get();
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
    await customUpdate(
      "UPDATE message SET device_id = NULL WHERE device_id IN "
      "(SELECT id FROM device WHERE uid = '')",
      updates: <TableInfo<Table, Object?>>{message},
    );
    await customStatement("DELETE FROM device WHERE uid = ''");

    final duplicateUids = await customSelect(
      'SELECT uid FROM device GROUP BY uid HAVING COUNT(*) > 1',
    ).get();
    for (final duplicate in duplicateUids) {
      final uid = duplicate.read<String>('uid');
      final rows = await customSelect(
        'SELECT id, auth, clipboard FROM device WHERE uid = ? '
        'ORDER BY last_time DESC, id DESC',
        variables: <Variable<Object>>[Variable<String>(uid)],
      ).get();
      final keeperId = rows.first.read<int>('id');
      final mergedAuth = rows.any((row) => row.read<int>('auth') == 1);
      final mergedClipboard = rows.any(
        (row) => row.read<int>('clipboard') == 1,
      );
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
        'UPDATE message SET device_id = ? WHERE device_id IN '
        '(SELECT id FROM device WHERE uid = ? AND id <> ?)',
        variables: <Variable<Object>>[
          Variable<int>(keeperId),
          Variable<String>(uid),
          Variable<int>(keeperId),
        ],
        updates: <TableInfo<Table, Object?>>{message},
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
    final columns = await customSelect(
      'PRAGMA table_info(remote_input_layout)',
    ).get();
    if (columns.isEmpty) {
      return;
    }
    final hasAutoRole = columns.any((row) => row.data['name'] == 'auto_role');
    final hasLayoutVersion = columns.any(
      (row) => row.data['name'] == 'layout_version',
    );
    final hasLayoutJson = columns.any(
      (row) => row.data['name'] == 'layout_json',
    );
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
      variables: [const Variable<int>(1)],
      updates: {remoteInputLayout},
    );
    await customUpdate(
      'UPDATE remote_input_layout SET layout_json = ? '
      'WHERE layout_json IS NULL',
      variables: [const Variable<String>('')],
      updates: {remoteInputLayout},
    );
  }

  MessageCompanion _messageCompanion(MessageData data, {required bool acked}) {
    return MessageCompanion.insert(
      sender: Value(data.sender),
      receiver: Value(data.receiver),
      content: Value(data.content),
      message: Value(data.message),
      name: Value(data.name),
      clipboard: Value(data.clipboard),
      size: Value(data.size),
      type: Value(data.type),
      timestamp: Value(data.timestamp),
      acked: Value(acked),
      uuid: Value(data.uuid),
      path: Value(data.path),
      md5: Value(data.md5),
      fileTimestamp: Value(data.fileTimestamp),
    );
  }

  Future<void> insertMessage(MessageData data) async {
    await insertMessageReturning(data, acked: false);
  }

  Future<MessageData> insertMessageReturning(
    MessageData data, {
    bool? acked,
  }) async {
    final persistedAcked = acked ?? data.acked;
    final id = await into(
      message,
    ).insert(_messageCompanion(data, acked: persistedAcked));
    return data.copyWith(id: id, acked: persistedAcked);
  }

  Future<MessageData?> ackMessage(MessageData data) async {
    if (data.uuid.isEmpty) {
      return null;
    }
    await (update(message)..where((t) => t.uuid.equals(data.uuid))).write(
      const MessageCompanion(acked: Value(true)),
    );
    return (select(message)
          ..where((t) => t.uuid.equals(data.uuid))
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(1))
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

  Future<void> setDeviceDiscoveryPresence(String uid, bool around) async {
    if (uid.isEmpty) {
      return;
    }
    await (update(device)..where((item) => item.uid.equals(uid))).write(
      DeviceCompanion(around: Value(around)),
    );
  }

  Future<void> clearDeviceDiscoveryPresence() async {
    await update(device).write(const DeviceCompanion(around: Value(false)));
  }

  Future<void> authDevice(String uid, bool auth) async {
    if (uid.isEmpty) {
      return;
    }
    await (update(device)..where((t) => t.uid.equals(uid))).write(
      DeviceCompanion(auth: Value(auth)),
    );
  }

  Future<bool> authDeviceIfPinned(String uid, String publicKey) async {
    if (uid.isEmpty || publicKey.isEmpty) {
      return false;
    }
    final updated = await customUpdate(
      'UPDATE device SET auth = 1 '
      'WHERE uid = ? AND identity_public_key = ?',
      variables: <Variable<Object>>[
        Variable<String>(uid),
        Variable<String>(publicKey),
      ],
      updates: <TableInfo<Table, Object?>>{device},
    );
    return updated == 1;
  }

  /// Commits the discovered profile, identity CAS, and trust bit together.
  /// [requireCurrent] is deliberately called after every async boundary so a
  /// socket close aborts and rolls back the transaction instead of trusting a
  /// key from an expired handshake.
  Future<DeviceData> commitAuthenticatedDevice({
    required DeviceData candidate,
    required String publicKey,
    required bool replaceIdentity,
    required String expectedPublicKey,
    required void Function() requireCurrent,
  }) {
    if (candidate.uid.isEmpty || publicKey.isEmpty) {
      throw ArgumentError('candidate.uid and publicKey must not be empty');
    }
    if (replaceIdentity && expectedPublicKey.isEmpty) {
      throw ArgumentError(
        'expectedPublicKey must not be empty for replacement',
      );
    }
    return transaction(() async {
      requireCurrent();
      final existingDevice = await fetchDevice(candidate.uid);
      requireCurrent();
      final identityChanged =
          existingDevice != null &&
          existingDevice.identityPublicKey != publicKey;
      await upsertDevice(candidate);
      requireCurrent();

      final pinResult = replaceIdentity
          ? await replaceDeviceIdentity(
              candidate.uid,
              expectedPublicKey: expectedPublicKey,
              newPublicKey: publicKey,
            )
          : await pinDeviceIdentity(candidate.uid, publicKey);
      requireCurrent();
      if (!pinResult.isSuccess) {
        throw StateError('identity_pin_conflict');
      }

      if (identityChanged) {
        await _cancelOutgoingTransfersForPeerInTransaction(
          candidate.uid,
          reason: 'identity_replaced',
        );
        requireCurrent();
      }

      final authenticated = await authDeviceIfPinned(candidate.uid, publicKey);
      requireCurrent();
      if (!authenticated) {
        throw StateError('identity_pin_conflict');
      }

      final stored = await fetchDevice(candidate.uid);
      requireCurrent();
      if (stored == null ||
          !stored.auth ||
          stored.identityPublicKey != publicKey) {
        throw StateError('identity_pin_conflict');
      }
      return stored;
    });
  }

  /// Reverts the DB side of an authentication that lost its final connection
  /// commit gate. The public-key comparison prevents stale attempts from
  /// overwriting a newer identity decision.
  Future<bool> rollbackAuthenticatedDevice({
    required String peerId,
    required String attemptedPublicKey,
    required DeviceData? previous,
  }) {
    if (peerId.isEmpty || attemptedPublicKey.isEmpty) {
      return Future<bool>.value(false);
    }
    return transaction(() async {
      final current = await fetchDevice(peerId);
      if (current == null || current.identityPublicKey != attemptedPublicKey) {
        return false;
      }
      if (previous == null) {
        final removed =
            await (delete(device)..where(
                  (row) =>
                      row.uid.equals(peerId) &
                      row.identityPublicKey.equals(attemptedPublicKey),
                ))
                .go();
        return removed == 1;
      }
      if (previous.uid != peerId) {
        return false;
      }
      final restored =
          await (update(device)..where((row) => row.uid.equals(peerId))).write(
            previous.toCompanion(false),
          );
      return restored == 1;
    });
  }

  Future<void> clipboardDevice(String uid, bool clipboard) async {
    if (uid.isEmpty) {
      return;
    }
    await (update(device)..where((t) => t.uid.equals(uid))).write(
      DeviceCompanion(clipboard: Value(clipboard)),
    );
  }

  Future<List<String>> fetchTrustedPeerIds() async {
    final trustedDevices =
        await (select(device)..where(
              (t) => t.auth.equals(true) & t.identityPublicKey.isNotValue(''),
            ))
            .get();
    return trustedDevices.map((item) => item.uid).toList(growable: false);
  }

  Future<String?> fetchPinnedIdentityKey(String uid) async {
    if (uid.isEmpty) {
      return null;
    }
    final stored =
        await (selectOnly(device)
              ..addColumns(<Expression<Object>>[device.identityPublicKey])
              ..where(device.uid.equals(uid))
              ..limit(1))
            .getSingleOrNull();
    final key = stored?.read(device.identityPublicKey) ?? '';
    return key.isEmpty ? null : key;
  }

  Future<DeviceIdentityPinResult> pinDeviceIdentity(
    String uid,
    String publicKey,
  ) async {
    if (uid.isEmpty || publicKey.isEmpty) {
      throw ArgumentError('uid and publicKey must not be empty');
    }
    final updated = await customUpdate(
      'UPDATE device SET identity_public_key = ? '
      "WHERE uid = ? AND identity_public_key = ''",
      variables: <Variable<Object>>[
        Variable<String>(publicKey),
        Variable<String>(uid),
      ],
      updates: <TableInfo<Table, Object?>>{device},
    );
    if (updated == 1) {
      return DeviceIdentityPinResult.pinned;
    }
    final current = await fetchPinnedIdentityKey(uid);
    if (current == null) {
      return await fetchDevice(uid) == null
          ? DeviceIdentityPinResult.missingDevice
          : DeviceIdentityPinResult.conflict;
    }
    return current == publicKey
        ? DeviceIdentityPinResult.alreadyPinned
        : DeviceIdentityPinResult.conflict;
  }

  Future<DeviceIdentityPinResult> replaceDeviceIdentity(
    String uid, {
    required String expectedPublicKey,
    required String newPublicKey,
  }) async {
    if (uid.isEmpty || expectedPublicKey.isEmpty || newPublicKey.isEmpty) {
      throw ArgumentError(
        'uid, expectedPublicKey, and newPublicKey must not be empty',
      );
    }
    final updated = await customUpdate(
      'UPDATE device SET identity_public_key = ? '
      'WHERE uid = ? AND identity_public_key = ?',
      variables: <Variable<Object>>[
        Variable<String>(newPublicKey),
        Variable<String>(uid),
        Variable<String>(expectedPublicKey),
      ],
      updates: <TableInfo<Table, Object?>>{device},
    );
    if (updated == 1) {
      return expectedPublicKey == newPublicKey
          ? DeviceIdentityPinResult.alreadyPinned
          : DeviceIdentityPinResult.replaced;
    }
    final current = await fetchPinnedIdentityKey(uid);
    if (current == null) {
      return await fetchDevice(uid) == null
          ? DeviceIdentityPinResult.missingDevice
          : DeviceIdentityPinResult.conflict;
    }
    return current == newPublicKey
        ? DeviceIdentityPinResult.alreadyPinned
        : DeviceIdentityPinResult.conflict;
  }

  Future<bool> hasPinnedIdentity(String uid, String publicKey) async {
    if (uid.isEmpty || publicKey.isEmpty) {
      return false;
    }
    final match =
        await (selectOnly(device)
              ..addColumns(<Expression<Object>>[device.id])
              ..where(
                device.uid.equals(uid) &
                    device.identityPublicKey.equals(publicKey),
              )
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
    return (select(device)..orderBy([
          (t) => OrderingTerm(expression: t.lastTime, mode: OrderingMode.desc),
        ]))
        .get();
  }

  Future<List<MessageData>> fetchMessageList(
    String uid, {
    int beforeId = 0,
    int limit = 8,
  }) {
    if (beforeId > 0) {
      return (select(message)
            ..where(
              (t) =>
                  (t.sender.equals(uid) | t.receiver.equals(uid)) &
                  t.clipboard.equals(false) &
                  t.id.isSmallerThanValue(beforeId),
            )
            ..orderBy([
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
            ])
            ..limit(limit))
          .get();
    } else {
      return (select(message)
            ..where(
              (t) =>
                  (t.sender.equals(uid) | t.receiver.equals(uid)) &
                  t.clipboard.equals(false),
            )
            ..orderBy([
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
            ])
            ..limit(limit))
          .get();
    }
  }

  Future<List<TextMessageSearchResult>> searchTextMessagesForPeer(
    String peerUid, {
    String query = '',
    int beforeId = 0,
    int limit = 100,
  }) async {
    if (peerUid.trim().isEmpty || limit <= 0) {
      return const <TextMessageSearchResult>[];
    }
    final normalizedQuery = query.trim();
    final effectiveLimit = limit > 500 ? 500 : limit;
    final useFullTextIndex = normalizedQuery.runes.length >= 3;
    final fromClause = useFullTextIndex
        ? 'FROM message_fts '
              'JOIN message AS m ON m.id = message_fts.rowid '
        : 'FROM message AS m ';
    final filters = <String>[
      'm.type = ?',
      '(m.sender = ? OR m.receiver = ?)',
      'm.clipboard = 0',
      "COALESCE(m.content, '') <> ''",
    ];
    final variables = <Variable<Object>>[
      Variable<int>(MessageEnum.Text.index),
      Variable<String>(peerUid),
      Variable<String>(peerUid),
    ];
    if (beforeId > 0) {
      filters.add('m.id < ?');
      variables.add(Variable<int>(beforeId));
    }
    if (normalizedQuery.isNotEmpty) {
      if (useFullTextIndex) {
        filters.add('message_fts MATCH ?');
        final literalQuery = '"${normalizedQuery.replaceAll('"', '""')}"';
        variables.add(Variable<String>(literalQuery));
      } else {
        filters.add("instr(lower(COALESCE(m.content, '')), lower(?)) > 0");
        variables.add(Variable<String>(normalizedQuery));
      }
    }
    variables.add(Variable<int>(effectiveLimit));

    final rows = await customSelect(
      'SELECT m.*, '
      'CASE WHEN favorite_text.id IS NULL THEN 0 ELSE 1 END AS is_favorite '
      '$fromClause'
      'LEFT JOIN favorite_text '
      'ON favorite_text.source_message_id = m.id '
      'WHERE ${filters.join(' AND ')} '
      'ORDER BY m.id DESC LIMIT ?',
      variables: variables,
      readsFrom: <ResultSetImplementation<Table, Object?>>{
        message,
        favoriteText,
      },
    ).get();
    return rows
        .map(
          (row) => TextMessageSearchResult(
            message: message.map(row.data),
            isFavorite: row.read<int>('is_favorite') == 1,
          ),
        )
        .toList(growable: false);
  }

  Future<List<FavoriteTextData>> fetchFavoriteTextsForPeer(
    String peerUid, {
    int limit = 100,
  }) {
    if (peerUid.trim().isEmpty || limit <= 0) {
      return Future<List<FavoriteTextData>>.value(const <FavoriteTextData>[]);
    }
    final effectiveLimit = limit > 500 ? 500 : limit;
    return (select(favoriteText)
          ..where((row) => row.peerUid.equals(peerUid))
          ..orderBy([
            (row) => OrderingTerm.desc(row.createdAt),
            (row) => OrderingTerm.desc(row.id),
          ])
          ..limit(effectiveLimit))
        .get();
  }

  Future<void> favoriteTextMessage(
    MessageData source, {
    required String peerUid,
  }) async {
    if (peerUid.trim().isEmpty || source.id <= 0) {
      throw ArgumentError(
        'peerUid and a persisted source message are required',
      );
    }
    final stored = await fetchMessageById(source.id);
    if (stored == null) {
      throw StateError('source_message_missing');
    }
    if (stored.type != MessageEnum.Text ||
        stored.content == null ||
        stored.content!.trim().isEmpty) {
      throw ArgumentError('only non-empty text messages can be favorited');
    }
    if (stored.sender != peerUid && stored.receiver != peerUid) {
      throw ArgumentError('source message does not belong to peerUid');
    }
    final favorite = FavoriteTextCompanion.insert(
      sourceMessageId: stored.id,
      peerUid: peerUid,
      content: stored.content!,
      sourceTimestamp: stored.timestamp,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await into(favoriteText).insert(
      favorite,
      onConflict: DoUpdate(
        (_) => favorite,
        target: <Column<Object>>[favoriteText.sourceMessageId],
      ),
    );
  }

  Future<void> unfavoriteTextMessage(int sourceMessageId) async {
    if (sourceMessageId <= 0) {
      return;
    }
    await (delete(
      favoriteText,
    )..where((row) => row.sourceMessageId.equals(sourceMessageId))).go();
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
      final latest =
          await (select(message)
                ..where(
                  (t) => uid == selfUid
                      ? t.sender.equals(selfUid) &
                            t.receiver.equals('') &
                            t.clipboard.equals(false)
                      : (t.sender.equals(uid) | t.receiver.equals(uid)) &
                            t.clipboard.equals(false),
                )
                ..orderBy([
                  (t) =>
                      OrderingTerm(expression: t.id, mode: OrderingMode.desc),
                ])
                ..limit(1))
              .getSingleOrNull();
      if (latest != null) {
        latestMessages[uid] = latest;
      }
    }
    return latestMessages;
  }

  Future<void> clearDevices(List<String> uids, {String? localPeerId}) async {
    if (uids.isEmpty) {
      return;
    }
    final selfUid = localPeerId ?? await localUUID();
    final targetIds = List<String>.from(uids);
    await transaction(() async {
      final removedMessageIds = <int>{};
      if (targetIds.remove(selfUid)) {
        final selfMessages =
            await (select(message)..where(
                  (item) =>
                      item.sender.equals(selfUid) & item.receiver.equals(''),
                ))
                .get();
        removedMessageIds.addAll(selfMessages.map((item) => item.id));
        await (delete(message)..where(
              (item) => item.sender.equals(selfUid) & item.receiver.equals(''),
            ))
            .go();
        await (delete(device)..where((item) => item.uid.equals(selfUid))).go();
      }
      if (targetIds.isNotEmpty) {
        final peerMessages =
            await (select(message)..where(
                  (item) =>
                      item.sender.isIn(targetIds) |
                      item.receiver.isIn(targetIds),
                ))
                .get();
        removedMessageIds.addAll(peerMessages.map((item) => item.id));
      }
      await _detachFileTransfersForMessages(
        removedMessageIds,
        reason: 'device_cleared',
      );
      if (targetIds.isNotEmpty) {
        await (delete(message)..where(
              (item) =>
                  item.sender.isIn(targetIds) | item.receiver.isIn(targetIds),
            ))
            .go();
      }
      await (delete(device)..where((item) => item.uid.isIn(targetIds))).go();
    });
  }

  Future<void> deleteMessage(int id) async {
    await deleteMessages(<int>{id});
  }

  Future<void> deleteMessages(Set<int> ids) async {
    if (ids.isEmpty) {
      return;
    }
    await transaction(() async {
      await _detachFileTransfersForMessages(ids, reason: 'message_deleted');
      await (delete(message)..where((item) => item.id.isIn(ids))).go();
    });
  }

  Future<int> discardRecoverableOutgoingTransfersWithPathPrefix(
    String pathPrefix,
  ) {
    if (pathPrefix.isEmpty) {
      throw ArgumentError.value(pathPrefix, 'pathPrefix', 'must not be empty');
    }
    final escapedPrefix = pathPrefix
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    return transaction(() async {
      final transfers =
          await (select(fileTransfer)..where(
                (item) =>
                    item.direction.equalsValue(FileTransferDirection.outgoing) &
                    item.state.isNotIn(const <String>[
                      'completed',
                      'failed',
                      'canceled',
                    ]) &
                    item.finalPath.like('$escapedPrefix%', escapeChar: r'\'),
              ))
              .get();
      if (transfers.isEmpty) {
        return 0;
      }
      final transferIds = transfers
          .map((item) => item.transferId)
          .toList(growable: false);
      final messageIds = transfers
          .map((item) => item.messageRowId)
          .where((id) => id > 0)
          .toSet()
          .toList(growable: false);
      final now = DateTime.now().millisecondsSinceEpoch;
      final affected =
          await (update(fileTransfer)..where(
                (item) =>
                    item.transferId.isIn(transferIds) &
                    item.state.isNotIn(const <String>[
                      'completed',
                      'failed',
                      'canceled',
                    ]),
              ))
              .write(
                FileTransferCompanion(
                  messageRowId: const Value(0),
                  state: const Value(FileTransferState.canceled),
                  lastError: const Value(''),
                  updatedAt: Value(now),
                ),
              );
      if (messageIds.isNotEmpty) {
        await (delete(message)..where((item) => item.id.isIn(messageIds))).go();
      }
      return affected;
    });
  }

  Future<void> _detachFileTransfersForMessages(
    Set<int> messageIds, {
    required String reason,
  }) async {
    if (messageIds.isEmpty) return;
    final ids = messageIds.toList(growable: false);
    final now = DateTime.now().millisecondsSinceEpoch;
    await (update(fileTransfer)..where(
          (item) =>
              item.messageRowId.isIn(ids) &
              item.state.isNotIn(const <String>[
                'completed',
                'failed',
                'canceled',
              ]),
        ))
        .write(
          FileTransferCompanion(
            messageRowId: const Value(0),
            state: const Value(FileTransferState.canceled),
            lastError: Value(reason),
            updatedAt: Value(now),
          ),
        );
    await (update(
      fileTransfer,
    )..where((item) => item.messageRowId.isIn(ids))).write(
      FileTransferCompanion(
        messageRowId: const Value(0),
        updatedAt: Value(now),
      ),
    );
  }

  Future<void> upsertFileTransfer(FileTransferData data) {
    return into(fileTransfer).insertOnConflictUpdate(data);
  }

  Future<FileTransferAdmissionResult> admitFileTransfer({
    required MessageData message,
    required FileTransferData transfer,
    bool acked = false,
    String? expectedPublicKeyHash,
    int perPeerLimit = maxNonterminalTransfersPerPeer,
    int globalLimit = maxNonterminalTransfersGlobal,
  }) {
    return transaction(() async {
      if (!await _matchesStoredTrustedIdentityHash(
        transfer.peerUid,
        expectedPublicKeyHash,
      )) {
        return const FileTransferAdmissionResult(
          decision: FileTransferAdmission.missing,
        );
      }
      if (!_isExactFileTransferMessageAssociation(transfer, message)) {
        return const FileTransferAdmissionResult(
          decision: FileTransferAdmission.missing,
        );
      }
      final existingTransfer = await fetchFileTransfer(transfer.transferId);
      if (existingTransfer != null) {
        final associated = await fetchAssociatedFileTransferMessage(
          existingTransfer,
        );
        return FileTransferAdmissionResult(
          decision: associated == null
              ? FileTransferAdmission.missing
              : FileTransferAdmission.existing,
          message: associated,
          transfer: existingTransfer,
        );
      }
      if (await _nonterminalTransferCount(peerUid: transfer.peerUid) >=
          perPeerLimit) {
        return const FileTransferAdmissionResult(
          decision: FileTransferAdmission.peerLimit,
        );
      }
      if (await _nonterminalTransferCount() >= globalLimit) {
        return const FileTransferAdmissionResult(
          decision: FileTransferAdmission.globalLimit,
        );
      }
      if ((await fetchMessagesByUuid(message.uuid)).isNotEmpty) {
        throw StateError('message UUID already exists without a transfer');
      }
      final persistedMessage = await insertMessageReturning(
        message,
        acked: acked,
      );
      final persistedTransfer = transfer.copyWith(
        messageRowId: persistedMessage.id,
      );
      await upsertFileTransfer(persistedTransfer);
      return FileTransferAdmissionResult(
        decision: FileTransferAdmission.admitted,
        message: persistedMessage,
        transfer: persistedTransfer,
      );
    });
  }

  Future<FileTransferAdmissionResult> admitTransferForExistingMessage({
    required MessageData message,
    required FileTransferData transfer,
    int perPeerLimit = maxNonterminalTransfersPerPeer,
    int globalLimit = maxNonterminalTransfersGlobal,
  }) {
    return transaction(() async {
      final existingTransfer = await fetchFileTransfer(transfer.transferId);
      final existingMessage = await fetchMessageById(message.id);
      if (existingMessage == null ||
          !_isExactFileTransferMessageAssociation(transfer, existingMessage)) {
        return const FileTransferAdmissionResult(
          decision: FileTransferAdmission.missing,
        );
      }
      if (existingTransfer != null) {
        final associated = await fetchAssociatedFileTransferMessage(
          existingTransfer,
        );
        return FileTransferAdmissionResult(
          decision: associated == null
              ? FileTransferAdmission.missing
              : FileTransferAdmission.existing,
          message: associated,
          transfer: existingTransfer,
        );
      }
      final associatedTransfer = transfer.copyWith(
        messageRowId: existingMessage.id,
      );
      if (await _nonterminalTransferCount(peerUid: transfer.peerUid) >=
          perPeerLimit) {
        final failed = associatedTransfer.copyWith(
          state: FileTransferState.failed,
          lastError: 'queue_full',
        );
        await upsertFileTransfer(failed);
        return FileTransferAdmissionResult(
          decision: FileTransferAdmission.peerLimit,
          message: existingMessage,
          transfer: failed,
        );
      }
      if (await _nonterminalTransferCount() >= globalLimit) {
        final failed = associatedTransfer.copyWith(
          state: FileTransferState.failed,
          lastError: 'queue_full',
        );
        await upsertFileTransfer(failed);
        return FileTransferAdmissionResult(
          decision: FileTransferAdmission.globalLimit,
          message: existingMessage,
          transfer: failed,
        );
      }
      await upsertFileTransfer(associatedTransfer);
      return FileTransferAdmissionResult(
        decision: FileTransferAdmission.admitted,
        message: existingMessage,
        transfer: associatedTransfer,
      );
    });
  }

  Future<FileTransferAdmission> reacquireFileTransferCapacity(
    String transferId, {
    required FileTransferState nextState,
    int perPeerLimit = maxNonterminalTransfersPerPeer,
    int globalLimit = maxNonterminalTransfersGlobal,
  }) {
    return transaction(() async {
      final transfer = await fetchFileTransfer(transferId);
      if (transfer == null) {
        return FileTransferAdmission.missing;
      }
      if (await fetchAssociatedFileTransferMessage(transfer) == null) {
        return FileTransferAdmission.missing;
      }
      if (!isTerminalFileTransferState(transfer.state)) {
        return FileTransferAdmission.existing;
      }
      if (transfer.state != FileTransferState.failed) {
        return FileTransferAdmission.missing;
      }
      if (await _nonterminalTransferCount(peerUid: transfer.peerUid) >=
          perPeerLimit) {
        return FileTransferAdmission.peerLimit;
      }
      if (await _nonterminalTransferCount() >= globalLimit) {
        return FileTransferAdmission.globalLimit;
      }
      final affected =
          await (update(fileTransfer)..where(
                (item) =>
                    item.transferId.equals(transferId) &
                    item.messageRowId.equals(transfer.messageRowId) &
                    item.state.equalsValue(FileTransferState.failed),
              ))
              .write(
                FileTransferCompanion(
                  state: Value(nextState),
                  lastError: const Value(''),
                  updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
                ),
              );
      return affected == 1
          ? FileTransferAdmission.admitted
          : FileTransferAdmission.missing;
    });
  }

  Future<FileTransferAdmissionResult> reacquireInvalidatedOutgoingFileTransfer(
    String transferId, {
    required FileTransferState nextState,
    required String expectedPublicKeyHash,
    MessageData? replacementMessage,
    int perPeerLimit = maxNonterminalTransfersPerPeer,
    int globalLimit = maxNonterminalTransfersGlobal,
  }) {
    return transaction(() async {
      final transfer = await fetchFileTransfer(transferId);
      if (transfer == null ||
          transfer.direction != FileTransferDirection.outgoing ||
          transfer.state != FileTransferState.canceled ||
          !isRetryableOutgoingInvalidationReason(transfer.lastError) ||
          isTerminalFileTransferState(nextState)) {
        return const FileTransferAdmissionResult(
          decision: FileTransferAdmission.missing,
        );
      }
      if (!await _matchesStoredTrustedIdentityHash(
        transfer.peerUid,
        expectedPublicKeyHash,
      )) {
        return const FileTransferAdmissionResult(
          decision: FileTransferAdmission.missing,
        );
      }
      var associated = await fetchAssociatedFileTransferMessage(transfer);
      if (associated == null &&
          (replacementMessage == null ||
              !_isExactInvalidatedOutgoingReplacement(
                transfer,
                replacementMessage,
              ) ||
              (await fetchMessagesByUuid(
                replacementMessage.uuid,
              )).isNotEmpty)) {
        return const FileTransferAdmissionResult(
          decision: FileTransferAdmission.missing,
        );
      }
      if (await _nonterminalTransferCount(peerUid: transfer.peerUid) >=
          perPeerLimit) {
        return const FileTransferAdmissionResult(
          decision: FileTransferAdmission.peerLimit,
        );
      }
      if (await _nonterminalTransferCount() >= globalLimit) {
        return const FileTransferAdmissionResult(
          decision: FileTransferAdmission.globalLimit,
        );
      }
      associated ??= await insertMessageReturning(replacementMessage!);
      final affected =
          await (update(fileTransfer)..where(
                (item) =>
                    item.transferId.equals(transferId) &
                    item.direction.equalsValue(FileTransferDirection.outgoing) &
                    item.state.equalsValue(FileTransferState.canceled) &
                    item.lastError.equals(transfer.lastError) &
                    item.messageRowId.equals(transfer.messageRowId),
              ))
              .write(
                FileTransferCompanion(
                  state: Value(nextState),
                  messageRowId: Value(associated.id),
                  lastError: const Value(''),
                  updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
                ),
              );
      if (affected != 1) {
        throw StateError('invalidated transfer changed during reacquisition');
      }
      return FileTransferAdmissionResult(
        decision: FileTransferAdmission.admitted,
        message: associated,
        transfer: await fetchFileTransfer(transferId),
      );
    });
  }

  bool _isExactInvalidatedOutgoingReplacement(
    FileTransferData transfer,
    MessageData replacement,
  ) {
    if (!_isExactFileTransferMessageAssociation(transfer, replacement) ||
        replacement.path != transfer.finalPath) {
      return false;
    }
    try {
      final metadata = FileTransferV3Metadata.parseOffer(
        replacement.content,
        size: replacement.size,
      );
      return metadata.checksumAlgorithm == transfer.checksumAlgorithm &&
          metadata.checksumValue == transfer.checksumValue &&
          metadata.chunkSize == transfer.chunkSize;
    } on FileTransferV3MetadataException {
      return false;
    }
  }

  Future<bool> _matchesStoredTrustedIdentityHash(
    String peerUid,
    String? expectedPublicKeyHash,
  ) async {
    if (expectedPublicKeyHash == null) {
      return true;
    }
    if (expectedPublicKeyHash.length != 43 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(expectedPublicKeyHash)) {
      return false;
    }
    final stored = await fetchDevice(peerUid);
    if (stored == null || !stored.auth || stored.identityPublicKey.isEmpty) {
      return false;
    }
    try {
      final publicKey = decodeAuthBase64Url(
        stored.identityPublicKey,
        expectedLength: 32,
      );
      final actualHash = base64Url
          .encode(hashes.sha256.convert(publicKey).bytes)
          .replaceAll('=', '');
      return actualHash == expectedPublicKeyHash;
    } on FormatException {
      return false;
    }
  }

  Future<FileTransferData?> claimIncomingResumeProofReset(
    String transferId, {
    required int expectedOffset,
  }) {
    return transaction(() async {
      final transfer = await fetchFileTransfer(transferId);
      if (transfer == null ||
          transfer.direction != FileTransferDirection.incoming ||
          isTerminalFileTransferState(transfer.state) ||
          expectedOffset <= 0 ||
          transfer.committedBytes != expectedOffset ||
          transfer.resumeProofResetCount != 0 ||
          transfer.tempPath.isEmpty) {
        return null;
      }
      if (await fetchAssociatedFileTransferMessage(transfer) == null) {
        return null;
      }
      final affected =
          await (update(fileTransfer)..where(
                (item) =>
                    item.transferId.equals(transferId) &
                    item.direction.equalsValue(FileTransferDirection.incoming) &
                    item.committedBytes.equals(expectedOffset) &
                    item.resumeProofResetCount.equals(0),
              ))
              .write(
                FileTransferCompanion(
                  resumeProofResetCount: const Value(
                    pendingResumeProofResetMarker,
                  ),
                  updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
                ),
              );
      if (affected != 1) {
        return null;
      }
      return fetchFileTransfer(transferId);
    });
  }

  Future<FileTransferData?> completeIncomingResumeProofReset(
    String transferId, {
    required int expectedOffset,
  }) {
    return transaction(() async {
      final transfer = await fetchFileTransfer(transferId);
      if (transfer == null ||
          transfer.direction != FileTransferDirection.incoming ||
          isTerminalFileTransferState(transfer.state) ||
          expectedOffset <= 0 ||
          transfer.committedBytes != expectedOffset ||
          transfer.resumeProofResetCount != pendingResumeProofResetMarker ||
          transfer.tempPath.isEmpty) {
        return null;
      }
      if (await fetchAssociatedFileTransferMessage(transfer) == null) {
        return null;
      }
      final affected =
          await (update(fileTransfer)..where(
                (item) =>
                    item.transferId.equals(transferId) &
                    item.direction.equalsValue(FileTransferDirection.incoming) &
                    item.committedBytes.equals(expectedOffset) &
                    item.resumeProofResetCount.equals(
                      pendingResumeProofResetMarker,
                    ),
              ))
              .write(
                FileTransferCompanion(
                  state: const Value(FileTransferState.negotiating),
                  committedBytes: const Value(0),
                  resumeProofResetCount: const Value(1),
                  lastError: const Value(''),
                  updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
                ),
              );
      if (affected != 1) return null;
      return fetchFileTransfer(transferId);
    });
  }

  Future<int> _nonterminalTransferCount({String? peerUid}) async {
    final peerClause = peerUid == null ? '' : ' AND peer_uid = ?';
    final result = await customSelect(
      'SELECT COUNT(*) AS amount FROM file_transfer '
      "WHERE state NOT IN ('completed', 'failed', 'canceled')$peerClause",
      variables: <Variable<Object>>[
        if (peerUid != null) Variable<String>(peerUid),
      ],
      readsFrom: <ResultSetImplementation<Table, Object?>>{fileTransfer},
    ).getSingle();
    return result.read<int>('amount');
  }

  Future<int> updateFileTransfer(
    String transferId, {
    Value<FileTransferState> state = const Value.absent(),
    Value<int> committedBytes = const Value.absent(),
    Value<String> lastError = const Value.absent(),
    Value<String> finalPath = const Value.absent(),
    Value<String> tempPath = const Value.absent(),
    Value<String> checksumValue = const Value.absent(),
    Value<int> updatedAt = const Value.absent(),
  }) {
    return transaction(() async {
      final transfer = await fetchFileTransfer(transferId);
      if (transfer == null ||
          isTerminalFileTransferState(transfer.state) ||
          await fetchAssociatedFileTransferMessage(transfer) == null) {
        return 0;
      }
      return (update(fileTransfer)..where(
            (item) =>
                item.transferId.equals(transferId) &
                item.messageRowId.equals(transfer.messageRowId) &
                item.state.equalsValue(transfer.state) &
                item.state.isNotIn(const <String>[
                  'completed',
                  'failed',
                  'canceled',
                ]),
          ))
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
    });
  }

  Future<FileTransferData?> failRecoverableFileTransfer({
    required String transferId,
    required String peerUid,
    required FileTransferDirection direction,
    required String reason,
  }) {
    return transaction(() async {
      final transfer = await fetchFileTransfer(transferId);
      if (transfer == null ||
          transfer.peerUid != peerUid ||
          transfer.direction != direction ||
          isTerminalFileTransferState(transfer.state)) {
        return null;
      }
      final affected =
          await (update(fileTransfer)..where(
                (item) =>
                    item.transferId.equals(transferId) &
                    item.peerUid.equals(peerUid) &
                    item.direction.equalsValue(direction) &
                    item.messageRowId.equals(transfer.messageRowId) &
                    item.state.equalsValue(transfer.state),
              ))
              .write(
                FileTransferCompanion(
                  state: const Value(FileTransferState.failed),
                  lastError: Value(reason),
                  updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
                ),
              );
      return affected == 1 ? fetchFileTransfer(transferId) : null;
    });
  }

  Future<FileTransferData> completeIncomingFileTransfer({
    required String transferId,
    required String finalPath,
    required int size,
  }) {
    return transaction(() async {
      final transfer = await fetchFileTransfer(transferId);
      if (transfer == null ||
          transfer.direction != FileTransferDirection.incoming ||
          transfer.state != FileTransferState.verifying ||
          transfer.messageRowId <= 0 ||
          transfer.size != size) {
        throw StateError('invalid incoming transfer completion state');
      }
      final associatedMessage = await fetchAssociatedFileTransferMessage(
        transfer,
      );
      if (associatedMessage == null) {
        throw StateError('invalid incoming transfer message association');
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final transferUpdates =
          await (update(fileTransfer)..where(
                (item) =>
                    item.transferId.equals(transferId) &
                    item.messageRowId.equals(transfer.messageRowId) &
                    item.direction.equalsValue(FileTransferDirection.incoming) &
                    item.state.equalsValue(FileTransferState.verifying),
              ))
              .write(
                FileTransferCompanion(
                  state: const Value(FileTransferState.completed),
                  committedBytes: Value(size),
                  finalPath: Value(finalPath),
                  lastError: const Value(''),
                  updatedAt: Value(now),
                ),
              );
      if (transferUpdates != 1) {
        throw StateError('incoming transfer completion affected no transfer');
      }
      final messageUpdates =
          await (update(message)..where(
                (item) =>
                    item.id.equals(transfer.messageRowId) &
                    item.uuid.equals(transfer.messageUuid) &
                    item.type.equalsValue(MessageEnum.File),
              ))
              .write(MessageCompanion(path: Value(finalPath)));
      if (messageUpdates != 1) {
        throw StateError('incoming transfer completion affected no message');
      }
      final completed = await fetchFileTransfer(transferId);
      if (completed == null) {
        throw StateError('incoming transfer disappeared during completion');
      }
      return completed;
    });
  }

  Future<MessageData?> fetchMessageById(int id) {
    if (id <= 0) {
      return Future<MessageData?>.value();
    }
    return (select(
      message,
    )..where((item) => item.id.equals(id))).getSingleOrNull();
  }

  Future<MessageData?> fetchAssociatedFileTransferMessage(
    FileTransferData transfer,
  ) async {
    if (transfer.messageRowId <= 0) {
      return null;
    }
    final associated = await fetchMessageById(transfer.messageRowId);
    return associated != null &&
            _isExactFileTransferMessageAssociation(transfer, associated)
        ? associated
        : null;
  }

  bool _isExactFileTransferMessageAssociation(
    FileTransferData transfer,
    MessageData message,
  ) {
    if (transfer.transferId != message.uuid ||
        transfer.messageUuid != message.uuid ||
        message.type != MessageEnum.File ||
        transfer.size != message.size) {
      return false;
    }
    return switch (transfer.direction) {
      FileTransferDirection.incoming => message.sender == transfer.peerUid,
      FileTransferDirection.outgoing => message.receiver == transfer.peerUid,
    };
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
    final items = await (select(
      fileTransfer,
    )..where((t) => t.transferId.isIn(ids))).get();
    return <String, FileTransferData>{
      for (final item in items) item.transferId: item,
    };
  }

  Future<MessageData?> fetchMessageByUuid(String uuid) {
    return (select(message)
          ..where((t) => t.uuid.equals(uuid))
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<List<MessageData>> fetchMessagesByUuid(String uuid) {
    if (uuid.isEmpty) {
      return Future<List<MessageData>>.value(const <MessageData>[]);
    }
    return (select(message)
          ..where((t) => t.uuid.equals(uuid))
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
  }

  Future<List<FileTransferData>> fetchRecoverableFileTransfers() {
    return (select(fileTransfer)
          ..where(
            (t) => t.state.isNotIn(const <String>[
              'completed',
              'failed',
              'canceled',
            ]),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<List<FileTransferData>> fetchRetainedOutgoingFileTransfers() {
    return (select(fileTransfer)..where(
          (t) =>
              t.direction.equalsValue(FileTransferDirection.outgoing) &
              t.state.isNotIn(const <String>['completed', 'canceled']),
        ))
        .get();
  }

  Future<List<FileTransferData>> cancelOutgoingTransfersForPeer(
    String peerUid, {
    required String reason,
    bool revokeDeviceTrust = false,
  }) {
    if (peerUid.isEmpty || reason.isEmpty) {
      return Future<List<FileTransferData>>.value(const <FileTransferData>[]);
    }
    return transaction(
      () => _cancelOutgoingTransfersForPeerInTransaction(
        peerUid,
        reason: reason,
        revokeDeviceTrust: revokeDeviceTrust,
      ),
    );
  }

  Future<List<FileTransferData>> _cancelOutgoingTransfersForPeerInTransaction(
    String peerUid, {
    required String reason,
    bool revokeDeviceTrust = false,
  }) async {
    if (revokeDeviceTrust) {
      await (update(device)..where((item) => item.uid.equals(peerUid))).write(
        const DeviceCompanion(auth: Value(false)),
      );
    }
    final candidates =
        await (select(fileTransfer)..where(
              (item) =>
                  item.peerUid.equals(peerUid) &
                  item.direction.equalsValue(FileTransferDirection.outgoing) &
                  item.state.isNotIn(const <String>['completed', 'canceled']),
            ))
            .get();
    if (candidates.isNotEmpty) {
      final transferIds = candidates
          .map((item) => item.transferId)
          .toList(growable: false);
      final now = DateTime.now().millisecondsSinceEpoch;
      await (update(fileTransfer)..where(
            (item) =>
                item.transferId.isIn(transferIds) &
                item.state.isNotIn(const <String>['completed', 'canceled']),
          ))
          .write(
            FileTransferCompanion(
              state: const Value(FileTransferState.canceled),
              lastError: Value(reason),
              updatedAt: Value(now),
            ),
          );
    }
    return (select(fileTransfer)..where(
          (item) =>
              item.peerUid.equals(peerUid) &
              item.direction.equalsValue(FileTransferDirection.outgoing) &
              item.state.equalsValue(FileTransferState.canceled) &
              item.lastError.equals(reason),
        ))
        .get();
  }

  Future<List<FileTransferData>> fetchRecoverableFileTransfersForPeer(
    String peerUid, {
    FileTransferDirection? direction,
  }) async {
    final items = await fetchRecoverableFileTransfers();
    return items
        .where((item) {
          if (item.peerUid != peerUid) {
            return false;
          }
          if (direction != null && item.direction != direction) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
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
    return (select(remoteInputLayout)..orderBy([
          (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
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

extension DeviceDataDriftX on DeviceData {
  DeviceCompanion toCompanion(bool nullToAbsent) {
    return DeviceCompanion(
      id: Value<int>(id),
      uid: Value<String>(uid),
      identityPublicKey: Value<String>(identityPublicKey),
      name: Value<String>(name),
      host: Value<String>(host),
      port: Value<int>(port),
      password: password == null && nullToAbsent
          ? const Value<String?>.absent()
          : Value<String?>(password),
      platform: Value<String>(platform),
      isServer: Value<bool>(isServer),
      online: Value<bool>(online),
      clipboard: Value<bool>(clipboard),
      auth: Value<bool>(auth),
      lastTime: Value<int>(lastTime),
      around: around == null && nullToAbsent
          ? const Value<bool?>.absent()
          : Value<bool?>(around),
    );
  }

  DeviceData copyWithCompanion(DeviceCompanion data) {
    return DeviceData(
      id: data.id.present ? data.id.value : id,
      uid: data.uid.present ? data.uid.value : uid,
      identityPublicKey: data.identityPublicKey.present
          ? data.identityPublicKey.value
          : identityPublicKey,
      name: data.name.present ? data.name.value : name,
      host: data.host.present ? data.host.value : host,
      port: data.port.present ? data.port.value : port,
      password: data.password.present ? data.password.value : password,
      platform: data.platform.present ? data.platform.value : platform,
      isServer: data.isServer.present ? data.isServer.value : isServer,
      online: data.online.present ? data.online.value : online,
      clipboard: data.clipboard.present ? data.clipboard.value : clipboard,
      auth: data.auth.present ? data.auth.value : auth,
      lastTime: data.lastTime.present ? data.lastTime.value : lastTime,
      around: data.around.present ? data.around.value : around,
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
    final dbFolder = await _databaseDirectory();
    final file = File('${dbFolder.path}/db.sqlite');

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

    return NativeDatabase.createInBackground(
      file,
      setup: configureWhisperDatabase,
    );
  });
}

Future<Directory> _databaseDirectory() async {
  if (Platform.isMacOS) {
    final currentDirectory = await getApplicationSupportDirectory();
    final currentDatabase = File('${currentDirectory.path}/db.sqlite');
    if (await currentDatabase.exists()) {
      return currentDirectory;
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final legacyDirectory = Directory(
        '$home/Library/Containers/com.vireen.whisper/Data/Documents',
      );
      final legacyDatabase = File('${legacyDirectory.path}/db.sqlite');
      if (await migrateLegacyMacOSDatabase(
        legacyDatabase: legacyDatabase,
        destinationDirectory: currentDirectory,
      )) {
        return currentDirectory;
      }
      if (await legacyDatabase.exists()) {
        return legacyDirectory;
      }
    }
    return currentDirectory;
  }
  return getApplicationDocumentsDirectory();
}

Future<bool> migrateLegacyMacOSDatabase({
  required File legacyDatabase,
  required Directory destinationDirectory,
}) async {
  final destination = File('${destinationDirectory.path}/db.sqlite');
  if (await destination.exists()) {
    return true;
  }
  if (!await legacyDatabase.exists()) {
    return false;
  }

  await destinationDirectory.create(recursive: true);
  final temporary = File('${destination.path}.migrating');
  Database? source;
  Database? target;
  try {
    if (await temporary.exists()) {
      await temporary.delete();
    }
    source = sqlite3.open(legacyDatabase.path, mode: OpenMode.readOnly);
    target = sqlite3.open(temporary.path);
    await source.backup(target, nPage: -1).drain<void>();
    target.dispose();
    target = null;
    source.dispose();
    source = null;
    await temporary.rename(destination.path);
    return true;
  } catch (_) {
    return false;
  } finally {
    target?.dispose();
    source?.dispose();
    if (await temporary.exists()) {
      await temporary.delete();
    }
  }
}

void configureWhisperDatabase(Database database) {
  database
    ..execute('PRAGMA journal_mode = WAL;')
    ..execute('PRAGMA synchronous = NORMAL;');
}
