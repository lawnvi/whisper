import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/atomic_file_move.dart';
import 'package:whisper/helper/exclusive_file_link.dart';
import 'package:whisper/socket/verified_file_publisher.dart';

void main() {
  late Directory root;
  late File source;
  late VerifiedTransferSnapshot snapshot;
  final bytes = List<int>.generate(4096, (index) => index & 255);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('whisper-fast-publish-');
    source = File(p.join(root.path, 'received.part'));
    await source.writeAsBytes(bytes, flush: true);
    snapshot = await VerifiedTransferSnapshot.openFromStreamingDigest(
      source,
      expectedSize: bytes.length,
      streamingSha256: sha256.convert(bytes).toString(),
    );
  });
  tearDown(() async {
    await snapshot.close();
    await root.delete(recursive: true);
  });

  group('a download that takes its final name', () {
    final modified = DateTime.utc(2026, 10, 12);
    _Stat stat(int mode, {int size = 4096, DateTime? at}) =>
        _Stat(mode: mode, size: size, modified: at ?? modified);
    // What Windows reports for the same file as received.part and as an .exe.
    const plain = 0x81b6; // 0o100666
    const executable = 0x81ff; // 0o100777
    const readOnly = 0x8124; // 0o100444

    test('is the same file on Windows when only the extension changed', () {
      expect(
        sameFileContentAcrossRename(
          stat(plain),
          stat(executable),
          executeBitsFollowName: true,
        ),
        isTrue,
      );
      expect(
        sameFileContentAcrossRename(
          stat(executable),
          stat(plain),
          executeBitsFollowName: true,
        ),
        isTrue,
      );
    });

    test('is still rejected on Windows when the file itself changed', () {
      for (final moved in <_Stat>[
        stat(readOnly),
        stat(executable, size: 4097),
        stat(executable, at: modified.add(const Duration(seconds: 2))),
      ]) {
        expect(
          sameFileContentAcrossRename(
            stat(plain),
            moved,
            executeBitsFollowName: true,
          ),
          isFalse,
        );
      }
    });

    test('keeps its execute bits where they are a real permission', () {
      expect(
        sameFileContentAcrossRename(
          stat(plain),
          stat(executable),
          executeBitsFollowName: false,
        ),
        isFalse,
      );
      expect(
        sameFileContentAcrossRename(
          stat(plain),
          stat(plain),
          executeBitsFollowName: false,
        ),
        isTrue,
      );
    });

    test('is how the fast path compares the two names', () {
      final source = File(
        'lib/socket/verified_file_publisher.dart',
      ).readAsStringSync();
      final publish = RegExp(
        r'Future<DownloadFileReservation> publishVerifiedDownload\([\s\S]*?\n\}\n',
      ).firstMatch(source)!.group(0)!;
      expect(
        'sameFileContentAcrossRename(snapshot._pathStat, movedStat)'.allMatches(
          publish,
        ),
        hasLength(2),
      );
      expect(
        publish,
        isNot(contains('_sameFileContentStat(snapshot._pathStat, movedStat)')),
      );
    });
  });

  test('a download named like a Windows program is published', () async {
    final reservation = await publishVerifiedDownload(
      snapshot,
      root,
      'installer.exe',
    );
    // Windows holds the reservation's lock against every other reader.
    await releaseDownloadReservation(reservation);

    expect(p.basename(reservation.path), 'installer.exe');
    expect(await File(reservation.path).readAsBytes(), bytes);
    // A move takes the source with it; Windows publishes through a hard
    // link instead and leaves the source for the caller to remove.
    expect(await source.exists(), !reservation.sourceWasMoved);
  });

  test('unsupported moves fall back to the verified copy path', () async {
    final reservation = await publishVerifiedDownload(
      snapshot,
      root,
      'result.bin',
      atomicMove: (_, __) => AtomicFileMoveResult.unavailable,
      atomicLink: (_, __) => ExclusiveFileLinkResult.unavailable,
    );
    await releaseDownloadReservation(reservation);
    expect(reservation.sourceWasMoved, isFalse);
    expect(await source.readAsBytes(), bytes);
    expect(await File(reservation.path).readAsBytes(), bytes);
  });

  test(
    'copy preparation failure removes the locked partial destination',
    () async {
      await expectLater(
        publishVerifiedDownload(
          snapshot,
          root,
          'result.bin',
          atomicMove: (_, __) => AtomicFileMoveResult.unavailable,
          atomicLink: (_, __) => ExclusiveFileLinkResult.unavailable,
          preparePublishedFile: (_) =>
              throw const FileSystemException('timestamp failed'),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(p.join(root.path, 'result.bin')).exists(), isFalse);
      expect(await source.readAsBytes(), bytes);
    },
  );

  group('Windows hard-link publication', () {
    test(
      'keeps a colliding Unicode filename and avoids a second copy',
      () async {
        final existing = File(p.join(root.path, '校验.bin'));
        await existing.writeAsString('keep');
        final reservation = await publishVerifiedDownload(
          snapshot,
          root,
          '校验.bin',
        );
        expect(reservation.sourceWasLinked, isTrue);
        expect(reservation.sourceWasMoved, isFalse);
        expect(p.basename(reservation.path), '校验-1.bin');
        expect(
          await FileSystemEntity.identical(source.path, reservation.path),
          isTrue,
        );
        await releaseDownloadReservation(reservation);
        await snapshot.close();
        await source.delete();
        expect(await existing.readAsString(), 'keep');
        expect(await File(reservation.path).readAsBytes(), bytes);
      },
    );

    test(
      'rollback removes only the final link and restores the timestamp',
      () async {
        final modified = await source.lastModified();
        final reservation = await publishVerifiedDownload(
          snapshot,
          root,
          'result.bin',
          preparePublishedFile: (file) => file.setLastModified(DateTime(2020)),
        );
        expect(reservation.sourceWasLinked, isTrue);
        await discardDownloadReservation(reservation);
        expect(await source.readAsBytes(), bytes);
        expect(await source.lastModified(), modified);
        expect(await File(reservation.path).exists(), isFalse);
      },
    );

    test(
      'timestamp failure releases both handles and retains the source',
      () async {
        await expectLater(
          publishVerifiedDownload(
            snapshot,
            root,
            'result.bin',
            preparePublishedFile: (_) =>
                throw const FileSystemException('timestamp failed'),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await source.readAsBytes(), bytes);
        expect(await File(p.join(root.path, 'result.bin')).exists(), isFalse);
      },
    );
  }, skip: !Platform.isWindows);

  group('exclusive move', () {
    test(
      'preserves occupied names and dangling links without a second copy',
      () async {
        final existing = File(p.join(root.path, 'result.bin'));
        await existing.writeAsString('keep');
        final link = Link(p.join(root.path, 'result-1.bin'));
        await link.create(p.join(root.path, 'missing'));
        final reservation = await publishVerifiedDownload(
          snapshot,
          root,
          'result.bin',
        );
        await releaseDownloadReservation(reservation);
        expect(reservation.sourceWasMoved, isTrue);
        expect(p.basename(reservation.path), 'result-2.bin');
        expect(await source.exists(), isFalse);
        expect(await File(reservation.path).readAsBytes(), bytes);
        expect(await existing.readAsString(), 'keep');
        expect(await link.exists(), isTrue);
      },
    );

    test(
      'discard restores the source and its timestamp after preparation',
      () async {
        final modified = await source.lastModified();
        final reservation = await publishVerifiedDownload(
          snapshot,
          root,
          'result.bin',
          preparePublishedFile: (file) => file.setLastModified(DateTime(2020)),
        );
        await discardDownloadReservation(reservation);
        expect(await source.readAsBytes(), bytes);
        expect(await source.lastModified(), modified);
        expect(await File(reservation.path).exists(), isFalse);
      },
    );

    test('rollback never overwrites a recreated source', () async {
      final reservation = await publishVerifiedDownload(
        snapshot,
        root,
        'result.bin',
      );
      await source.writeAsString('new owner');
      await discardDownloadReservation(reservation);
      expect(await source.readAsString(), 'new owner');
      expect(await File(reservation.path).readAsBytes(), bytes);
    });

    test('discard leaves a replaced destination untouched', () async {
      final reservation = await publishVerifiedDownload(
        snapshot,
        root,
        'result.bin',
      );
      final published = File(reservation.path);
      await published.delete();
      await published.writeAsString('new owner');
      await discardDownloadReservation(reservation);
      expect(await published.readAsString(), 'new owner');
      expect(await source.exists(), isFalse);
    });

    test('rejects a changed source before moving it', () async {
      await source.writeAsString('changed');
      await expectLater(
        publishVerifiedDownload(snapshot, root, 'result.bin'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(p.join(root.path, 'result.bin')).exists(), isFalse);
    });

    test('native move keeps both files on a destination collision', () async {
      final destination = File(p.join(root.path, 'existing'));
      await destination.writeAsString('keep');
      expect(
        moveFileWithoutOverwrite(source.path, destination.path),
        AtomicFileMoveResult.destinationExists,
      );
      expect(await source.readAsBytes(), bytes);
      expect(await destination.readAsString(), 'keep');
    });
  }, skip: !Platform.isMacOS && !Platform.isLinux);
}

final class _Stat implements FileStat {
  _Stat({required this.mode, required this.size, required this.modified});

  @override
  final int mode;
  @override
  final int size;
  @override
  final DateTime modified;
  @override
  FileSystemEntityType get type => FileSystemEntityType.file;
  @override
  DateTime get changed => modified;
  @override
  DateTime get accessed => modified;
  @override
  String modeString() => mode.toRadixString(8);
}
