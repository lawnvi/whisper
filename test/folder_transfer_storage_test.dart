import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:whisper/helper/folder_transfer_store.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/file_path_policy.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/folder_transfer_manifest.dart';
import 'package:whisper/state/folder_message.dart';
import 'package:whisper/state/message_deletion.dart';

const _firstId = '01234567-89ab-4cde-8fab-0123456789ab';
const _secondId = '11234567-89ab-4cde-8fab-0123456789ab';
const _thirdId = '21234567-89ab-4cde-8fab-0123456789ab';

String _folderContent({int skippedAtSource = 0}) => jsonEncode(
  FileTransferV3Metadata(
    checksumAlgorithm: fileTransferFolderChecksumAlgorithm,
    checksumValue: 'a' * 64,
    folder: FolderOfferSummary(
      manifestLength: 100,
      fileCount: 2,
      directoryCount: 1,
      totalBytes: 50,
      skippedAtSource: skippedAtSource,
    ),
  ).toJson(),
);

MessageData _message(
  String id, {
  required String content,
  String sender = 'peer-a',
  String receiver = 'local',
  String path = '',
  int size = 216,
}) => MessageData(
  id: 0,
  sender: sender,
  receiver: receiver,
  name: 'Folder',
  clipboard: false,
  size: size,
  type: MessageEnum.File,
  content: content,
  message: '',
  timestamp: 1,
  uuid: id,
  acked: false,
  path: path,
  md5: '',
  fileTimestamp: 0,
);

FileTransferData _transfer(
  String id, {
  required FileTransferDirection direction,
  required FileTransferState state,
  int messageRowId = 0,
  int size = 216,
}) => FileTransferData(
  transferId: id,
  messageUuid: id,
  messageRowId: messageRowId,
  peerUid: 'peer-a',
  direction: direction,
  state: state,
  finalPath: '',
  tempPath: '',
  size: size,
  checksumAlgorithm: fileTransferFolderChecksumAlgorithm,
  checksumValue: 'a' * 64,
  chunkSize: 524288,
  committedBytes: 0,
  resumeProofResetCount: 0,
  lastError: '',
  createdAt: 1,
  updatedAt: 1,
);

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('whisper-folder-storage-');
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  group('store', () {
    late FolderTransferStore store;
    late Directory directory;

    setUp(() {
      directory = Directory(p.join(temp.path, 'store'));
      store = FolderTransferStore(directory: () async => directory);
    });

    test('keeps a manifest until it is released', () async {
      final manifest = Uint8List.fromList(<int>[1, 2, 3]);

      await store.writeManifest(_firstId, manifest);
      final path = await store.manifestPath(_firstId);

      expect(File(path).readAsBytesSync(), manifest);
      expect(directory.listSync(), hasLength(1));
      await store.deleteManifest(_firstId);
      expect(File(path).existsSync(), isFalse);
      await store.deleteManifest(_firstId);
    });

    test('refuses an id that could name another file', () {
      expect(() => store.manifestPath('../escape'), throwsArgumentError);
    });

    test('adds skipped entries without repeating a path', () async {
      await store.addSkipped(_firstId, const <FolderSkippedEntry>[
        FolderSkippedEntry(path: 'a/link', reason: FolderSkipReason.symlink),
      ]);
      await store.addSkipped(_firstId, const <FolderSkippedEntry>[
        FolderSkippedEntry(path: 'a/link', reason: FolderSkipReason.unreadable),
        FolderSkippedEntry(
          path: 'b.txt',
          reason: FolderSkipReason.sourceUnavailable,
        ),
      ]);

      final entries = await store.readSkipped(_firstId);

      expect(entries.map((entry) => entry.path), <String>['a/link', 'b.txt']);
      expect(entries.first.reason, FolderSkipReason.symlink);
      expect(await store.readSkipped(_secondId), isEmpty);
    });

    test('an unreadable skipped list is treated as empty', () async {
      await store.addSkipped(_firstId, const <FolderSkippedEntry>[
        FolderSkippedEntry(path: 'a', reason: FolderSkipReason.symlink),
      ]);
      directory.listSync().whereType<File>().single.writeAsStringSync('{');

      expect(await store.readSkipped(_firstId), isEmpty);
    });

    test('leftovers go once their transfer no longer needs them', () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      Future<void> stale(String transferId) async {
        await store.writeManifest(transferId, Uint8List(1));
        await store.addSkipped(transferId, const <FolderSkippedEntry>[
          FolderSkippedEntry(path: 'a', reason: FolderSkipReason.symlink),
        ]);
      }

      await stale(_firstId);
      await stale(_secondId);
      await stale(_thirdId);
      final old = DateTime.now().subtract(const Duration(hours: 1));
      for (final file in directory.listSync().whereType<File>()) {
        file.setLastModifiedSync(old);
      }
      // A fresh manifest whose transfer has not been recorded yet.
      const pendingId = '31234567-89ab-4cde-8fab-0123456789ab';
      await store.writeManifest(pendingId, Uint8List(1));
      await database.upsertFileTransfer(
        _transfer(
          _firstId,
          direction: FileTransferDirection.outgoing,
          state: FileTransferState.waitingReconnect,
        ),
      );
      await database.upsertFileTransfer(
        _transfer(
          _secondId,
          direction: FileTransferDirection.outgoing,
          state: FileTransferState.completed,
        ),
      );

      await store.removeLeftovers(database);

      final names = directory
          .listSync()
          .map((entity) => p.basename(entity.path))
          .toSet();
      expect(names, <String>{
        '$_firstId.manifest',
        '$_firstId.skipped.json',
        '$_secondId.skipped.json',
        '$pendingId.manifest',
      });
    });
  });

  test('abandoned staging is removed, resumable staging is kept', () async {
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final downloads = Directory(p.join(temp.path, 'downloads'))..createSync();
    Directory staged(String transferId) => Directory(
      p.join(downloads.path, '.whisper', 'transfers', '$transferId.folder'),
    )..createSync(recursive: true);
    final resumable = staged(_firstId);
    final canceled = staged(_secondId);
    final unknown = staged(_thirdId);
    final part = File(
      p.join(downloads.path, '.whisper', 'transfers', '$_thirdId.part'),
    )..writeAsBytesSync(<int>[1]);
    final message = await database.insertMessageReturning(
      _message(_firstId, content: _folderContent()),
    );
    await database.upsertFileTransfer(
      _transfer(
        _firstId,
        direction: FileTransferDirection.incoming,
        state: FileTransferState.waitingReconnect,
        messageRowId: message.id,
      ),
    );
    await database.upsertFileTransfer(
      _transfer(
        _secondId,
        direction: FileTransferDirection.incoming,
        state: FileTransferState.canceled,
        messageRowId: 5,
      ),
    );

    await removeAbandonedFolderStaging(database, downloads);

    expect(resumable.existsSync(), isTrue);
    expect(canceled.existsSync(), isFalse);
    expect(unknown.existsSync(), isFalse);
    expect(part.existsSync(), isTrue, reason: 'single files are not touched');
    await removeAbandonedFolderStaging(
      database,
      Directory(p.join(temp.path, 'no-such-root')),
    );
  });

  group('staging path', () {
    test('stays inside the download root', () async {
      final root = Directory(p.join(temp.path, 'downloads'))..createSync();

      final path = await safeFolderStagingPath(root, _firstId);

      expect(p.isWithin(root.resolveSymbolicLinksSync(), path), isTrue);
      expect(p.basename(path), '$_firstId.folder');
      expect(
        () => safeFolderStagingPath(root, '../x'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        revalidateFolderStagingDirectory(
          root: root,
          transferId: _firstId,
          expectedPath: p.join(temp.path, 'elsewhere'),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a file standing where staging belongs is refused', () async {
      final root = Directory(p.join(temp.path, 'downloads'))..createSync();
      final transfers = Directory(p.join(root.path, '.whisper', 'transfers'))
        ..createSync(recursive: true);
      File(
        p.join(transfers.path, '$_firstId.folder'),
      ).writeAsBytesSync(<int>[]);

      await expectLater(
        safeFolderStagingPath(root, _firstId),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('publishing', () {
    test('never replaces what is already there', () async {
      final root = Directory(p.join(temp.path, 'downloads'))..createSync();
      Directory staged(String marker) {
        final directory = Directory(p.join(temp.path, 'staged-$marker'))
          ..createSync();
        File(p.join(directory.path, marker)).writeAsStringSync(marker);
        return directory;
      }

      File(p.join(root.path, 'Photos-1')).writeAsStringSync('a file');
      final first = await publishStagedDirectory(staged('a'), root, 'Photos');
      final second = await publishStagedDirectory(staged('b'), root, 'Photos');

      expect(p.basename(first.path), 'Photos');
      expect(p.basename(second.path), 'Photos-2');
      expect(File(p.join(first.path, 'a')).existsSync(), isTrue);
      expect(File(p.join(second.path, 'b')).existsSync(), isTrue);
      expect(File(p.join(root.path, 'Photos-1')).readAsStringSync(), 'a file');
    });

    test('refuses a name that is a path, and a missing source', () async {
      final root = Directory(p.join(temp.path, 'downloads'))..createSync();

      expect(
        () => publishStagedDirectory(Directory(temp.path), root, '../out'),
        throwsArgumentError,
      );
      await expectLater(
        publishStagedDirectory(
          Directory(p.join(temp.path, 'missing')),
          root,
          'Photos',
        ),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('folder messages', () {
    test('are told apart from single files by their offer', () {
      final folder = folderOfferOf(
        _message(_firstId, content: _folderContent(skippedAtSource: 4)),
      );

      expect(folder?.fileCount, 2);
      expect(folder?.totalBytes, 50);
      expect(folder?.skippedAtSource, 4);
      expect(
        folderOfferOf(
          _message(
            _firstId,
            content: jsonEncode(
              const FileTransferV3Metadata(checksumValue: '').toJson(),
            ),
          ),
        ),
        isNull,
      );
      expect(
        folderOfferOf(
          _message(_firstId, content: 'sha256-folder-v1 but not json'),
        ),
        isNull,
      );
      expect(
        folderOfferOf(
          _message(
            _firstId,
            content: _folderContent(),
          ).copyWith(type: MessageEnum.Text),
        ),
        isNull,
      );
    });

    test('deleting a received folder removes the folder', () async {
      final received = Directory(p.join(temp.path, 'Folder'))..createSync();
      File(p.join(received.path, 'a.txt')).writeAsStringSync('a');
      Directory(p.join(received.path, 'sub')).createSync();

      await deleteReceivedMessageFile(
        _message(_firstId, content: _folderContent(), path: received.path),
        selfUid: 'local',
        path: received.path,
      );

      expect(received.existsSync(), isFalse);
    });

    test(
      'a sent folder and a plain file message never take a directory',
      () async {
        final source = Directory(p.join(temp.path, 'Source'))..createSync();
        File(p.join(source.path, 'a.txt')).writeAsStringSync('a');

        await deleteReceivedMessageFile(
          _message(
            _firstId,
            content: _folderContent(),
            sender: 'local',
            receiver: 'peer-a',
            path: source.path,
          ),
          selfUid: 'local',
          path: source.path,
        );
        await deleteReceivedMessageFile(
          _message(
            _secondId,
            content: jsonEncode(
              const FileTransferV3Metadata(checksumValue: '').toJson(),
            ),
            path: source.path,
          ),
          selfUid: 'local',
          path: source.path,
        );

        expect(File(p.join(source.path, 'a.txt')).existsSync(), isTrue);
      },
    );

    if (!Platform.isWindows) {
      test('a link standing in for a received folder is left alone', () async {
        final target = Directory(p.join(temp.path, 'Target'))..createSync();
        File(p.join(target.path, 'a.txt')).writeAsStringSync('a');
        final link = Link(p.join(temp.path, 'Folder'))..createSync(target.path);

        await deleteReceivedMessageFile(
          _message(_firstId, content: _folderContent(), path: link.path),
          selfUid: 'local',
          path: link.path,
        );

        expect(File(p.join(target.path, 'a.txt')).existsSync(), isTrue);
      });
    }
  });

  group('database', () {
    test('an upgrade from schema 10 gains the skipped count', () async {
      final file = File(p.join(temp.path, 'upgrade.sqlite'));
      var database = LocalDatabase.forTesting(NativeDatabase(file));
      await database.upsertFileTransfer(
        _transfer(
          _firstId,
          direction: FileTransferDirection.incoming,
          state: FileTransferState.completed,
        ),
      );
      await database.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('ALTER TABLE file_transfer DROP COLUMN skipped_entries');
      raw.execute('PRAGMA user_version = 10');
      raw.dispose();

      database = LocalDatabase.forTesting(NativeDatabase(file));
      addTearDown(database.close);
      final kept = await database.fetchFileTransfer(_firstId);

      expect(database.schemaVersion, 11);
      expect(kept?.state, FileTransferState.completed);
      expect(kept?.skippedEntries, isNull);
      expect(database.snapshotForTransfer(kept!).skippedEntries, 0);
    });

    test(
      'going back to an older version and forward again is harmless',
      () async {
        // An older build opens a newer database as it is and stamps its own
        // version on it; the column is then already there on the way back.
        final file = File(p.join(temp.path, 'roundtrip.sqlite'));
        var database = LocalDatabase.forTesting(NativeDatabase(file));
        await database.upsertFileTransfer(
          _transfer(
            _firstId,
            direction: FileTransferDirection.incoming,
            state: FileTransferState.completed,
          ),
        );
        await database.setFileTransferSkippedEntries(_firstId, 4);
        await database.close();
        final raw = sqlite.sqlite3.open(file.path);
        raw.execute('PRAGMA user_version = 10');
        raw.dispose();

        database = LocalDatabase.forTesting(NativeDatabase(file));
        addTearDown(database.close);

        expect((await database.fetchFileTransfer(_firstId))?.skippedEntries, 4);
        final columns = await database
            .customSelect('PRAGMA table_info(file_transfer)')
            .get();
        expect(
          columns.where((row) => row.read<String>('name') == 'skipped_entries'),
          hasLength(1),
        );
      },
    );

    test('the skipped count can be set on a finished transfer', () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.upsertFileTransfer(
        _transfer(
          _firstId,
          direction: FileTransferDirection.outgoing,
          state: FileTransferState.completed,
        ),
      );

      final untouched = await database.setFileTransferSkippedEntries(
        _firstId,
        0,
      );
      final updated = await database.setFileTransferSkippedEntries(_firstId, 7);

      expect(untouched?.skippedEntries, isNull);
      expect(updated?.skippedEntries, 7);
      expect(updated?.state, FileTransferState.completed);
      expect(database.snapshotForTransfer(updated!).skippedEntries, 7);
      expect(
        await database.setFileTransferSkippedEntries(_secondId, 3),
        isNull,
      );
    });
  });

  group('wire', () {
    FileTransferV3Control control(
      FileTransferV3Action action, {
      int skippedEntries = 0,
    }) => FileTransferV3Control(
      action: action,
      transferId: _firstId,
      durableOffset: 10,
      size: 10,
      failureReason: FileTransferFailureReason.none,
      skippedEntries: skippedEntries,
    );

    test('complete carries how many files were left out', () {
      final plain = control(FileTransferV3Action.complete).toJson();
      final partial = control(
        FileTransferV3Action.complete,
        skippedEntries: 3,
      ).toJson();

      expect(plain.containsKey('skippedEntries'), isFalse);
      expect(FileTransferV3Control.fromJson(plain).skippedEntries, 0);
      expect(FileTransferV3Control.fromJson(partial).skippedEntries, 3);
    });

    test('a skipped count is refused anywhere else or when negative', () {
      final onAck = control(FileTransferV3Action.ack).toJson()
        ..['skippedEntries'] = 2;
      final negative = control(FileTransferV3Action.complete).toJson()
        ..['skippedEntries'] = -1;
      final wrongType = control(FileTransferV3Action.complete).toJson()
        ..['skippedEntries'] = '2';

      for (final json in <Map<String, dynamic>>[onAck, negative, wrongType]) {
        expect(
          () => FileTransferV3Control.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('the folder failure code survives the wire', () {
      expect(
        fileTransferFailureReasonFromWire(
          FileTransferFailureReason.folderUnsupported.wireCode,
        ),
        FileTransferFailureReason.folderUnsupported,
      );
      expect(fileTransferFailureWireCodes, contains('folder_unsupported'));
    });

    test('a folder offer has to describe a consistent folder', () {
      Map<String, dynamic> offer({Map<String, dynamic>? folder}) =>
          <String, dynamic>{
            ...jsonDecode(_folderContent()) as Map<String, dynamic>,
            'folder': ?folder,
          };
      String encoded(Map<String, dynamic> json) => jsonEncode(json);
      const size = 100 + 50 + 2 * folderTrailerLength;

      expect(
        FileTransferV3Metadata.parseOffer(
          encoded(offer()),
          size: size,
        ).isFolder,
        isTrue,
      );
      for (final bad in <Map<String, dynamic>>[
        offer()..remove('folder'),
        offer(folder: <String, dynamic>{'manifestLength': 100}),
        offer(
          folder: <String, dynamic>{
            'manifestLength': 3,
            'fileCount': 2,
            'directoryCount': 1,
            'totalBytes': 50,
          },
        ),
        offer(
          folder: <String, dynamic>{
            'manifestLength': 100,
            'fileCount': folderManifestMaxEntries,
            'directoryCount': 1,
            'totalBytes': 50,
          },
        ),
        offer()..['checksumDeferred'] = true,
        offer()..['checksumValue'] = '',
      ]) {
        expect(
          () => FileTransferV3Metadata.parseOffer(encoded(bad), size: size),
          throwsA(isA<FileTransferV3MetadataException>()),
          reason: encoded(bad),
        );
      }
      expect(
        () =>
            FileTransferV3Metadata.parseOffer(encoded(offer()), size: size + 1),
        throwsA(isA<FileTransferV3MetadataException>()),
      );
    });

    test('a single file keeps its own size limit', () {
      final content = jsonEncode(
        const FileTransferV3Metadata(
          checksumValue: '',
          checksumDeferred: true,
        ).toJson(),
      );

      expect(
        FileTransferV3Metadata.parseOffer(content, size: 5).isFolder,
        isFalse,
      );
      expect(
        () => FileTransferV3Metadata.parseOffer(
          content,
          size: fileTransferV3MaxFileSize + 1,
        ),
        throwsA(
          isA<FileTransferV3MetadataException>().having(
            (error) => error.reason,
            'reason',
            'invalid_size',
          ),
        ),
      );
    });
  });
}
