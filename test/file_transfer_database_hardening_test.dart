import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('incoming transfer completion association', () {
    late LocalDatabase database;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '_uuid': 'local',
      });
      database = LocalDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => database.close());

    test('updates only the exact associated row when UUIDs are duplicated',
        () async {
      final first = await database.insertMessageReturning(
        _message(uuid: _transferId, name: 'first.bin'),
      );
      final associated = await database.insertMessageReturning(
        _message(uuid: _transferId, name: 'associated.bin'),
      );
      await database.upsertFileTransfer(
        _transfer(messageRowId: associated.id),
      );

      final completed = await database.completeIncomingFileTransfer(
        transferId: _transferId,
        finalPath: '/downloads/associated.bin',
        size: 4,
      );

      final firstAfter = await (database.select(database.message)
            ..where((row) => row.id.equals(first.id)))
          .getSingle();
      final associatedAfter = await (database.select(database.message)
            ..where((row) => row.id.equals(associated.id)))
          .getSingle();
      expect(completed.messageRowId, associated.id);
      expect(firstAfter.path, isEmpty);
      expect(associatedAfter.path, '/downloads/associated.bin');
    });

    test('rejects missing transfer, wrong association, direction, and state',
        () async {
      final message = await database.insertMessageReturning(
        _message(uuid: _transferId),
      );
      await expectLater(
        database.completeIncomingFileTransfer(
          transferId: _transferId,
          finalPath: '/downloads/file.bin',
          size: 4,
        ),
        throwsStateError,
      );

      for (final transfer in <FileTransferData>[
        _transfer(messageRowId: message.id, messageUuid: _otherTransferId),
        _transfer(
          messageRowId: message.id,
          direction: FileTransferDirection.outgoing,
        ),
        _transfer(
          messageRowId: message.id,
          state: FileTransferState.transferring,
        ),
      ]) {
        await database.upsertFileTransfer(transfer);
        await expectLater(
          database.completeIncomingFileTransfer(
            transferId: _transferId,
            finalPath: '/downloads/file.bin',
            size: 4,
          ),
          throwsStateError,
        );
        expect(
          (await database.fetchFileTransfer(_transferId))?.state,
          isNot(FileTransferState.completed),
        );
      }
      expect(
        (await (database.select(database.message)
                  ..where((row) => row.id.equals(message.id)))
                .getSingle())
            .path,
        isEmpty,
      );
    });

    test(
        'rolls back transfer update when the exact message update affects zero',
        () async {
      final message = await database.insertMessageReturning(
        _message(uuid: _transferId),
      );
      await database.upsertFileTransfer(_transfer(messageRowId: message.id));
      await database.customStatement('''
        CREATE TRIGGER ignore_transfer_message_completion
        BEFORE UPDATE OF path ON message
        WHEN OLD.id = ${message.id}
        BEGIN
          SELECT RAISE(IGNORE);
        END
      ''');

      await expectLater(
        database.completeIncomingFileTransfer(
          transferId: _transferId,
          finalPath: '/downloads/file.bin',
          size: 4,
        ),
        throwsStateError,
      );

      expect(
        (await database.fetchFileTransfer(_transferId))?.state,
        FileTransferState.verifying,
      );
      expect(
        (await (database.select(database.message)
                  ..where((row) => row.id.equals(message.id)))
                .getSingle())
            .path,
        isEmpty,
      );
    });

    test('rejects a completion when the transfer update affects zero',
        () async {
      final message = await database.insertMessageReturning(
        _message(uuid: _transferId),
      );
      await database.upsertFileTransfer(_transfer(messageRowId: message.id));
      await database.customStatement('''
        CREATE TRIGGER ignore_transfer_completion
        BEFORE UPDATE OF state ON file_transfer
        WHEN OLD.transfer_id = '$_transferId'
        BEGIN
          SELECT RAISE(IGNORE);
        END
      ''');

      await expectLater(
        database.completeIncomingFileTransfer(
          transferId: _transferId,
          finalPath: '/downloads/file.bin',
          size: 4,
        ),
        throwsStateError,
      );

      expect(
        (await database.fetchFileTransfer(_transferId))?.state,
        FileTransferState.verifying,
      );
      expect(
        (await database.fetchMessageById(message.id))?.path,
        isEmpty,
      );
    });

    test('quota-terminal orphan repair persists association in one transaction',
        () async {
      final orphanMessage = await database.insertMessageReturning(
        _message(uuid: _transferId),
      );
      await database.upsertFileTransfer(
        _transfer(
          messageRowId: 0,
          messageUuid: _otherTransferId,
          state: FileTransferState.transferring,
        ).copyWith(transferId: _otherTransferId),
      );

      final result = await database.admitTransferForExistingMessage(
        message: orphanMessage,
        transfer: _transfer(messageRowId: 0),
        perPeerLimit: 1,
        globalLimit: 2,
      );

      expect(result.decision, FileTransferAdmission.peerLimit);
      expect(result.transfer?.state, FileTransferState.failed);
      expect(result.transfer?.lastError, 'queue_full');
      expect(result.transfer?.messageRowId, orphanMessage.id);
      final persisted = await database.fetchFileTransfer(_transferId);
      expect(persisted?.state, FileTransferState.failed);
      expect(persisted?.messageRowId, orphanMessage.id);
    });

    test('one message row can belong to only one transfer', () async {
      final message = await database.insertMessageReturning(
        _message(uuid: _transferId),
      );
      await database.upsertFileTransfer(_transfer(messageRowId: message.id));

      await expectLater(
        database.upsertFileTransfer(
          _transfer(
            messageRowId: message.id,
            messageUuid: _otherTransferId,
          ).copyWith(transferId: _otherTransferId),
        ),
        throwsA(anything),
      );
      expect(await database.fetchFileTransfer(_otherTransferId), isNull);
    });
  });

  group('message deletion invariants', () {
    late LocalDatabase database;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '_uuid': 'local',
      });
      database = LocalDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => database.close());

    test('deleteMessage atomically cancels and detaches its active transfer',
        () async {
      final message = await database.insertMessageReturning(
        _message(uuid: _transferId),
      );
      await database.upsertFileTransfer(
        _transfer(
          messageRowId: message.id,
          state: FileTransferState.transferring,
        ),
      );

      await database.deleteMessage(message.id);

      expect(await database.fetchMessageById(message.id), isNull);
      final transfer = await database.fetchFileTransfer(_transferId);
      expect(transfer?.messageRowId, 0);
      expect(transfer?.state, FileTransferState.canceled);
      expect(transfer?.lastError, 'message_deleted');
      expect(
        await database.reacquireFileTransferCapacity(
          _transferId,
          nextState: FileTransferState.negotiating,
        ),
        FileTransferAdmission.missing,
        reason: 'a detached transfer must not be resurrected',
      );
    });

    test('deleteMessages removes the selected rows and keeps other messages',
        () async {
      final first = await database.insertMessageReturning(
        _message(uuid: _transferId),
      );
      final second = await database.insertMessageReturning(
        _message(uuid: _otherTransferId),
      );
      final retained = await database.insertMessageReturning(
        _message(uuid: 'retained-transfer'),
      );
      await database.upsertFileTransfer(
        _transfer(
          messageRowId: first.id,
          state: FileTransferState.transferring,
        ),
      );

      await database.deleteMessages(<int>{first.id, second.id});

      expect(await database.fetchMessageById(first.id), isNull);
      expect(await database.fetchMessageById(second.id), isNull);
      expect(await database.fetchMessageById(retained.id), isNotNull);
      final transfer = await database.fetchFileTransfer(_transferId);
      expect(transfer?.messageRowId, 0);
      expect(transfer?.state, FileTransferState.canceled);
    });

    test('deleteMessage rolls transfer changes back if deletion fails',
        () async {
      final message = await database.insertMessageReturning(
        _message(uuid: _transferId),
      );
      await database.upsertFileTransfer(
        _transfer(
          messageRowId: message.id,
          state: FileTransferState.transferring,
        ),
      );
      await database.customStatement('''
        CREATE TRIGGER reject_message_delete
        BEFORE DELETE ON message
        WHEN OLD.id = ${message.id}
        BEGIN
          SELECT RAISE(ABORT, 'injected delete failure');
        END
      ''');

      await expectLater(database.deleteMessage(message.id), throwsA(anything));

      expect(await database.fetchMessageById(message.id), isNotNull);
      final transfer = await database.fetchFileTransfer(_transferId);
      expect(transfer?.messageRowId, message.id);
      expect(transfer?.state, FileTransferState.transferring);
    });

    test('clearDevices cancels only transfers associated with removed messages',
        () async {
      final removed = await database.insertMessageReturning(
        _message(uuid: _transferId),
      );
      final retained = await database.insertMessageReturning(
        _message(uuid: _otherTransferId).copyWith(sender: 'peer-b'),
      );
      await database.upsertFileTransfer(
        _transfer(
          messageRowId: removed.id,
          state: FileTransferState.queued,
        ),
      );
      await database.upsertFileTransfer(
        _transfer(
          messageRowId: retained.id,
          messageUuid: _otherTransferId,
          state: FileTransferState.queued,
        ).copyWith(
          transferId: _otherTransferId,
          peerUid: 'peer-b',
        ),
      );

      await database.clearDevices(const <String>['peer-a']);

      final detached = await database.fetchFileTransfer(_transferId);
      final untouched = await database.fetchFileTransfer(_otherTransferId);
      expect(detached?.messageRowId, 0);
      expect(detached?.state, FileTransferState.canceled);
      expect(await database.fetchMessageById(removed.id), isNull);
      expect(untouched?.messageRowId, retained.id);
      expect(untouched?.state, FileTransferState.queued);
      expect(await database.fetchMessageById(retained.id), isNotNull);
    });
  });

  group('retry association validation', () {
    late LocalDatabase database;

    setUp(() {
      database = LocalDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => database.close());

    test('reacquire rejects every missing or mismatched message association',
        () async {
      final mismatchedUuid = await database.insertMessageReturning(
        _message(uuid: _otherTransferId),
      );
      final wrongPeer = await database.insertMessageReturning(
        _message(uuid: _contenderOneId).copyWith(sender: 'peer-b'),
      );
      final wrongSize = await database.insertMessageReturning(
        _message(uuid: _contenderTwoId).copyWith(size: 5),
      );
      final wrongType = await database.insertMessageReturning(
        _message(uuid: _contendedMessageId).copyWith(type: MessageEnum.Text),
      );
      final cases = <FileTransferData>[
        _transfer(messageRowId: 0),
        _transfer(
          messageRowId: mismatchedUuid.id,
          messageUuid: _transferId,
        ).copyWith(transferId: '51234567-89ab-4cde-8fab-0123456789ab'),
        _transfer(
          messageRowId: wrongPeer.id,
          messageUuid: _contenderOneId,
        ).copyWith(transferId: _contenderOneId),
        _transfer(
          messageRowId: wrongSize.id,
          messageUuid: _contenderTwoId,
        ).copyWith(transferId: _contenderTwoId),
        _transfer(
          messageRowId: wrongType.id,
          messageUuid: _contendedMessageId,
        ).copyWith(transferId: _contendedMessageId),
      ];
      for (final transfer in cases) {
        final failed = transfer.copyWith(state: FileTransferState.failed);
        await database.upsertFileTransfer(failed);
        expect(
          await database.reacquireFileTransferCapacity(
            failed.transferId,
            nextState: FileTransferState.negotiating,
          ),
          FileTransferAdmission.missing,
          reason: failed.transferId,
        );
        expect(
          (await database.fetchFileTransfer(failed.transferId))?.state,
          FileTransferState.failed,
        );
      }
    });

    test('reacquire admits an exact file message association', () async {
      final message = await database.insertMessageReturning(
        _message(uuid: _transferId),
      );
      await database.upsertFileTransfer(
        _transfer(messageRowId: message.id).copyWith(
          state: FileTransferState.failed,
        ),
      );

      expect(
        await database.reacquireFileTransferCapacity(
          _transferId,
          nextState: FileTransferState.negotiating,
        ),
        FileTransferAdmission.admitted,
      );
      expect(
        (await database.fetchFileTransfer(_transferId))?.state,
        FileTransferState.negotiating,
      );
    });
  });

  group('admission association validation', () {
    List<({MessageData message, FileTransferData transfer})> invalidCases() {
      const ids = <String>[
        '51000000-0000-4000-8000-000000000001',
        '51000000-0000-4000-8000-000000000002',
        '51000000-0000-4000-8000-000000000003',
        '51000000-0000-4000-8000-000000000004',
        '51000000-0000-4000-8000-000000000005',
        '51000000-0000-4000-8000-000000000006',
      ];
      FileTransferData draft(String id) => _transfer(
            messageRowId: 0,
            messageUuid: id,
            state: FileTransferState.queued,
          ).copyWith(transferId: id);

      return <({MessageData message, FileTransferData transfer})>[
        (
          message: _message(uuid: ids[0]),
          transfer: draft(ids[0]).copyWith(transferId: _otherTransferId),
        ),
        (
          message: _message(uuid: ids[1]),
          transfer: draft(ids[1]).copyWith(messageUuid: _otherTransferId),
        ),
        (
          message: _message(uuid: ids[2]).copyWith(type: MessageEnum.Text),
          transfer: draft(ids[2]),
        ),
        (
          message: _message(uuid: ids[3]).copyWith(size: 5),
          transfer: draft(ids[3]),
        ),
        (
          message: _message(uuid: ids[4]),
          transfer: draft(ids[4]).copyWith(peerUid: 'peer-b'),
        ),
        (
          message: _message(uuid: ids[5]),
          transfer: draft(ids[5]).copyWith(
            direction: FileTransferDirection.outgoing,
          ),
        ),
      ];
    }

    test('new admission rejects every mismatch before any persistence',
        () async {
      for (final item in invalidCases()) {
        final database = LocalDatabase.forTesting(NativeDatabase.memory());
        final result = await database.admitFileTransfer(
          message: item.message,
          transfer: item.transfer,
        );

        expect(result.decision, FileTransferAdmission.missing);
        expect(
            await database.fetchFileTransfer(item.transfer.transferId), isNull);
        expect(await database.fetchMessagesByUuid(item.message.uuid), isEmpty);
        await database.close();
      }
    });

    test('existing-message admission rejects mismatches without a transfer',
        () async {
      for (final item in invalidCases()) {
        final database = LocalDatabase.forTesting(NativeDatabase.memory());
        final persisted = await database.insertMessageReturning(item.message);
        final result = await database.admitTransferForExistingMessage(
          message: persisted,
          transfer: item.transfer,
        );

        expect(result.decision, FileTransferAdmission.missing);
        expect(
            await database.fetchFileTransfer(item.transfer.transferId), isNull);
        expect(await database.fetchMessageById(persisted.id), isNotNull);
        await database.close();
      }
    });
  });

  test('schema 7 upgrade backfills only an unambiguous message row', () async {
    final directory = await Directory.systemTemp.createTemp('whisper-v7-v8-');
    final file = File('${directory.path}/legacy.sqlite');
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('''
      CREATE TABLE message (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        device_id INTEGER,
        sender TEXT NOT NULL DEFAULT '',
        receiver TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL DEFAULT '',
        clipboard INTEGER NOT NULL DEFAULT 0,
        size INTEGER NOT NULL DEFAULT 0,
        type INTEGER NOT NULL DEFAULT 0,
        content TEXT DEFAULT '',
        message TEXT DEFAULT '',
        timestamp INTEGER NOT NULL DEFAULT 0,
        uuid TEXT NOT NULL DEFAULT '',
        acked INTEGER NOT NULL DEFAULT 0,
        path TEXT NOT NULL DEFAULT '',
        md5 TEXT NOT NULL DEFAULT '',
        file_timestamp INTEGER DEFAULT 0
      )
    ''');
    raw.execute('''
      CREATE TABLE file_transfer (
        transfer_id TEXT NOT NULL PRIMARY KEY,
        message_uuid TEXT NOT NULL,
        peer_uid TEXT NOT NULL,
        direction TEXT NOT NULL,
        state TEXT NOT NULL,
        final_path TEXT NOT NULL,
        temp_path TEXT NOT NULL,
        size INTEGER NOT NULL DEFAULT 0,
        checksum_algorithm TEXT NOT NULL DEFAULT '',
        checksum_value TEXT NOT NULL DEFAULT '',
        chunk_size INTEGER NOT NULL,
        committed_bytes INTEGER NOT NULL DEFAULT 0,
        last_error TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    raw.execute('''
      INSERT INTO message (sender, receiver, name, size, type, uuid)
      VALUES
        ('peer-a', 'local', 'one.bin', 4, ${MessageEnum.File.index}, '$_transferId'),
        ('peer-a', 'local', 'dup-a.bin', 4, ${MessageEnum.File.index}, '$_otherTransferId'),
        ('peer-a', 'local', 'dup-b.bin', 4, ${MessageEnum.File.index}, '$_otherTransferId'),
        ('peer-a', 'local', 'contended.bin', 4, ${MessageEnum.File.index}, '$_contendedMessageId')
    ''');
    raw.execute('''
      INSERT INTO file_transfer
        (transfer_id, message_uuid, peer_uid, direction, state, final_path,
         temp_path, size, checksum_algorithm, checksum_value, chunk_size,
         committed_bytes, created_at, updated_at)
      VALUES
        ('$_transferId', '$_transferId', 'peer-a', 'incoming', 'queued', '',
         '/tmp/one.part', 4, 'sha256', '${'0' * 64}', 524288, 0, 1, 1),
        ('$_otherTransferId', '$_otherTransferId', 'peer-a', 'incoming', 'queued', '',
         '/tmp/dup.part', 4, 'sha256', '${'0' * 64}', 524288, 0, 1, 1),
        ('$_contenderOneId', '$_contendedMessageId', 'peer-a', 'incoming', 'queued', '',
         '/tmp/contender-one.part', 4, 'sha256', '${'0' * 64}', 524288, 0, 1, 1),
        ('$_contenderTwoId', '$_contendedMessageId', 'peer-a', 'incoming', 'queued', '',
         '/tmp/contender-two.part', 4, 'sha256', '${'0' * 64}', 524288, 0, 1, 1)
    ''');
    raw.execute('PRAGMA user_version = 7');
    raw.dispose();

    var database = LocalDatabase.forTesting(NativeDatabase(file));
    try {
      final associated = await database.fetchFileTransfer(_transferId);
      final ambiguous = await database.fetchFileTransfer(_otherTransferId);
      expect(database.schemaVersion, 10);
      expect(associated?.messageRowId, 1);
      expect(associated?.resumeProofResetCount, 0);
      expect(ambiguous?.messageRowId, 0);
      expect(ambiguous?.state, FileTransferState.failed);
      expect(ambiguous?.lastError, 'message_association_unresolved');
      for (final id in <String>[_contenderOneId, _contenderTwoId]) {
        final contender = await database.fetchFileTransfer(id);
        expect(contender?.messageRowId, 0);
        expect(contender?.state, FileTransferState.failed);
        expect(contender?.lastError, 'message_association_unresolved');
      }
      final columns =
          await database.customSelect('PRAGMA table_info(file_transfer)').get();
      expect(
        columns.map((row) => row.read<String>('name')),
        containsAll(<String>['message_row_id', 'resume_proof_reset_count']),
      );
      final indexes =
          await database.customSelect('PRAGMA index_list(file_transfer)').get();
      expect(
        indexes.map((row) => row.read<String>('name')),
        containsAll(<String>[
          'file_transfer_message_row_lookup',
          'file_transfer_message_row_unique',
        ]),
      );
      final uniqueIndex = indexes.singleWhere(
        (row) => row.read<String>('name') == 'file_transfer_message_row_unique',
      );
      expect(uniqueIndex.read<int>('unique'), 1);
    } finally {
      await database.close();
    }

    database = LocalDatabase.forTesting(NativeDatabase(file));
    try {
      expect((await database.fetchFileTransfer(_transferId))?.messageRowId, 1);
      expect(
        (await database.fetchFileTransfer(_otherTransferId))?.state,
        FileTransferState.failed,
      );
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('v9 migration sanitizes historical transfer errors', () async {
    final directory = await Directory.systemTemp.createTemp('whisper-v8-dup-');
    final file = File('${directory.path}/conflict.sqlite');
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('''
      CREATE TABLE message (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        device_id INTEGER,
        sender TEXT NOT NULL DEFAULT '', receiver TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL DEFAULT '', clipboard INTEGER NOT NULL DEFAULT 0,
        size INTEGER NOT NULL DEFAULT 0, type INTEGER NOT NULL DEFAULT 0,
        content TEXT DEFAULT '', message TEXT DEFAULT '',
        timestamp INTEGER NOT NULL DEFAULT 0, uuid TEXT NOT NULL DEFAULT '',
        acked INTEGER NOT NULL DEFAULT 0, path TEXT NOT NULL DEFAULT '',
        md5 TEXT NOT NULL DEFAULT '', file_timestamp INTEGER DEFAULT 0
      )
    ''');
    raw.execute('''
      CREATE TABLE file_transfer (
        transfer_id TEXT NOT NULL PRIMARY KEY, message_uuid TEXT NOT NULL,
        message_row_id INTEGER NOT NULL DEFAULT 0, peer_uid TEXT NOT NULL,
        direction TEXT NOT NULL, state TEXT NOT NULL,
        final_path TEXT NOT NULL, temp_path TEXT NOT NULL,
        size INTEGER NOT NULL DEFAULT 0,
        checksum_algorithm TEXT NOT NULL DEFAULT '',
        checksum_value TEXT NOT NULL DEFAULT '', chunk_size INTEGER NOT NULL,
        committed_bytes INTEGER NOT NULL DEFAULT 0,
        resume_proof_reset_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    raw.execute('''
      INSERT INTO message (sender, receiver, name, size, type, uuid)
      VALUES ('peer-a', 'local', 'shared.bin', 4, ${MessageEnum.File.index}, '$_transferId')
    ''');
    for (final entry in <({String id, String state, String error})>[
      (id: _transferId, state: 'completed', error: 'completed-history'),
      (id: _otherTransferId, state: 'canceled', error: 'canceled-history'),
      (id: _contendedMessageId, state: 'transferring', error: ''),
    ]) {
      raw.execute('''
        INSERT INTO file_transfer
          (transfer_id, message_uuid, message_row_id, peer_uid, direction,
           state, final_path, temp_path, size, checksum_algorithm,
           checksum_value, chunk_size, committed_bytes,
           resume_proof_reset_count, last_error, created_at, updated_at)
        VALUES (?, '$_transferId', 1, 'peer-a', 'incoming', ?, '', '', 4,
                'sha256', '${'0' * 64}', 524288, 0, 0, ?, 1, 1)
      ''', <Object?>[entry.id, entry.state, entry.error]);
    }
    raw.execute('PRAGMA user_version = 8');
    raw.dispose();

    final database = LocalDatabase.forTesting(NativeDatabase(file));
    try {
      final completed = await database.fetchFileTransfer(_transferId);
      final canceled = await database.fetchFileTransfer(_otherTransferId);
      final active = await database.fetchFileTransfer(_contendedMessageId);
      expect(database.schemaVersion, 10);
      expect((completed?.messageRowId, completed?.state, completed?.lastError),
          (0, FileTransferState.completed, 'remote_failure'));
      expect((canceled?.messageRowId, canceled?.state, canceled?.lastError),
          (0, FileTransferState.canceled, 'remote_failure'));
      expect((active?.messageRowId, active?.state, active?.lastError),
          (0, FileTransferState.failed, 'message_association_conflict'));
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });
}

const _transferId = '01234567-89ab-4cde-8fab-0123456789ab';
const _otherTransferId = '11234567-89ab-4cde-8fab-0123456789ab';
const _contendedMessageId = '21234567-89ab-4cde-8fab-0123456789ab';
const _contenderOneId = '31234567-89ab-4cde-8fab-0123456789ab';
const _contenderTwoId = '41234567-89ab-4cde-8fab-0123456789ab';

MessageData _message({required String uuid, String name = 'file.bin'}) =>
    MessageData(
      id: 0,
      sender: 'peer-a',
      receiver: 'local',
      name: name,
      clipboard: false,
      size: 4,
      type: MessageEnum.File,
      content: '{}',
      message: '',
      timestamp: 1,
      uuid: uuid,
      acked: false,
      path: '',
      md5: '',
    );

FileTransferData _transfer({
  required int messageRowId,
  String messageUuid = _transferId,
  FileTransferDirection direction = FileTransferDirection.incoming,
  FileTransferState state = FileTransferState.verifying,
}) =>
    FileTransferData(
      transferId: _transferId,
      messageUuid: messageUuid,
      messageRowId: messageRowId,
      peerUid: 'peer-a',
      direction: direction,
      state: state,
      finalPath: '',
      tempPath: '/downloads/.whisper/transfers/$_transferId.part',
      size: 4,
      checksumAlgorithm: 'sha256',
      checksumValue:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      chunkSize: 512 * 1024,
      committedBytes: 4,
      resumeProofResetCount: 0,
      lastError: '',
      createdAt: 1,
      updatedAt: 1,
    );
