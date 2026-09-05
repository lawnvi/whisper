import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/socket/file_path_policy.dart';

void main() {
  group('validateIncomingFileName', () {
    test('accepts one portable component up to 240 UTF-8 bytes', () {
      expect(validateIncomingFileName('report.pdf'), isTrue);
      expect(validateIncomingFileName('.env'), isTrue);
      expect(validateIncomingFileName('${'a' * 236}.pdf'), isTrue);
      expect(utf8.encode('${'a' * 236}.pdf'), hasLength(240));
    });

    test('rejects traversal, platform-invalid, and oversized names', () {
      final invalidNames = <String>[
        '',
        '.',
        '..',
        '../report.pdf',
        r'..\report.pdf',
        '/tmp/report.pdf',
        r'C:\temp\report.pdf',
        r'\\server\share\report.pdf',
        'nul\u0000byte',
        'control\u001fbyte',
        'delete\u007fbyte',
        'next-line\u0085byte',
        'bad<name',
        'bad>name',
        'bad:name',
        'bad"name',
        'bad|name',
        'bad?name',
        'bad*name',
        'trailing.',
        'trailing ',
        'CON',
        'con.txt',
        'PrN.log',
        'AUX',
        'nul.bin',
        'COM1.txt',
        'com9',
        'LPT1',
        'lpt9.log',
        'a' * 241,
        '文' * 81,
      ];

      for (final name in invalidNames) {
        expect(
          validateIncomingFileName(name),
          isFalse,
          reason: 'expected invalid filename: $name',
        );
      }
    });

    test('rejects malformed UTF-16 without throwing', () {
      for (final name in <String>[
        String.fromCharCode(0xd800),
        'prefix${String.fromCharCode(0xdc00)}suffix.txt',
        '${String.fromCharCode(0xd800)}${String.fromCharCode(0xd800)}',
      ]) {
        expect(
          () => validateIncomingFileName(name),
          returnsNormally,
        );
        expect(validateIncomingFileName(name), isFalse);
      }
    });
  });

  group('safeTransferTempPath', () {
    test('keeps canonical transfer ids in the transfer root', () async {
      final root = await Directory.systemTemp.createTemp('whisper-path-root-');
      addTearDown(() => root.delete(recursive: true));
      const transferId = '01234567-89ab-4cde-8fab-0123456789ab';

      final result = await safeTransferTempPath(root, transferId);
      final canonicalRoot = await root.resolveSymbolicLinks();

      expect(
        result,
        p.join(
          canonicalRoot,
          '.whisper',
          'transfers',
          '$transferId.part',
        ),
      );
      expect(p.isWithin(canonicalRoot, result), isTrue);
      expect(Directory(p.dirname(result)).existsSync(), isFalse);
    });

    test('rejects noncanonical ids and a symlinked parent outside root',
        () async {
      final root = await Directory.systemTemp.createTemp('whisper-path-root-');
      final outside =
          await Directory.systemTemp.createTemp('whisper-path-outside-');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
        if (outside.existsSync()) await outside.delete(recursive: true);
      });

      for (final id in <String>[
        '../escape',
        '01234567-89AB-4CDE-8FAB-0123456789AB',
        '01234567-89ab-4cde-8fab-0123456789ab.part',
      ]) {
        await expectLater(
          safeTransferTempPath(root, id),
          throwsFormatException,
        );
      }

      await Link(p.join(root.path, '.whisper')).create(outside.path);
      await expectLater(
        safeTransferTempPath(
          root,
          '01234567-89ab-4cde-8fab-0123456789ab',
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('rejects an existing candidate symlink before it can be opened',
        () async {
      final root = await Directory.systemTemp.createTemp('whisper-path-root-');
      final outside =
          await Directory.systemTemp.createTemp('whisper-path-outside-');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
        if (outside.existsSync()) await outside.delete(recursive: true);
      });
      const transferId = '01234567-89ab-4cde-8fab-0123456789ab';
      final transferRoot = Directory(
        p.join(root.path, '.whisper', 'transfers'),
      );
      await transferRoot.create(recursive: true);
      final outsideFile = File(p.join(outside.path, 'outside.bin'));
      await outsideFile.writeAsString('outside');
      await Link(
        p.join(transferRoot.path, '$transferId.part'),
      ).create(outsideFile.path);

      await expectLater(
        safeTransferTempPath(root, transferId),
        throwsA(isA<FileSystemException>()),
      );
      expect(await outsideFile.readAsString(), 'outside');

      final candidate = Link(
        p.join(transferRoot.path, '$transferId.part'),
      );
      await candidate.delete();
      await Directory(candidate.path).create();
      await expectLater(
        safeTransferTempPath(root, transferId),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  test('exclusive reservations preserve existing files and publish only once',
      () async {
    final root = await Directory.systemTemp.createTemp('whisper-publish-root-');
    addTearDown(() => root.delete(recursive: true));
    final original = File(p.join(root.path, 'report.pdf'));
    await original.writeAsString('original');

    final reservations = await Future.wait(<Future<DownloadFileReservation>>[
      reserveUniqueDownloadFile(root, 'report.pdf'),
      reserveUniqueDownloadFile(root, 'report.pdf'),
    ]);

    expect(
      reservations.map((item) => p.basename(item.path)).toSet(),
      <String>{'report-1.pdf', 'report-2.pdf'},
    );
    expect(await original.readAsString(), 'original');

    final temp = File(p.join(root.path, 'verified.part'));
    await temp.writeAsString('verified payload');
    final published = await publishTempWithoutOverwrite(
      temp,
      reservations.first,
    );
    await releaseDownloadReservation(reservations.first);

    expect(await published.readAsString(), 'verified payload');
    expect(temp.existsSync(), isTrue);
    expect(await original.readAsString(), 'original');
    await expectLater(
      publishTempWithoutOverwrite(
        File(p.join(root.path, 'another.part')),
        reservations.first,
      ),
      throwsStateError,
    );
    await discardDownloadReservation(reservations.last);
  });

  test('published file metadata can be prepared while reservation is held',
      () async {
    final root = await Directory.systemTemp.createTemp('whisper-metadata-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final bytes = utf8.encode('verified payload');
    final temp = File(p.join(root.path, 'verified.part'));
    await temp.writeAsBytes(bytes);
    final snapshot = await VerifiedTransferSnapshot.open(
      temp,
      expectedSize: bytes.length,
      expectedSha256: sha256.convert(bytes).toString(),
    );
    final reservation = await reserveUniqueDownloadFile(root, 'report.pdf');
    final modified = DateTime.utc(2024, 1, 2, 3, 4, 5);

    try {
      final published = await publishVerifiedSnapshot(
        snapshot,
        reservation,
        preparePublishedFile: (file) => file.setLastModified(modified),
      );

      expect(
        (await published.stat()).modified.millisecondsSinceEpoch,
        modified.millisecondsSinceEpoch,
      );
    } finally {
      await snapshot.close();
      await discardDownloadReservation(reservation);
    }
  });

  test('replacement after reservation is never overwritten or deleted',
      () async {
    final root = await Directory.systemTemp.createTemp('whisper-replace-');
    addTearDown(() => root.delete(recursive: true));
    final reservation = await reserveUniqueDownloadFile(root, 'report.pdf');
    final detached = p.join(root.path, 'detached-reservation');
    if (Platform.isWindows) {
      await expectLater(
        File(reservation.path).rename(detached),
        throwsA(isA<FileSystemException>()),
      );
      await discardDownloadReservation(reservation);
      expect(await File(detached).exists(), isFalse);
      expect(await File(reservation.path).exists(), isFalse);
      return;
    }
    await File(reservation.path).rename(detached);
    final replacement = File(reservation.path);
    await replacement.writeAsString('replacement');
    final temp = File(p.join(root.path, 'verified.part'));
    await temp.writeAsString('verified payload');

    await expectLater(
      publishTempWithoutOverwrite(temp, reservation),
      throwsA(isA<FileSystemException>()),
    );
    expect(await replacement.readAsString(), 'replacement');

    await discardDownloadReservation(reservation);
    expect(await replacement.readAsString(), 'replacement');
  });

  test('discard never deletes a replacement installed after publication',
      () async {
    final root =
        await Directory.systemTemp.createTemp('whisper-discard-replace-');
    addTearDown(() => root.delete(recursive: true));
    final reservation = await reserveUniqueDownloadFile(root, 'report.pdf');
    final temp = File(p.join(root.path, 'verified.part'));
    await temp.writeAsString('verified payload');
    await publishTempWithoutOverwrite(temp, reservation);
    if (Platform.isWindows) {
      await expectLater(
        File(
          reservation.path,
        ).rename(p.join(root.path, 'detached-published-file')),
        throwsA(isA<FileSystemException>()),
      );
      await discardDownloadReservation(reservation);
      expect(await File(reservation.path).exists(), isFalse);
      expect(await temp.readAsString(), 'verified payload');
      return;
    }
    await File(reservation.path).rename(
      p.join(root.path, 'detached-published-file'),
    );
    final replacement = File(reservation.path);
    await replacement.writeAsString('replacement');

    await discardDownloadReservation(reservation);

    expect(await replacement.readAsString(), 'replacement');
  });

  test('a hard-linked reservation is rejected before publication', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('whisper-hardlink-');
    addTearDown(() => root.delete(recursive: true));
    final reservation = await reserveUniqueDownloadFile(root, 'report.pdf');
    final alias = p.join(root.path, 'reservation-alias');
    final linkResult = await Process.run('ln', <String>[
      reservation.path,
      alias,
    ]);
    expect(linkResult.exitCode, 0);
    final before = await File(alias).readAsBytes();
    final temp = File(p.join(root.path, 'verified.part'));
    await temp.writeAsString('verified payload');

    await expectLater(
      publishTempWithoutOverwrite(temp, reservation),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File(alias).readAsBytes(), before);
    await discardDownloadReservation(reservation);
    expect(await File(alias).readAsBytes(), before);
  });

  test('verified snapshot rejects a path swap before publication', () async {
    final root = await Directory.systemTemp.createTemp('whisper-snapshot-');
    addTearDown(() => root.delete(recursive: true));
    final temp = File(p.join(root.path, 'transfer.part'));
    await temp.writeAsString('verified payload');
    final snapshot = await VerifiedTransferSnapshot.open(
      temp,
      expectedSize: 16,
      expectedSha256:
          '3aac0a1146ffe55bac7c05f61401fb1e7e4e6a94110b91585c646fe8cf745f28',
    );
    final original = File(p.join(root.path, 'original.part'));
    if (Platform.isWindows) {
      await expectLater(
        temp.rename(original.path),
        throwsA(isA<FileSystemException>()),
      );
      await snapshot.close();
      expect(await temp.readAsString(), 'verified payload');
      expect(await original.exists(), isFalse);
      return;
    }
    await temp.rename(original.path);
    await temp.writeAsString('malicious bytes!');
    final reservation = await reserveUniqueDownloadFile(root, 'report.pdf');

    await expectLater(
      publishVerifiedSnapshot(snapshot, reservation),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(reservation.path).existsSync(), isTrue);
    expect(await File(reservation.path).length(), isNot(16));
    await snapshot.close();
    await discardDownloadReservation(reservation);
  });

  test('verified snapshot rejects truncation after hashing', () async {
    final root = await Directory.systemTemp.createTemp('whisper-truncate-');
    addTearDown(() => root.delete(recursive: true));
    final temp = File(p.join(root.path, 'transfer.part'));
    await temp.writeAsString('verified payload');
    final snapshot = await VerifiedTransferSnapshot.open(
      temp,
      expectedSize: 16,
      expectedSha256:
          '3aac0a1146ffe55bac7c05f61401fb1e7e4e6a94110b91585c646fe8cf745f28',
    );
    await temp.writeAsString('short', mode: FileMode.write);
    final reservation = await reserveUniqueDownloadFile(root, 'report.pdf');

    await expectLater(
      publishVerifiedSnapshot(snapshot, reservation),
      throwsA(isA<FileSystemException>()),
    );
    await snapshot.close();
    await discardDownloadReservation(reservation);
  });

  test('flush failure discards only the reservation-owned partial target',
      () async {
    final root = await Directory.systemTemp.createTemp('whisper-flush-fail-');
    addTearDown(() => root.delete(recursive: true));
    final temp = File(p.join(root.path, 'transfer.part'));
    await temp.writeAsString('verified payload');
    final snapshot = await VerifiedTransferSnapshot.open(
      temp,
      expectedSize: 16,
      expectedSha256:
          '3aac0a1146ffe55bac7c05f61401fb1e7e4e6a94110b91585c646fe8cf745f28',
    );
    final reservation = await reserveUniqueDownloadFile(root, 'report.pdf');

    await expectLater(
      publishVerifiedSnapshot(
        snapshot,
        reservation,
        flushReservation: (_) async {
          throw const FileSystemException('injected flush failure');
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(reservation.path).existsSync(), isTrue);
    await discardDownloadReservation(reservation);
    expect(File(reservation.path).existsSync(), isFalse);
    expect(await temp.readAsString(), 'verified payload');
    await snapshot.close();
  });

  test('flush failure never deletes a replacement path', () async {
    final root =
        await Directory.systemTemp.createTemp('whisper-flush-replace-');
    addTearDown(() => root.delete(recursive: true));
    final temp = File(p.join(root.path, 'transfer.part'));
    await temp.writeAsString('verified payload');
    final snapshot = await VerifiedTransferSnapshot.open(
      temp,
      expectedSize: 16,
      expectedSha256:
          '3aac0a1146ffe55bac7c05f61401fb1e7e4e6a94110b91585c646fe8cf745f28',
    );
    final reservation = await reserveUniqueDownloadFile(root, 'report.pdf');
    final replacement = File(reservation.path);

    await expectLater(
      publishVerifiedSnapshot(
        snapshot,
        reservation,
        flushReservation: (_) async {
          await replacement.rename(p.join(root.path, 'detached-partial'));
          await replacement.writeAsString('replacement');
          throw const FileSystemException('injected flush failure');
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    await discardDownloadReservation(reservation);
    if (Platform.isWindows) {
      // Windows rejects the replacement rename while our handle is open.
      expect(await replacement.exists(), isFalse);
      expect(
        await File(p.join(root.path, 'detached-partial')).exists(),
        isFalse,
      );
      expect(await temp.readAsString(), 'verified payload');
    } else {
      expect(await replacement.readAsString(), 'replacement');
    }
    await snapshot.close();
  });
}
