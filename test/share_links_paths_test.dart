import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart' as win32;
import 'package:whisper/share_links/share_link.dart';
import 'package:whisper/share_links/share_link_store.dart' show shareItemsFor;
import 'package:whisper/share_links/share_hidden.dart';
import 'package:whisper/share_links/share_paths.dart';

ShareLink _link(List<ShareItem> items) => ShareLink(
  id: 'id0000000000',
  route: 'abcd',
  name: 'test',
  items: items,
  createdAt: DateTime(2026),
);

void main() {
  group('request paths', () {
    test('decodes segments and drops a trailing slash', () {
      expect(shareRequestSegments('/'), isEmpty);
      expect(shareRequestSegments('/abcd'), ['abcd']);
      expect(shareRequestSegments('/abcd/'), ['abcd']);
      expect(shareRequestSegments('/abcd/f/a%20b/%E7%85%A7%E7%89%87.jpg'), [
        'abcd',
        'f',
        'a b',
        '照片.jpg',
      ]);
    });

    test('refuses anything that could climb or point elsewhere', () {
      for (final path in [
        '/abcd/f/../secret',
        '/abcd/f/%2e%2e/secret',
        '/abcd/f/./x',
        '/abcd/f/a%2Fb',
        '/abcd/f/a%5Cb',
        '/abcd/f/a%00b',
        '/abcd//f',
        '/abcd/f/%0d%0a',
        '/abcd/f/%E0%A4%A',
        'abcd',
      ]) {
        expect(
          () => shareRequestSegments(path, windows: false),
          throwsA(isA<SharePathException>()),
          reason: path,
        );
      }
    });

    test('on Windows also drive letters, streams and device names', () {
      for (final segment in [
        'C:',
        'file.txt:stream',
        'CON',
        'nul.txt',
        'COM1',
        'trailing.',
        'trailing ',
        'a*b',
      ]) {
        expect(
          () => checkShareSegment(segment, windows: true),
          throwsA(isA<SharePathException>()),
          reason: segment,
        );
        // Plain names elsewhere.
      }
      expect(() => checkShareSegment('CONFIG', windows: true), returnsNormally);
      expect(() => checkShareSegment('a:b', windows: false), returnsNormally);
    });

    test('natural order puts folders first and 2 before 10', () {
      final names = ['b10.txt', 'B2.txt', 'a.txt', 'z'];
      final listings = [
        for (final name in names)
          ShareListing(
            name: name,
            isDir: name == 'z',
            size: 0,
            modified: DateTime(2026),
          ),
      ]..sort(compareShareListings);
      expect(listings.map((l) => l.name), ['z', 'a.txt', 'B2.txt', 'b10.txt']);
    });
  });

  group('resolution on disk', () {
    late Directory temp;
    late String shared;
    late String outside;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('share_paths_');
      final root = await temp.resolveSymbolicLinks();
      shared = p.join(root, 'shared');
      outside = p.join(root, 'outside');
      await Directory(p.join(shared, 'sub', 'deep')).create(recursive: true);
      await Directory(outside).create();
      await File(p.join(shared, 'a.txt')).writeAsString('a');
      await File(p.join(shared, 'sub', 'b.txt')).writeAsString('bb');
      await File(p.join(shared, 'sub', 'deep', 'c.txt')).writeAsString('ccc');
      await File(p.join(shared, '.hidden')).writeAsString('h');
      await File(p.join(outside, 'secret.txt')).writeAsString('secret');
      if (!Platform.isWindows) {
        await Link(
          p.join(shared, 'escape.txt'),
        ).create(p.join(outside, 'secret.txt'));
        await Link(p.join(shared, 'escape-dir')).create(outside);
        await Link(
          p.join(shared, 'inside.txt'),
        ).create(p.join(shared, 'sub', 'b.txt'));
        await Link(p.join(shared, 'loop')).create(shared);
      }
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    test('files and folders inside the shared folder resolve', () async {
      const resolver = ShareResolver();
      final link = _link([
        ShareItem(path: shared, name: 'shared', isDir: true),
      ]);
      final root = await resolver.resolve(link, const []);
      expect(root!.isDir, isTrue);
      final deep = await resolver.resolve(link, ['sub', 'deep', 'c.txt']);
      expect(deep!.size, 3);
      expect(deep.isDir, isFalse);
      expect(await resolver.resolve(link, ['nope.txt']), isNull);
      expect(await resolver.resolve(link, ['.hidden']), isNull);
    });

    test('symlinks leaving the shared folder are refused', () async {
      if (Platform.isWindows) {
        markTestSkipped('symlinks need extra rights on Windows');
        return;
      }
      const resolver = ShareResolver();
      final link = _link([
        ShareItem(path: shared, name: 'shared', isDir: true),
      ]);
      expect(await resolver.resolve(link, ['escape.txt']), isNull);
      expect(await resolver.resolve(link, ['escape-dir']), isNull);
      expect(
        await resolver.resolve(link, ['escape-dir', 'secret.txt']),
        isNull,
      );
      final inside = await resolver.resolve(link, ['inside.txt']);
      expect(inside, isNotNull);
      expect(inside!.size, 2);

      final listing = await resolver.list(root(link, shared));
      final names = listing.map((l) => l.name).toList();
      expect(names, containsAll(['sub', 'a.txt', 'inside.txt']));
      expect(names, isNot(contains('escape.txt')));
      expect(names, isNot(contains('escape-dir')));
      expect(names, isNot(contains('.hidden')));

      final entries = await resolver.zipSource(link)().toList();
      final zipNames = entries.map((e) => e.name).toList();
      expect(zipNames, contains('shared/sub/deep/c.txt'));
      expect(zipNames, contains('shared/inside.txt'));
      expect(zipNames.any((n) => n.contains('secret')), isFalse);
      expect(zipNames.any((n) => n.contains('escape')), isFalse);
      expect(zipNames.any((n) => n.contains('loop')), isFalse);
      expect(zipNames.any((n) => n.contains('.hidden')), isFalse);
    });

    test('a symlink inside the folder cannot reach a hidden item', () async {
      if (Platform.isWindows) {
        markTestSkipped('symlinks need extra rights on Windows');
        return;
      }
      await Directory(p.join(shared, '.secret')).create();
      await File(p.join(shared, '.secret', 'key.txt')).writeAsString('k');
      await Link(
        p.join(shared, 'peek.txt'),
      ).create(p.join(shared, '.secret', 'key.txt'));
      await Link(p.join(shared, 'peekdir')).create(p.join(shared, '.secret'));
      const resolver = ShareResolver();
      final link = _link([
        ShareItem(path: shared, name: 'shared', isDir: true),
      ]);
      expect(await resolver.resolve(link, ['peek.txt']), isNull);
      expect(await resolver.resolve(link, ['peekdir', 'key.txt']), isNull);
      final names = (await resolver.list(
        root(link, shared),
      )).map((l) => l.name);
      expect(names, isNot(contains('peek.txt')));
      expect(names, isNot(contains('peekdir')));
      final zipped = await resolver
          .zipSource(link)()
          .map((e) => e.name)
          .toList();
      expect(
        zipped.any((n) => n.contains('peek') || n.contains('key')),
        isFalse,
      );
    });

    test('items the system hides are left out (Finder, Explorer)', () async {
      final hidden = p.join(shared, 'Library');
      await Directory(hidden).create();
      await File(p.join(hidden, 'prefs.plist')).writeAsString('p');
      final ProcessResult result;
      if (Platform.isMacOS) {
        result = await Process.run('chflags', ['hidden', hidden]);
      } else if (Platform.isWindows) {
        result = await Process.run('attrib', ['+h', hidden]);
      } else {
        markTestSkipped('Linux hides by name only');
        return;
      }
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(shareHiddenFlag(hidden), isTrue);
      expect(shareHiddenFlag(p.join(shared, 'sub')), isFalse);
      const resolver = ShareResolver();
      final link = _link([
        ShareItem(path: shared, name: 'shared', isDir: true),
      ]);
      expect(await resolver.resolve(link, ['Library', 'prefs.plist']), isNull);
      expect(await resolver.resolve(link, ['sub', 'b.txt']), isNotNull);
      final names = (await resolver.list(
        root(link, shared),
      )).map((l) => l.name);
      expect(names, isNot(contains('Library')));
      final zipped = await resolver
          .zipSource(link)()
          .map((e) => e.name)
          .toList();
      expect(zipped.any((n) => n.contains('Library')), isFalse);
      // Shared on purpose, the hidden folder itself is served.
      final own = _link([
        ShareItem(path: hidden, name: 'Library', isDir: true),
      ]);
      expect(await resolver.resolve(own, ['prefs.plist']), isNotNull);
    });

    test('a Windows short name cannot reach a dot folder', () async {
      if (!Platform.isWindows) {
        markTestSkipped('8.3 names are a Windows thing');
        return;
      }
      final ssh = p.join(shared, '.ssh');
      await Directory(ssh).create();
      await File(p.join(ssh, 'id_ed25519')).writeAsString('secret');
      final short = windowsShortName(ssh);
      if (short == null || short == '.ssh') {
        markTestSkipped('8.3 names are turned off on this volume');
        return;
      }
      const resolver = ShareResolver();
      final link = _link([
        ShareItem(path: shared, name: 'shared', isDir: true),
      ]);
      expect(await resolver.resolve(link, [short, 'id_ed25519']), isNull);
      expect(await resolver.resolve(link, [short]), isNull);
    });

    test('a shared file item takes no path below it', () async {
      const resolver = ShareResolver();
      final file = p.join(shared, 'a.txt');
      final link = _link([
        ShareItem(path: file, name: 'a.txt', isDir: false),
        ShareItem(path: p.join(shared, 'sub'), name: 'sub', isDir: true),
      ]);
      expect(await resolver.resolve(link, ['a.txt']), isNotNull);
      expect(await resolver.resolve(link, ['a.txt', 'x']), isNull);
      expect(await resolver.resolve(link, ['sub', 'b.txt']), isNotNull);
      expect(await resolver.resolve(link, ['sub', '..', 'a.txt']), isNull);
      expect(await resolver.resolve(link, ['other']), isNull);
      expect(await resolver.resolve(link, const []), isNull);
      final items = await resolver.listItems(link);
      expect(items.map((i) => i.name), ['sub', 'a.txt']);
    });

    test(
      'items get names of their own and missing paths are left out',
      () async {
        final again = p.join(shared, 'sub', 'a.txt');
        await File(again).writeAsString('again');
        final items = await shareItemsFor([
          p.join(shared, 'a.txt'),
          again,
          p.join(shared, 'a.txt'),
          p.join(shared, 'missing.bin'),
          p.join(shared, 'sub'),
        ]);
        expect(items.map((i) => i.name), ['a.txt', 'a (2).txt', 'sub']);
        expect(items.map((i) => i.isDir), [false, false, true]);
      },
    );
  });
}

ShareTarget root(ShareLink link, String real) => ShareTarget(
  item: link.items.first,
  realPath: real,
  isDir: true,
  size: 0,
  modified: DateTime(2026),
  relative: const [],
  mode: 0,
);

/// The 8.3 name Windows gave [path]'s last part, or null.
String? windowsShortName(String path) {
  final long = path.toNativeUtf16();
  final buffer = calloc<Uint16>(1024).cast<Utf16>();
  try {
    final length = win32.GetShortPathName(long, buffer, 1024);
    if (length == 0 || length >= 1024) {
      return null;
    }
    return p.basename(buffer.toDartString());
  } finally {
    calloc.free(long);
    calloc.free(buffer);
  }
}
