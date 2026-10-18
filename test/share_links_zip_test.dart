import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/share_links/share_link.dart';
import 'package:whisper/share_links/share_paths.dart';
import 'package:whisper/share_links/share_zip.dart';

/// Python's zipfile reads the central directory, checks every CRC and
/// prints name, size and CRC per entry.
const _pythonCheck = r'''
import sys, zipfile, zlib
with zipfile.ZipFile(sys.argv[1]) as z:
    bad = z.testzip()
    if bad is not None:
        print("BAD", bad); sys.exit(2)
    for info in z.infolist():
        data = z.read(info)
        print("%s\t%d\t%08x\t%08x" % (info.filename, info.file_size, info.CRC, zlib.crc32(data) & 0xffffffff))
''';

/// The Python on PATH (Windows has no `python3` outside its Store stub).
final _python = Platform.isWindows ? 'python' : 'python3';

/// Runs a checker; null when it is not installed. Output is decoded
/// leniently (unzip prints names in whatever form it likes).
Future<({int exitCode, String stdout, String stderr})?> _run(
  String executable,
  List<String> arguments,
) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      stdoutEncoding: null,
      stderrEncoding: null,
      environment: const {'PYTHONIOENCODING': 'utf-8', 'LC_ALL': 'C.UTF-8'},
    );
    String text(Object? bytes) =>
        utf8.decode(bytes as List<int>, allowMalformed: true);
    return (
      exitCode: result.exitCode,
      stdout: text(result.stdout),
      stderr: text(result.stderr),
    );
  } on ProcessException {
    return null;
  }
}

void main() {
  test('CRC-32 matches the standard check value', () {
    expect(ShareCrc32.of(ascii.encode('123456789')), 0xCBF43926);
    expect(ShareCrc32.of(const []), 0);
    final data = Uint8List.fromList(List.generate(100003, (i) => i * 7 & 0xff));
    final whole = ShareCrc32.of(data);
    final pieces = ShareCrc32()
      ..add(data.sublist(0, 5))
      ..add(data.sublist(5, 70001))
      ..add(data.sublist(70001));
    expect(pieces.value, whole);
  });

  group('streamed zip', () {
    late Directory temp;
    late String tree;
    late Map<String, List<int>> contents;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('share_zip_');
      tree = p.join(await temp.resolveSymbolicLinks(), '旅行 Photos');
      contents = {
        'a.txt': utf8.encode('hello'),
        '空文件.txt': const [],
        'sub/data.bin': List<int>.generate(
          1 << 20,
          (i) => Random(i ~/ 4096).nextInt(256),
        ),
        'sub/deeper/número 2.md': utf8.encode('# ¡Hola!\n'),
      };
      for (final entry in contents.entries) {
        final file = File(p.joinAll([tree, ...entry.key.split('/')]));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value);
      }
      await Directory(p.join(tree, 'empty folder')).create();
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    Future<File> writeZip({bool forceZip64 = false}) async {
      final link = ShareLink(
        id: 'zip000000000',
        route: 'zipt',
        name: 'zip',
        items: [ShareItem(path: tree, name: p.basename(tree), isDir: true)],
        createdAt: DateTime(2026),
      );
      final plan = await ShareZipPlan.plan(
        const ShareResolver().zipSource(link),
        forceZip64: forceZip64,
      );
      final out = File(p.join(temp.path, forceZip64 ? 'z64.zip' : 'z.zip'));
      final sink = out.openWrite();
      var counted = 0;
      await sink.addStream(plan.stream(onBytes: (n) => counted += n));
      await sink.close();
      expect(await out.length(), plan.length, reason: 'planned length');
      expect(counted, plan.length);
      return out;
    }

    Future<void> verify(File zip) async {
      final python = await _run(_python, ['-c', _pythonCheck, zip.path]);
      if (python == null) {
        markTestSkipped('python3 not available');
        return;
      }
      expect(python.exitCode, 0, reason: '${python.stdout}${python.stderr}');
      final lines = python.stdout
          .trim()
          .split('\n')
          .map((line) => line.trimRight().split('\t'))
          .toList();
      final byName = {for (final l in lines) l[0]: l};
      final top = p.basename(tree);
      expect(byName.keys, contains('$top/'));
      expect(byName.keys, contains('$top/empty folder/'));
      for (final entry in contents.entries) {
        final line = byName['$top/${entry.key}'];
        expect(line, isNotNull, reason: entry.key);
        expect(int.parse(line![1]), entry.value.length);
        // The CRC in the directory is the CRC of the bytes.
        expect(line[2], line[3]);
        expect(
          int.parse(line[2], radix: 16),
          ShareCrc32.of(entry.value),
          reason: entry.key,
        );
      }
      final unzip = await _run('unzip', ['-t', zip.path]);
      if (unzip != null) {
        expect(unzip.exitCode, 0, reason: '${unzip.stdout}${unzip.stderr}');
        expect(unzip.stdout, contains('No errors detected'));
      }
    }

    test('is a valid zip whose CRCs match the files', () async {
      await verify(await writeZip());
    });

    test('with ZIP64 records throughout it still reads back', () async {
      await verify(await writeZip(forceZip64: true));
    });

    test('a file that grows while zipping cuts the stream', () async {
      final path = p.join(tree, 'a.txt');
      final plan = ShareZipPlan.of([
        ShareZipEntry.file('a.txt', path, 5, DateTime(2026)),
      ]);
      await File(path).writeAsString('hello, longer now');
      expect(
        plan.stream().drain<void>(),
        throwsA(isA<ShareZipChangedException>()),
      );
    });

    test('a tree that changes between passes cuts the stream', () async {
      final path = p.join(tree, 'a.txt');
      var calls = 0;
      Stream<ShareZipEntry> source() {
        calls++;
        return Stream.fromIterable([
          ShareZipEntry.file('a.txt', path, 5, DateTime(2026)),
          // Gone on the last pass, the one writing the directory.
          if (calls < 3) ShareZipEntry.file('b.txt', path, 5, DateTime(2026)),
        ]);
      }

      final plan = await ShareZipPlan.plan(source);
      expect(plan.count, 2);
      await expectLater(
        plan.stream().drain<void>(),
        throwsA(isA<ShareZipChangedException>()),
      );
    });

    test('a zip of too many entries is refused before anything is sent', () {
      Stream<ShareZipEntry> source() => Stream.fromIterable([
        for (var i = 0; i < 5; i++)
          ShareZipEntry.folder('d$i/', DateTime(2026)),
      ]);
      expect(
        ShareZipPlan.plan(source, maxEntries: 4),
        throwsA(isA<ShareZipTooLargeException>()),
      );
    });

    test('backslashes in names cannot become folders on Windows', () async {
      if (Platform.isWindows) {
        markTestSkipped('Windows names cannot hold a backslash');
        return;
      }
      await File(p.join(tree, r'back\slash.txt')).writeAsString('x');
      final link = ShareLink(
        id: 'zip000000000',
        route: 'zipt',
        name: 'zip',
        items: [ShareItem(path: tree, name: p.basename(tree), isDir: true)],
        createdAt: DateTime(2026),
      );
      final names = await const ShareResolver()
          .zipSource(link)()
          .map((e) => e.name)
          .toList();
      expect(names, contains('${p.basename(tree)}/back_slash.txt'));
      expect(names.where((n) => n.contains('\\')), isEmpty);
      expect(shareZipSegment(r'a\b\c'), 'a_b_c');
    });

    test('plans past 4 GiB and 65535 entries switch to ZIP64', () {
      final big = ShareZipPlan.of([
        ShareZipEntry.file('big.iso', '/nowhere', 5 << 30, DateTime(2026)),
      ]);
      // local header + zip64 extra, data, 24-byte descriptor, central
      // header with sizes in the extra, zip64 end record and locator, end.
      expect(
        big.length,
        (30 + 7 + 20) + (5 << 30) + 24 + (46 + 7 + 20) + 76 + 22,
      );
      final many = ShareZipPlan.of([
        for (var i = 0; i < 70000; i++)
          ShareZipEntry.folder('d$i/', DateTime(2026)),
      ]);
      expect(many.length, greaterThan(70000 * (30 + 46)));
    });
  });

  test('70000 entries stream into a zip that reads back', () async {
    final entries = [
      for (var i = 0; i < 70000; i++)
        ShareZipEntry.folder(
          'f${i.toString().padLeft(5, '0')}/',
          DateTime(2026),
        ),
    ];
    final plan = ShareZipPlan.of(entries);
    final temp = await Directory.systemTemp.createTemp('share_zip_many_');
    try {
      final out = File(p.join(temp.path, 'many.zip'));
      final sink = out.openWrite();
      await sink.addStream(plan.stream());
      await sink.close();
      expect(await out.length(), plan.length);
      final python = await _run(_python, [
        '-c',
        'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); '
            'print(len(z.infolist()), z.testzip())',
        out.path,
      ]);
      if (python == null) {
        markTestSkipped('python3 not available');
        return;
      }
      expect(python.exitCode, 0, reason: python.stderr);
      expect(python.stdout.trim(), '70000 None');
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
