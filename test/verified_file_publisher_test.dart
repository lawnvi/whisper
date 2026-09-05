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
