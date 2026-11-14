import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/remote_files/fs_host_files.dart';
import 'package:whisper/remote_files/fs_paths.dart';
import 'package:whisper/remote_files/fs_share_policy.dart';

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

  test('what is mounted here is never served, nor a link to it', () async {
    final mounted = await Directory(
      p.join(home.path, 'Whisper', 'Phone'),
    ).create(recursive: true);
    await File(p.join(mounted.path, 'inside.txt')).writeAsString('x');
    final real = await mounted.resolveSymbolicLinks();
    // A link someone made to a mount.
    await Link(p.join(home.path, 'Phone link')).create(real);
    final before = FsHostFiles.excluded;
    FsHostFiles.excluded = () => {real};
    addTearDown(() => FsHostFiles.excluded = before);
    final top = await files.list('home', '');
    expect(top.entries.map((e) => e.name), isNot(contains('Phone link')));
    final whisper = await files.list('home', 'Whisper');
    expect(whisper.entries, isEmpty);
    // The app's mounts are the ones left out.
    expect(
      File('lib/remote_files/mount/remote_mounts.dart').readAsStringSync(),
      contains('RemoteMounts().._hideFromHost()'),
    );
  });

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

  group('shared folders', () {
    late String real;
    late Directory outsideRepo;

    /// The host's files when [shared] (relative to home) are shared, less
    /// [excluded].
    FsHostFiles sharing(
      List<String> shared, {
      List<String> excluded = const [],
    }) {
      final policy = FsSharePolicy(
        shared: [for (final folder in shared) p.join(real, folder)],
        excluded: [for (final folder in excluded) p.join(real, folder)],
        protected: FsProtectedAreas(
          home: real,
          private: [p.join(real, 'Library')],
          files: [p.join(real, 'Documents', 'db')],
        ),
      );
      return FsHostFiles(
        resolver: FsPathResolver([
          FsRoot(id: 'home', directory: home.path),
        ], policy: () => policy),
      );
    }

    setUp(() async {
      real = await home.resolveSymbolicLinks();
      Future<void> write(String path) async {
        final file = File(p.join(real, path));
        await file.parent.create(recursive: true);
        await file.writeAsString(path);
      }

      for (final path in [
        '.ssh/id_rsa',
        '.zshrc',
        'Library/LaunchAgents/a.plist',
        'Music/song.mp3',
        'Projects/app/main.dart',
        'Projects/notes.txt',
        'Documents/db',
        'Documents/repo/.git/config',
        'Documents/repo/.git/HEAD',
        'Documents/repo/.git/hooks/pre-commit.sample',
        'Documents/repo/.git/worktrees/w/commondir',
        'Documents/evil/config',
      ]) {
        await write(path);
      }
      await Link(
        p.join(real, 'Documents', 'keys'),
      ).create(p.join(real, '.ssh'));
      outsideRepo = await Directory(
        p.join(sandbox.path, 'arrived', 'proj', '.git'),
      ).create(recursive: true);
    });

    test('decide what another device may do, and where', () async {
      final folders = sharing(['Documents', 'Projects/app']);
      final whole = sharing(['']);
      // A disk shared on its own (Projects/app) where the system disk's
      // folder holding it is left out, as /Volumes is.
      final leftOut = sharing(
        ['', 'Projects/app'],
        excluded: ['Projects', 'Music', 'Documents/repo'],
      );
      final deep = sharing([''], excluded: ['Projects/app']);
      Future<void> place(String from, String to) async {
        if (!await folders.mayPlace(from, p.join(real, to))) {
          throw const FsPathException('not shared');
        }
      }

      final allowed = <String, Future<Object?> Function()>{
        'read in a shared folder': () =>
            folders.stat('home', 'Documents/A.txt'),
        'read a git config': () =>
            folders.stat('home', 'Documents/repo/.git/config'),
        'make a folder in a shared one': () =>
            folders.mkdir('home', 'Documents', 'New'),
        'copy out a shared folder (without Whisper\'s files)': () => folders
            .resolver
            .resolveExisting('home', 'Documents', use: FsUse.copy),
        'place a copy in a shared folder': () =>
            place(p.join(real, 'Music', 'song.mp3'), 'Documents/song.mp3'),
        'read in a disk shared inside a folder left out': () =>
            leftOut.stat('home', 'Projects/app/main.dart'),
        'copy out that disk': () => leftOut.resolver.resolveExisting(
          'home',
          'Projects/app',
          use: FsUse.copy,
        ),
      };
      final refused = <String, Future<Object?> Function()>{
        'read beside it': () => folders.stat('home', 'Music/song.mp3'),
        'read on the way to it': () =>
            folders.stat('home', 'Projects/notes.txt'),
        'read a hidden home entry': () => whole.stat('home', '.ssh/id_rsa'),
        'read ~/Library': () =>
            whole.stat('home', 'Library/LaunchAgents/a.plist'),
        'read Whisper\'s own file': () => folders.stat('home', 'Documents/db'),
        'follow a link to ~/.ssh': () =>
            folders.stat('home', 'Documents/keys/id_rsa'),
        'make a folder on the way': () =>
            folders.mkdir('home', 'Projects', 'New'),
        'make a folder in home': () => folders.mkdir('home', '', 'New'),
        'rename a shared folder': () =>
            folders.rename('home', 'Documents', 'Docs'),
        'delete a folder on the way': () =>
            folders.deletePermanently('home', 'Projects'),
        'write a dot file in home': () => whole.create('home', '', '.bashrc'),
        'add a hook': () => folders.create(
          'home',
          'Documents/repo/.git/hooks',
          'post-checkout',
        ),
        'change a git config': () =>
            folders.touch('home', 'Documents/repo/.git/config', 0),
        // A worktree's commondir says where its config is read from.
        'point a worktree at another config': () => folders.touch(
          'home',
          'Documents/repo/.git/worktrees/w/commondir',
          0,
        ),
        'delete a hook': () => folders.deletePermanently(
          'home',
          'Documents/repo/.git/hooks/pre-commit.sample',
        ),
        'rename a folder into .git': () =>
            folders.rename('home', 'Documents/evil', '.git'),
        'move a file into hooks': () => folders.move(
          'home',
          'Documents/A.txt',
          'Documents/repo/.git/hooks',
          'pre-push',
        ),
        'move a .git away': () =>
            folders.move('home', 'Documents/repo/.git', 'Documents', 'old'),
        'copy out the whole home': () =>
            whole.resolver.resolveExisting('home', '', use: FsUse.copy),
        'place a copy that brings a .git': () =>
            place(outsideRepo.parent.path, 'Documents/proj'),
        'place a copy on the way': () =>
            place(p.join(real, 'Music', 'song.mp3'), 'Projects/song.mp3'),
        'read in a folder left out': () =>
            leftOut.stat('home', 'Music/song.mp3'),
        'read beside a disk shared inside one': () =>
            leftOut.stat('home', 'Projects/notes.txt'),
        'make a folder in one left out': () =>
            leftOut.mkdir('home', 'Music', 'New'),
        'copy out a folder holding one left out': () => leftOut.resolver
            .resolveExisting('home', 'Documents', use: FsUse.copy),
        // What is left out, Whisper's files and mounts are known by where
        // they are: a folder holding one renamed, moved or deleted would
        // take it out from under its rule, or delete it.
        'rename a folder holding one left out': () =>
            deep.rename('home', 'Projects', 'Other'),
        'move a folder holding Whisper\'s file': () =>
            whole.move('home', 'Documents', 'Music', 'Docs'),
        'delete a folder holding one left out': () =>
            deep.deletePermanently('home', 'Projects'),
        // Hidden from listings; put in place of a file being read, between
        // the check and the open, it would be what is opened.
        'move a link to ~/.ssh': () =>
            folders.rename('home', 'Documents/keys', 'notes'),
      };
      for (final MapEntry(key: name, value: run) in allowed.entries) {
        await expectLater(run(), completes, reason: name);
      }
      for (final MapEntry(key: name, value: run) in refused.entries) {
        await expectLater(
          run(),
          throwsA(
            isA<FsPathException>().having(
              (e) => e.reason,
              'reason',
              'not shared',
            ),
          ),
          reason: name,
        );
      }
    });

    test('list only the way to shared folders, and never the floor', () async {
      Future<List<String>> names(FsHostFiles files, String path) async => [
        for (final entry in (await files.list(
          'home',
          path,
          showHidden: true,
        )).entries)
          entry.name,
      ];
      final folders = sharing(['Documents', 'Projects/app']);
      expect(await names(folders, ''), ['Documents', 'Projects']);
      expect(await names(folders, 'Projects'), ['app']);
      expect(await names(folders, 'Documents'), isNot(contains('keys')));
      expect(await names(folders, 'Documents'), isNot(contains('db')));
      final leftOut = sharing(
        ['', 'Projects/app'],
        excluded: ['Projects', 'Music'],
      );
      expect(await names(leftOut, ''), ['Documents', 'Projects']);
      expect(await names(leftOut, 'Projects'), ['app']);
      final everything = sharing(['']);
      expect(
        await names(everything, ''),
        [
          'Documents',
          'Music',
          'Projects',
          'secret',
          'escape',
        ].where((name) => name != 'secret' && name != 'escape').toList(),
      );
    });
  });
}
