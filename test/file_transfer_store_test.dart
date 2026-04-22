import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';

void main() {
  group('FileTransfer persistence', () {
    late LocalDatabase database;

    setUp(() {
      database = LocalDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test('persists and reloads transfer state by transfer id', () async {
      final transfer = FileTransferData(
        transferId: 'transfer-1',
        messageUuid: 'message-1',
        peerUid: 'peer-a',
        direction: FileTransferDirection.outgoing,
        state: FileTransferState.negotiating,
        finalPath: '/tmp/archive.zip',
        tempPath: '/tmp/.whisper/transfers/transfer-1.part',
        size: 1024,
        checksumAlgorithm: 'sha256',
        checksumValue: 'abc123',
        chunkSize: 1024,
        committedBytes: 256,
        lastError: '',
        createdAt: 1,
        updatedAt: 2,
      );

      await database.upsertFileTransfer(transfer);
      final loaded = await database.fetchFileTransfer('transfer-1');

      expect(loaded, isNotNull);
      expect(loaded!.state, FileTransferState.negotiating);
      expect(loaded.committedBytes, 256);
      expect(loaded.direction, FileTransferDirection.outgoing);
    });

    test('lists only incomplete transfers for automatic recovery', () async {
      await database.upsertFileTransfer(
        FileTransferData(
          transferId: 'waiting',
          messageUuid: 'message-1',
          peerUid: 'peer-a',
          direction: FileTransferDirection.outgoing,
          state: FileTransferState.waitingReconnect,
          finalPath: '/tmp/archive.zip',
          tempPath: '/tmp/.whisper/transfers/waiting.part',
          size: 1024,
          checksumAlgorithm: 'sha256',
          checksumValue: 'abc123',
          chunkSize: 1024,
          committedBytes: 512,
          lastError: '',
          createdAt: 1,
          updatedAt: 3,
        ),
      );
      await database.upsertFileTransfer(
        FileTransferData(
          transferId: 'done',
          messageUuid: 'message-2',
          peerUid: 'peer-a',
          direction: FileTransferDirection.incoming,
          state: FileTransferState.completed,
          finalPath: '/tmp/done.zip',
          tempPath: '/tmp/.whisper/transfers/done.part',
          size: 1024,
          checksumAlgorithm: 'sha256',
          checksumValue: 'def456',
          chunkSize: 1024,
          committedBytes: 1024,
          lastError: '',
          createdAt: 1,
          updatedAt: 4,
        ),
      );

      final recoverable = await database.fetchRecoverableFileTransfers();

      expect(recoverable.map((item) => item.transferId), <String>['waiting']);
    });
  });
}
