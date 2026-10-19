import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/remote_files/fs_host_files.dart';
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

    test('drives are roots of their own', () {
      final root = windowsDriveRoot(letter: 'd', label: 'Data');
      expect(root.id, 'drive:d');
      expect(root.directory, r'D:\');
      expect(root.toJson(), {
        'id': 'drive:d',
        'kind': 'drive',
        'name': 'Data',
        'drive': 'D',
      });
      expect(
        windowsDriveRoot(letter: 'E', label: '', removable: true).toJson(),
        {'id': 'drive:e', 'kind': 'drive', 'drive': 'E', 'removable': true},
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

  group('Linux places', () {
    test('XDG user folders keep their localized names', () {
      const home = '/home/loop';
      const dirs = '''
# This file is written by xdg-user-dirs-update
XDG_DESKTOP_DIR="\$HOME/桌面"
XDG_DOWNLOAD_DIR="\$HOME/下载"
XDG_TEMPLATES_DIR="\$HOME/模板"
XDG_PUBLICSHARE_DIR="\$HOME/公共的"
XDG_DOCUMENTS_DIR="\$HOME/文档"
XDG_MUSIC_DIR="\$HOME"
XDG_PICTURES_DIR="/home/loop/图片"
XDG_VIDEOS_DIR="/mnt/media/videos"
''';
      final shortcuts = linuxUserDirShortcuts(home, dirs);
      expect(
        {for (final s in shortcuts) s.kind: s.path},
        {
          'desktop': '桌面',
          'documents': '文档',
          'downloads': '下载',
          'pictures': '图片',
          // Disabled (set to home) and outside the home: left out.
        },
      );
      // Without the file, the English defaults.
      expect(linuxUserDirShortcuts(home, null).map((s) => s.path), [
        'Desktop',
        'Documents',
        'Downloads',
        'Pictures',
        'Videos',
        'Music',
      ]);
    });

    test('volumes mounted for the user become roots', () {
      const mounts = r'''
/dev/sda2 / ext4 rw,relatime 0 0
/dev/sdb1 /media/loop/USB\040DISK vfat rw,nosuid,nodev 0 0
/dev/sdc1 /run/media/loop/SD exfat rw 0 0
/dev/sdd1 /media/other/THEIRS vfat rw 0 0
/dev/sde1 /media/loop/USB\040DISK/nested vfat rw 0 0
/dev/sdf1 /run/media/loop/SD ext4 rw 0 0
tmpfs /run/user/1000 tmpfs rw 0 0
''';
      final roots = linuxVolumeRoots(mounts, 'loop');
      expect(roots.map((r) => r.directory), [
        '/media/loop/USB DISK',
        '/run/media/loop/SD',
        '/run/media/loop/SD',
      ]);
      expect(roots.map((r) => r.id), ['vol:USB DISK', 'vol:SD', 'vol:SD 2']);
      expect(roots.first.toJson(), {
        'id': 'vol:USB DISK',
        'kind': 'volume',
        'name': 'USB DISK',
        'removable': true,
      });
      expect(linuxVolumeRoots(mounts, ''), isEmpty);
    });
  });

  group('roots', () {
    test('this Mac keeps its home folder and shortcuts', () {
      if (!Platform.isMacOS) {
        return;
      }
      final roots = defaultFsRoots();
      expect(roots.single.id, 'home');
      expect(roots.single.kind, FsRootKind.home);
      expect(roots.single.shortcuts.map((s) => s.path), [
        'Desktop',
        'Documents',
        'Downloads',
        'Pictures',
        'Movies',
        'Music',
      ]);
      expect(roots.single.toJson(), {'id': 'home', 'kind': 'home'});
    });

    test('roots can change under a resolver', () async {
      final sandbox = await Directory.systemTemp.createTemp('whisper-roots-');
      addTearDown(() => sandbox.delete(recursive: true));
      final a = await Directory(p.join(sandbox.path, 'a')).create();
      final b = await Directory(p.join(sandbox.path, 'b')).create();
      await File(p.join(b.path, 'only-in-b.txt')).writeAsString('b');
      final resolver = FsPathResolver([FsRoot(id: 'vol', directory: a.path)]);
      await expectLater(
        resolver.resolveExisting('vol', 'only-in-b.txt'),
        throwsA(isA<FsPathException>()),
      );
      resolver.setRoots([
        FsRoot(id: 'vol', directory: b.path),
        FsRoot(id: 'other', directory: a.path),
      ]);
      expect(
        await resolver.resolveExisting('vol', 'only-in-b.txt'),
        p.join(await b.resolveSymbolicLinks(), 'only-in-b.txt'),
      );
      expect(resolver.roots.map((r) => r.id), ['vol', 'other']);
    });

    test('thumbnails are asked of every platform, documents where drawn', () {
      for (final os in ['macos', 'android', 'windows', 'linux', 'ios']) {
        expect(FsPlatform.thumbnailsWanted(FsKind.image, platform: os), isTrue);
        expect(FsPlatform.thumbnailsWanted(FsKind.video, platform: os), isTrue);
        expect(
          FsPlatform.thumbnailsWanted(FsKind.audio, platform: os),
          isFalse,
        );
      }
      expect(
        FsPlatform.thumbnailsWanted(FsKind.document, platform: 'windows'),
        isTrue,
      );
      expect(
        FsPlatform.thumbnailsWanted(FsKind.document, platform: 'ios'),
        isTrue,
      );
      expect(
        FsPlatform.thumbnailsWanted(FsKind.document, platform: 'linux'),
        isFalse,
      );
      expect(
        FsPlatform.thumbnailsWanted(FsKind.document, platform: 'android'),
        isFalse,
      );
      expect(
        FsPlatform.thumbnailsWanted(FsKind.image, platform: 'fuchsia'),
        isFalse,
      );
    });
  });

  test('every desktop can take the file manager\'s copy off the clipboard', () {
    // Another device's items copied for a paste here replace what the
    // clipboard held, so Finder does not paste an older thing meanwhile.
    for (final plugin in [
      'macos/Runner/MainFlutterWindow.swift',
      'windows/runner/desktop_clipboard_image_plugin.cpp',
      'linux/desktop_clipboard_image_plugin.cc',
    ]) {
      expect(
        File(plugin).readAsStringSync(),
        contains('clearFilePaths'),
        reason: plugin,
      );
    }
    final model = File(
      'lib/page/remote_files/files_model.dart',
    ).readAsStringSync();
    expect(model, contains("invokeMethod<bool>('clearFilePaths')"));
    expect(
      model,
      contains(
        '      await system.clear();\n'
        '      _systemPaths = const [];\n'
        '      if (generation == _clipboardGeneration) {',
      ),
    );
  });
}
