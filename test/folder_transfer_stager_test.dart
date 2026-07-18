import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/folder_transfer_stager.dart';

void main() {
  test(
    'legacy cleanup removes stale archives but keeps active transfers',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'whisper-folder-cleanup-',
      );
      addTearDown(() => root.delete(recursive: true));
      final active = File(p.join(root.path, 'active.zip'))
        ..writeAsStringSync('active');
      final orphan = File(p.join(root.path, 'orphan.zip'))
        ..writeAsStringSync('orphan');
      final staleTime = DateTime.now().subtract(const Duration(days: 1));
      active.setLastModifiedSync(staleTime);
      orphan.setLastModifiedSync(staleTime);

      await LegacyFolderTransferCleanup(
        stagingDirectoryProvider: () async => root,
        activeTransferPathsProvider: () async => <String>{active.path},
      ).cleanup();

      expect(active.existsSync(), isTrue);
      expect(orphan.existsSync(), isFalse);
    },
  );

  test('legacy release deletes only archives inside managed storage', () async {
    final root = await Directory.systemTemp.createTemp(
      'whisper-folder-release-',
    );
    addTearDown(() => root.delete(recursive: true));
    final staging = Directory(p.join(root.path, 'staging'))..createSync();
    final managed = File(p.join(staging.path, 'managed.zip'))
      ..writeAsStringSync('managed');
    final outside = File(p.join(root.path, 'outside.zip'))
      ..writeAsStringSync('outside');

    expect(
      await releaseStagedFolderTransferArchive(
        managed.path,
        stagingDirectoryProvider: () async => staging,
      ),
      isTrue,
    );
    expect(
      await releaseStagedFolderTransferArchive(
        outside.path,
        stagingDirectoryProvider: () async => staging,
      ),
      isFalse,
    );
    expect(managed.existsSync(), isFalse);
    expect(outside.existsSync(), isTrue);
  });
}
