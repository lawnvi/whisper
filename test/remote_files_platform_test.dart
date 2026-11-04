import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/remote_files/fs_paths.dart';
import 'package:whisper/remote_files/fs_platform.dart';

void main() {
  group('Windows names', () {
    test('device names, reserved characters and trailing dots are refused', () {
      for (final (name, problem) in [
        ('CON', 'reserved'),
        ('con.txt', 'reserved'),
        ('Nul.tar.gz', 'reserved'),
        ('COM1', 'reserved'),
        ('lpt9.log', 'reserved'),
        ('COM¹', 'reserved'),
        ('CON .txt', 'reserved'),
        ('a<b', 'character'),
        ('a>b', 'character'),
        ('report:v2', 'character'),
        ('"quoted"', 'character'),
        ('pipe|d', 'character'),
        ('what?', 'character'),
        ('star*', 'character'),
        ('tab\there', 'control'),
        ('trailing.', 'trailing'),
        ('trailing ', 'trailing'),
        ('back\\slash', 'separator'),
        ('', 'empty'),
        ('..', 'dots'),
        ('x' * 256, 'tooLong'),
      ]) {
        expect(fsNameProblem(name, windows: true), problem, reason: name);
      }
      for (final name in [
        'CONSOLE.txt',
        'COM10',
        'console',
        'notes.txt',
        '照片 2026.jpg',
        '.gitignore',
        'a.b.c',
        'LPT',
      ]) {
        expect(fsNameProblem(name, windows: true), isNull, reason: name);
      }
      // Elsewhere only separators, NUL and dots matter.
      expect(fsNameProblem('report:v2', windows: false), isNull);
      expect(fsNameProblem('CON', windows: false), isNull);
      expect(fsNameProblem('trailing.', windows: false), isNull);
      expect(fsNameProblem('a/b', windows: false), 'separator');
    });

    test('wire paths through device names or streams are malformed', () {
      for (final bad in [
        'CON',
        'Documents/nul.txt',
        'file.txt:secret',
        'Documents/old.',
        'a/b?',
        'D:',
      ]) {
        expect(
          () => FsPathResolver.segments(bad, windows: true),
          throwsA(isA<FsPathException>()),
          reason: bad,
        );
      }
      expect(FsPathResolver.segments('Documents/报告 v2.docx', windows: true), [
        'Documents',
        '报告 v2.docx',
      ]);
      expect(
        () => FsPathResolver.checkName('aux.json', windows: true),
        throwsA(isA<FsPathException>()),
      );
      FsPathResolver.checkName('aux.json', windows: false);
    });

    test('a resolver keeps Windows rules on its own', () async {
      final sandbox = await Directory.systemTemp.createTemp('whisper-fs-win-');
      addTearDown(() => sandbox.delete(recursive: true));
      final resolver = FsPathResolver([
        FsRoot(id: 'home', directory: sandbox.path),
      ], windows: true);
      await expectLater(
        resolver.resolveNewChild('home', '', 'NUL'),
        throwsA(isA<FsPathException>()),
      );
      expect(
        await resolver.resolveNewChild('home', '', 'fine.txt'),
        p.join(await sandbox.resolveSymbolicLinks(), 'fine.txt'),
      );
    });

    test('hidden and system attributes hide an entry', () {
      expect(fsHiddenFromAttributes(0x2), isTrue); // hidden
      expect(fsHiddenFromAttributes(0x4), isTrue); // system
      expect(fsHiddenFromAttributes(0x2 | 0x4 | 0x10), isTrue);
      expect(fsHiddenFromAttributes(0x10), isFalse); // a plain folder
      expect(fsHiddenFromAttributes(0x20), isFalse); // archive
      expect(fsHiddenFromAttributes(0xFFFFFFFF), isFalse); // could not read
    });
  });
}
