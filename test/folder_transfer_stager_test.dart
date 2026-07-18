import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/folder_transfer_stager.dart';

void main() {
  test('stages a folder without following symbolic links', () async {
    final root = await Directory.systemTemp.createTemp('whisper-folder-test-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory(p.join(root.path, 'Project'))
      ..createSync(recursive: true);
    Directory(p.join(source.path, 'nested')).createSync();
    File(p.join(source.path, 'note.txt')).writeAsStringSync('hello');
    File(p.join(source.path, 'nested', 'data.txt')).writeAsStringSync('world');
    if (!Platform.isWindows) {
      Link(p.join(source.path, 'outside-link')).createSync(root.path);
    }
    final staging = Directory(p.join(root.path, 'staging'));

    final result = await FolderTransferStager(
      stagingDirectoryProvider: () async => staging,
    ).stage(source.path);
    final archive = ZipDecoder().decodeStream(
      InputFileStream(result.archiveFile.path),
    );
    final names = archive.files.map((entry) => entry.name).toSet();

    expect(result.archiveFile.path, endsWith('.zip'));
    expect(names, contains('Project/note.txt'));
    expect(names, contains('Project/nested/data.txt'));
    expect(names.any((name) => name.contains('outside-link')), isFalse);
  });

  test('rejects a missing source folder', () async {
    final root = await Directory.systemTemp.createTemp('whisper-folder-test-');
    addTearDown(() => root.delete(recursive: true));

    await expectLater(
      FolderTransferStager(
        stagingDirectoryProvider: () async => Directory(root.path),
      ).stage(p.join(root.path, 'missing')),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'excludes staging storage when it is nested inside the source',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'whisper-folder-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = Directory(p.join(root.path, 'Project'))
        ..createSync(recursive: true);
      File(p.join(source.path, 'note.txt')).writeAsStringSync('hello');
      final staging = Directory(p.join(source.path, '.whisper-staging'));

      final result = await FolderTransferStager(
        stagingDirectoryProvider: () async => staging,
      ).stage(source.path);
      final archive = ZipDecoder().decodeStream(
        InputFileStream(result.archiveFile.path),
      );

      expect(
        archive.files.any((entry) => entry.name.contains('.whisper-staging')),
        isFalse,
      );
      expect(
        archive.files.map((entry) => entry.name),
        contains('Project/note.txt'),
      );
    },
  );

  test('canonical paths reject a source hidden inside staging', () async {
    if (Platform.isWindows) {
      return;
    }
    final root = await Directory.systemTemp.createTemp('whisper-folder-test-');
    addTearDown(() => root.delete(recursive: true));
    final realRoot = Directory(p.join(root.path, 'real'))
      ..createSync(recursive: true);
    final staging = Directory(p.join(realRoot.path, 'staging'))
      ..createSync(recursive: true);
    final source = Directory(p.join(staging.path, 'Project'))
      ..createSync(recursive: true);
    final alias = Link(p.join(root.path, 'alias'))..createSync(realRoot.path);
    final aliasedSource = p.join(alias.path, 'staging', 'Project');

    await expectLater(
      FolderTransferStager(
        stagingDirectoryProvider: () async => staging,
      ).stage(aliasedSource),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.existsSync(), isTrue);
  });

  test('concurrent staging uses distinct archive paths', () async {
    final root = await Directory.systemTemp.createTemp('whisper-folder-test-');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory(p.join(root.path, 'Project'))
      ..createSync(recursive: true);
    File(p.join(source.path, 'note.txt')).writeAsStringSync('hello');
    final staging = Directory(p.join(root.path, 'staging'));
    final stager = FolderTransferStager(
      stagingDirectoryProvider: () async => staging,
    );

    final archives = await Future.wait(<Future<StagedTransferFolder>>[
      stager.stage(source.path),
      stager.stage(source.path),
    ]);

    expect(archives.map((item) => item.archiveFile.path).toSet(), hasLength(2));
    expect(archives.every((item) => item.archiveFile.existsSync()), isTrue);
  });

  test(
    'stale cleanup preserves archives used by recoverable transfers',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'whisper-folder-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = Directory(p.join(root.path, 'Project'))
        ..createSync(recursive: true);
      File(p.join(source.path, 'note.txt')).writeAsStringSync('hello');
      final staging = Directory(p.join(root.path, 'staging'))
        ..createSync(recursive: true);
      final activeArchive = File(p.join(staging.path, 'active.zip'))
        ..writeAsBytesSync(<int>[1]);
      final expiredArchive = File(p.join(staging.path, 'expired.zip'))
        ..writeAsBytesSync(<int>[2]);
      final staleTime = DateTime.now().subtract(const Duration(days: 8));
      activeArchive.setLastModifiedSync(staleTime);
      expiredArchive.setLastModifiedSync(staleTime);

      await FolderTransferStager(
        stagingDirectoryProvider: () async => staging,
        activeTransferPathsProvider: () async => <String>{activeArchive.path},
      ).stage(source.path);

      expect(activeArchive.existsSync(), isTrue);
      expect(expiredArchive.existsSync(), isFalse);
    },
  );

  test(
    'stale cleanup preserves a staged archive before durable admission',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'whisper-folder-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = Directory(p.join(root.path, 'Project'))
        ..createSync(recursive: true);
      File(p.join(source.path, 'note.txt')).writeAsStringSync('hello');
      final staging = Directory(p.join(root.path, 'staging'));
      final stager = FolderTransferStager(
        stagingDirectoryProvider: () async => staging,
        activeTransferPathsProvider: () async => const <String>{},
      );
      final staged = await stager.stage(source.path);
      staged.archiveFile.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 8)),
      );

      await stager.cleanup();

      expect(staged.archiveFile.existsSync(), isTrue);
      expect(
        await releaseStagedFolderTransferArchive(
          staged.archiveFile.path,
          stagingDirectoryProvider: () async => staging,
        ),
        isTrue,
      );
    },
  );

  test(
    'terminal cleanup deletes only archives inside managed staging',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'whisper-folder-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final staging = Directory(p.join(root.path, 'staging'))
        ..createSync(recursive: true);
      final managed = File(p.join(staging.path, 'managed.zip'))
        ..writeAsBytesSync(<int>[1]);
      final outside = File(p.join(root.path, 'outside.zip'))
        ..writeAsBytesSync(<int>[2]);

      expect(
        await releaseStagedFolderTransferArchive(
          outside.path,
          stagingDirectoryProvider: () async => staging,
        ),
        isFalse,
      );
      expect(outside.existsSync(), isTrue);
      expect(
        await releaseStagedFolderTransferArchive(
          managed.path,
          stagingDirectoryProvider: () async => staging,
        ),
        isTrue,
      );
      expect(managed.existsSync(), isFalse);
    },
  );

  test(
    'unowned cleanup preserves a path claimed by a durable transfer',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'whisper-folder-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final staging = Directory(p.join(root.path, 'staging'))
        ..createSync(recursive: true);
      final managed = File(p.join(staging.path, 'managed.zip'))
        ..writeAsBytesSync(<int>[1]);

      expect(
        await releaseUnownedStagedFolderTransferArchive(
          managed.path,
          stagingDirectoryProvider: () async => staging,
          retainedTransferPathsProvider: () async => <String>{managed.path},
        ),
        isFalse,
      );
      expect(managed.existsSync(), isTrue);
    },
  );
}
