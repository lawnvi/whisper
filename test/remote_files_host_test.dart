import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/remote_files/fs_host_files.dart';
import 'package:whisper/remote_files/fs_paths.dart';

void main() {
  late Directory sandbox;
  late Directory home;
  late Directory outside;
  late FsHostFiles files;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('whisper-fs-');
    home = await Directory(p.join(sandbox.path, 'home')).create();
    outside = await Directory(p.join(sandbox.path, 'secret')).create();
    await File(p.join(outside.path, 'key.txt')).writeAsString('secret');
    await Directory(p.join(home.path, 'Documents')).create();
    for (final name in [
      'IMG_10.jpg',
      'IMG_2.jpg',
      'b.txt',
      'A.txt',
      '.hidden',
    ]) {
      await File(p.join(home.path, 'Documents', name)).writeAsString(name);
    }
    await Directory(p.join(home.path, 'Documents', 'zFolder')).create();
    await Link(p.join(home.path, 'escape')).create(outside.path);
    await Link(
      p.join(home.path, 'Documents', 'inside-link'),
    ).create(p.join(home.path, 'Documents', 'b.txt'));
    files = FsHostFiles(
      resolver: FsPathResolver([FsRoot(id: 'home', directory: home.path)]),
    );
  });

  tearDown(() => sandbox.delete(recursive: true));

  test('wire paths never leave the root', () async {
    for (final bad in [
      '../secret',
      'Documents/../../secret',
      '/etc',
      'a//b',
      r'C:\x',
      'a\u0000b',
    ]) {
      await expectLater(
        files.resolver.resolveExisting('home', bad),
        throwsA(isA<FsPathException>()),
        reason: bad,
      );
    }
    // A symlink pointing out of the root is refused, and hidden in listings.
    await expectLater(
      files.resolver.resolveExisting('home', 'escape/key.txt'),
      throwsA(isA<FsPathException>()),
    );
    final root = await files.list('home', '');
    expect(root.entries.map((e) => e.name), ['Documents']);
    await expectLater(
      files.resolver.resolveExisting('nope', ''),
      throwsA(isA<FsPathException>()),
    );
  });

  test('listings put folders first, sort naturally and page', () async {
    final page = await files.list('home', 'Documents');
    expect(page.entries.map((e) => e.name), [
      'zFolder',
      'A.txt',
      'b.txt',
      'IMG_2.jpg',
      'IMG_10.jpg',
      'inside-link',
    ]);
    expect(page.entries.last.isLink, isTrue);
    expect(page.entries.first.kind, FsKind.folder);
    expect(page.entries[3].kind, FsKind.image);
    final hidden = await files.list('home', 'Documents', showHidden: true);
    expect(hidden.entries.map((e) => e.name), contains('.hidden'));
    final first = await files.list('home', 'Documents', limit: 2);
    expect(first.hasMore, isTrue);
    final next = await files.list('home', 'Documents', offset: 2, limit: 10);
    expect(next.entries.first.name, 'b.txt');
    expect(next.hasMore, isFalse);
  });

  test(
    'create, rename and delete stay inside and spare link targets',
    () async {
      final made = await files.mkdir('home', 'Documents', 'New');
      expect(made, 'Documents/New');
      expect(
        Directory(p.join(home.path, 'Documents', 'New')).existsSync(),
        isTrue,
      );
      await expectLater(
        files.mkdir('home', 'Documents', '../x'),
        throwsA(isA<FsPathException>()),
      );
      final renamed = await files.rename('home', 'Documents/New', 'Renamed');
      expect(renamed, 'Documents/Renamed');
      // Deleting a link removes the link, not the file it points to.
      await files.deletePermanently('home', 'Documents/inside-link');
      expect(
        File(p.join(home.path, 'Documents', 'b.txt')).existsSync(),
        isTrue,
      );
      await files.deletePermanently('home', 'escape');
      expect(File(p.join(outside.path, 'key.txt')).existsSync(), isTrue);
      await expectLater(
        files.deletePermanently('home', ''),
        throwsA(isA<FsPathException>()),
      );
    },
  );
}
