import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/ios_sandbox_path.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';

const oldRoot =
    '/private/var/mobile/Containers/Data/Application/'
    '11111111-1111-1111-1111-111111111111';
const newRoot =
    '/var/mobile/Containers/Data/Application/'
    '22222222-2222-2222-2222-222222222222';

void main() {
  for (final suffix in [
    'Documents/中文🙂.txt',
    'Documents/.whisper/transfers/transfer.part',
    'Library/Caches/picked.txt',
    'tmp/sent.txt',
    'Documents',
  ]) {
    test('rebases preserved sandbox $suffix after an update', () {
      final rebased = rebaseIosSandboxPath(
        '$oldRoot/$suffix',
        '$newRoot/Documents',
      );
      expect(rebased, '$newRoot/$suffix');
      expect(rebaseIosSandboxPath(rebased, '$newRoot/Documents'), rebased);
    });
  }
  for (final path in [
    '',
    '/tmp/external.txt',
    '/Volumes/drive/file.txt',
    'file://$oldRoot/Documents/file.txt',
    '$oldRoot/Documents/../other.txt',
    '$oldRoot/Other/file.txt',
    '$oldRoot/Documents/file\u0000.txt',
  ]) {
    test('preserves unrelated or invalid path $path', () {
      expect(rebaseIosSandboxPath(path, '$newRoot/Documents'), path);
    });
  }
  test('does not rebase against a non-container directory', () {
    const path = '$oldRoot/Documents/file.txt';
    expect(rebaseIosSandboxPath(path, '/tmp/Documents'), path);
  });
  test(
    'updates message and resumable transfer paths together without changing progress',
    () async {
      final db = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final messageId = await db
          .into(db.message)
          .insert(
            MessageCompanion.insert(
              uuid: const Value('fixture-message'),
              path: const Value('$oldRoot/Documents/中文.txt'),
              acked: const Value(true),
            ),
          );
      await db.upsertFileTransfer(
        const FileTransferData(
          transferId: 'fixture-transfer',
          messageUuid: 'fixture-message',
          messageRowId: 0,
          peerUid: 'peer',
          direction: FileTransferDirection.incoming,
          state: FileTransferState.paused,
          finalPath: '$oldRoot/Documents/中文.txt',
          tempPath: '$oldRoot/Documents/.whisper/transfers/fixture.part',
          size: 1024,
          checksumAlgorithm: 'sha256',
          checksumValue: 'checksum',
          chunkSize: 512,
          committedBytes: 512,
          resumeProofResetCount: 1,
          lastError: '',
          createdAt: 1,
          updatedAt: 2,
        ),
      );
      await db.rebaseIosFilePaths('$newRoot/Documents');
      await db.rebaseIosFilePaths('$newRoot/Documents');
      expect(
        (await db.fetchMessageById(messageId))!.path,
        '$newRoot/Documents/中文.txt',
      );
      expect((await db.fetchMessageById(messageId))!.acked, isTrue);
      final transfer = (await db.fetchFileTransfer('fixture-transfer'))!;
      expect(transfer.finalPath, '$newRoot/Documents/中文.txt');
      expect(
        transfer.tempPath,
        '$newRoot/Documents/.whisper/transfers/fixture.part',
      );
      expect(transfer.state, FileTransferState.paused);
      expect(transfer.committedBytes, 512);
      expect(transfer.resumeProofResetCount, 1);
      expect(transfer.updatedAt, 2);
    },
  );
}
