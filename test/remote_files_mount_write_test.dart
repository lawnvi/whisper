import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/remote_files/fs_client.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/remote_files/fs_host_files.dart';
import 'package:whisper/remote_files/fs_host_uploads.dart';
import 'package:whisper/remote_files/fs_paths.dart';
import 'package:whisper/remote_files/fs_protocol.dart';
import 'package:whisper/remote_files/mount/fuse_linux.dart';
import 'package:whisper/remote_files/mount/mount_macos.dart';
import 'package:whisper/remote_files/mount/mount_tree.dart';
import 'package:whisper/remote_files/mount/nfs_server.dart';
import 'package:whisper/remote_files/mount/remote_mounts.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';

class _AllowGate extends FileBrowseGate {
  @override
  Future<FileBrowseDecision> ask(FileBrowseRequest request) async =>
      FileBrowseDecision.once;
}

/// A device's files in memory that take changes, counting what is asked.
class _Device extends MountSource {
  final files = <String, Uint8List>{};
  final modified = <String, int>{};
  final folders = <String>{''};
  final trashed = <String>[];
  final deleted = <String>[];
  final opens = <(String, bool)>[];
  int lists = 0;
  final writes = <(int, int)>[];
  final _uploads = <String, (String, BytesBuilder)>{};
  var _next = 0;
  Completer<void>? holdWrites;
  bool failWrites = false;

  @override
  bool get writable => true;

  String _key(String parent, String name) =>
      parent.isEmpty ? name : '$parent/$name';

  @override
  Future<List<FsEntry>> list(String root, String path) async {
    lists++;
    if (!folders.contains(path)) {
      throw const MountException(MountError.notFound);
    }
    bool inside(String key) =>
        p.posix.dirname(key) == (path.isEmpty ? '.' : path) && key != path;
    return [
      for (final folder in folders)
        if (folder.isNotEmpty && inside(folder))
          FsEntry(
            name: p.posix.basename(folder),
            isDir: true,
            size: 0,
            modifiedMs: 1000,
          ),
      for (final MapEntry(:key, :value) in files.entries)
        if (inside(key))
          FsEntry(
            name: p.posix.basename(key),
            isDir: false,
            size: value.length,
            modifiedMs: modified[key] ?? 1000,
          ),
    ];
  }

  @override
  Future<Uint8List> read(String root, String path, int offset, int length) {
    final data = files[path]!;
    final end = (offset + length).clamp(0, data.length);
    return Future.value(Uint8List.sublistView(data, offset.clamp(0, end), end));
  }

  @override
  Future<FsEntry> create(String root, String parent, String name) async {
    final key = _key(parent, name);
    if (files.containsKey(key) || folders.contains(key)) {
      throw const MountException(MountError.exists);
    }
    files[key] = Uint8List(0);
    return FsEntry(name: name, isDir: false, size: 0, modifiedMs: 2000);
  }

  @override
  Future<void> mkdir(String root, String parent, String name) async {
    folders.add(_key(parent, name));
  }

  @override
  Future<void> remove(
    String root,
    String path, {
    bool folder = false,
    bool permanent = false,
  }) async {
    (permanent ? deleted : trashed).add(path);
    folder ? folders.remove(path) : files.remove(path);
  }

  @override
  Future<void> move(
    String root,
    String path,
    String parent,
    String name,
  ) async {
    final to = _key(parent, name);
    if (folders.remove(path)) {
      folders.add(to);
      for (final key in files.keys.toList()) {
        if (key.startsWith('$path/')) {
          files['$to${key.substring(path.length)}'] = files.remove(key)!;
        }
      }
    } else {
      files[to] = files.remove(path)!;
    }
  }

  @override
  Future<void> touch(String root, String path, int modifiedMs) async {
    modified[path] = modifiedMs;
  }

  @override
  Future<({String id, int size})> writeOpen(
    String root,
    String path, {
    required bool truncate,
  }) async {
    opens.add((path, truncate));
    final builder = BytesBuilder();
    if (!truncate) {
      builder.add(files[path]!);
    }
    final id = 'u${_next++}';
    _uploads[id] = (path, builder);
    return (id: id, size: builder.length);
  }

  @override
  Future<void> write(String upload, int offset, Uint8List data) async {
    writes.add((offset, data.length));
    await holdWrites?.future;
    if (failWrites) {
      throw const MountException(MountError.offline);
    }
    final (path, builder) = _uploads[upload]!;
    final bytes = builder.takeBytes();
    final out = Uint8List(
      offset + data.length > bytes.length ? offset + data.length : bytes.length,
    )..setAll(0, bytes);
    out.setAll(offset, data);
    builder.add(out);
    _uploads[upload] = (path, builder);
  }

  @override
  Future<void> writeSize(String upload, int size) async {
    final (path, builder) = _uploads[upload]!;
    final bytes = builder.takeBytes();
    builder.add(
      size <= bytes.length
          ? Uint8List.sublistView(bytes, 0, size)
          : (Uint8List(size)..setAll(0, bytes)),
    );
  }

  @override
  Future<Uint8List> readUpload(String upload, int offset, int length) async {
    final bytes = _uploads[upload]!.$2.toBytes();
    final end = (offset + length).clamp(0, bytes.length);
    return Uint8List.sublistView(bytes, offset.clamp(0, end), end);
  }

  @override
  Future<({String path, FsEntry? entry})> writeClose(
    String upload, {
    required bool commit,
    int? modifiedMs,
  }) async {
    final (path, builder) = _uploads.remove(upload)!;
    if (!commit) {
      return (path: path, entry: null);
    }
    files[path] = builder.takeBytes();
    modified[path] = modifiedMs ?? 3000;
    return (
      path: path,
      entry: FsEntry(
        name: p.posix.basename(path),
        isDir: false,
        size: files[path]!.length,
        modifiedMs: modified[path]!,
      ),
    );
  }
}

Uint8List _bytes(int length, [int seed = 7]) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed) & 0xff));

Matcher _fails(MountError error) =>
    throwsA(isA<MountException>().having((e) => e.error, 'error', error));

void main() {
  group('writes through the browse session', () {
    late Directory sandbox;
    late FileBrowseHost host;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      sandbox = await Directory.systemTemp.createTemp('whisper-write-');
      await File(p.join(sandbox.path, 'a.txt')).writeAsString('hello');
      await Directory(p.join(sandbox.path, 'Docs')).create();
      host = FileBrowseHost(
        files: FsHostFiles(
          resolver: FsPathResolver([
            FsRoot(id: 'home', directory: sandbox.path),
          ]),
        ),
        gate: _AllowGate(),
      );
      FileBrowseMessage copy(FileBrowseMessage message) =>
          FileBrowseMessage.fromJson(
            jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
          );
      host.sender = (peerId, message) async {
        final reply = copy(message);
        scheduleMicrotask(
          () => RemoteFilesClient.handle(reply, remotePeerId: 'host'),
        );
        return true;
      };
      host.sendData = (peerId, sessionId, requestId, offset, data) async {
        scheduleMicrotask(
          () => RemoteFilesClient.handleData(
            remotePeerId: 'host',
            sessionId: sessionId,
            requestId: requestId,
            data: Uint8List.fromList(data),
          ),
        );
        return true;
      };
      RemoteFilesClient.localPeerId = (_) => 'client';
      RemoteFilesClient.sender = (peerId, message) async {
        final request = copy(message);
        scheduleMicrotask(
          () => host.handle(request, remotePeerId: 'client', deviceName: 'Mac'),
        );
        return true;
      };
      RemoteFilesClient.sendWrite =
          (peerId, transferId, requestId, offset, data) async {
            // As a frame does: through bytes.
            final frame = WhisperFrameV3.decode(
              WhisperFrameV3(
                type: WhisperFrameType.browseWrite,
                transferId: transferId,
                offset: offset,
                sequence: requestId,
                payload: data,
              ).encode(),
            );
            // Frames are taken in the order they come.
            unawaited(
              host.handleWrite(
                remotePeerId: 'client',
                transferId: frame.transferId,
                requestId: frame.sequence,
                offset: frame.offset,
                data: Uint8List.fromList(frame.payload),
              ),
            );
            return true;
          };
    });

    tearDown(() => sandbox.delete(recursive: true));

    Future<List<String>> names() async => [
      for (final entity in await sandbox.list().toList())
        p.basename(entity.path),
    ]..sort();

    test('a newer host takes writes; one made read-only says so', () async {
      final client = RemoteFilesClient('host');
      final info = await client.open();
      expect(info.canWrite, isTrue);
      expect(info.readOnly, isFalse);
      await client.close();

      await host.setReadOnly('client', true);
      final limited = RemoteFilesClient('host');
      final limitedInfo = await limited.open();
      expect(limitedInfo.canWrite, isFalse);
      expect(limitedInfo.readOnly, isTrue);
      Matcher refused() => throwsA(
        isA<RemoteFsException>().having(
          (e) => e.reason,
          'reason',
          FileBrowseError.readOnly,
        ),
      );
      await expectLater(limited.create('home', '', 'b.txt'), refused());
      await expectLater(limited.mkdir('home', '', 'New'), refused());
      await expectLater(limited.remove('home', 'a.txt'), refused());
      await expectLater(limited.writeOpen('home', 'a.txt'), refused());
      // Reading still works.
      expect(utf8.decode(await limited.read('home', 'a.txt', 0, 10)), 'hello');
      expect(await names(), ['Docs', 'a.txt']);
      await limited.close();
    });

    test(
      'a file is written beside itself and put in place at the end',
      () async {
        final client = RemoteFilesClient('host');
        await client.open();
        final entry = await client.create('home', 'Docs', 'new.bin');
        expect(entry.size, 0);
        final upload = await client.writeOpen(
          'home',
          'Docs/new.bin',
          truncate: true,
        );
        final data = _bytes(3 * 1024 * 1024 + 5);
        await Future.wait([
          client.write(upload.id, 0, Uint8List.sublistView(data, 0, 1 << 20)),
          client.write(
            upload.id,
            1 << 20,
            Uint8List.sublistView(data, 1 << 20, data.length),
          ),
        ]);
        // Nothing there yet but the hidden copy, which listings leave out.
        final docs = Directory(p.join(sandbox.path, 'Docs'));
        final hidden = [
          for (final e in await docs.list().toList()) p.basename(e.path),
        ];
        expect(hidden.where(FsUploads.isTemp), hasLength(1));
        expect(await File(p.join(docs.path, 'new.bin')).length(), 0);
        final page = await client.list('home', 'Docs', showHidden: true);
        expect(page.entries.map((e) => e.name), ['new.bin']);
        // What was written reads back before it is in place.
        expect(
          await client.read('', '', 1 << 20, 16, upload: upload.id),
          data.sublist(1 << 20, (1 << 20) + 16),
        );

        final closed = await client.writeClose(
          upload.id,
          commit: true,
          modifiedMs: DateTime(2025, 1, 2).millisecondsSinceEpoch,
        );
        expect(closed.path, 'Docs/new.bin');
        expect(closed.entry!.size, data.length);
        final file = File(p.join(docs.path, 'new.bin'));
        expect(await file.readAsBytes(), data);
        expect((await file.lastModified()).year, 2025);
        expect(
          [for (final e in await docs.list().toList()) p.basename(e.path)],
          ['new.bin'],
        );
        await client.close();
      },
    );

    test('writing from what a file holds, and cutting it short', () async {
      final client = RemoteFilesClient('host');
      await client.open();
      final upload = await client.writeOpen('home', 'a.txt');
      expect(upload.size, 5);
      await client.write(upload.id, 5, utf8.encode(' world!'));
      await client.writeSize(upload.id, 11);
      await client.writeClose(upload.id, commit: true);
      expect(
        await File(p.join(sandbox.path, 'a.txt')).readAsString(),
        'hello world',
      );
      await client.close();
    });

    test(
      'a file changed here meanwhile is kept; the write goes beside it',
      () async {
        final client = RemoteFilesClient('host');
        await client.open();
        final upload = await client.writeOpen('home', 'a.txt', truncate: true);
        await client.write(upload.id, 0, utf8.encode('from the Mac'));
        final original = File(p.join(sandbox.path, 'a.txt'));
        await original.writeAsString('changed here');
        await original.setLastModified(DateTime(2020));
        final closed = await client.writeClose(upload.id, commit: true);
        expect(closed.path, 'a (Mac).txt');
        expect(await original.readAsString(), 'changed here');
        expect(
          await File(p.join(sandbox.path, 'a (Mac).txt')).readAsString(),
          'from the Mac',
        );
        await client.close();
      },
    );

    test('dropped or left behind, a write leaves nothing', () async {
      final client = RemoteFilesClient('host');
      await client.open();
      final dropped = await client.writeOpen('home', 'a.txt', truncate: true);
      await client.write(dropped.id, 0, utf8.encode('nope'));
      await client.writeClose(dropped.id, commit: false);
      final left = await client.writeOpen('home', 'a.txt');
      await client.write(left.id, 0, utf8.encode('gone'));
      expect((await names()).where(FsUploads.isTemp), hasLength(1));
      await client.close();
      // The session's end takes it away, file I/O and all.
      for (var i = 0; i < 100 && (await names()).any(FsUploads.isTemp); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(await names(), ['Docs', 'a.txt']);
      expect(await File(p.join(sandbox.path, 'a.txt')).readAsString(), 'hello');
    });

    test('making read-only drops what is being written', () async {
      final client = RemoteFilesClient('host');
      await client.open();
      final upload = await client.writeOpen('home', 'a.txt', truncate: true);
      await host.setReadOnly('client', true);
      await expectLater(
        client.write(upload.id, 0, utf8.encode('x')),
        throwsA(isA<RemoteFsException>()),
      );
      expect(await names(), ['Docs', 'a.txt']);
      await client.close();
    });

    test('moves, touches and removes', () async {
      final client = RemoteFilesClient('host');
      await client.open();
      await File(p.join(sandbox.path, 'b.txt')).writeAsString('b');
      // A rename replaces a file the way rename(2) does.
      expect(await client.move('home', 'b.txt', '', 'a.txt'), 'a.txt');
      expect(await File(p.join(sandbox.path, 'a.txt')).readAsString(), 'b');
      expect(await client.move('home', 'a.txt', 'Docs', 'c.txt'), 'Docs/c.txt');
      // A folder into itself is refused.
      await expectLater(
        client.move('home', 'Docs', 'Docs', 'Inner'),
        throwsA(isA<RemoteFsException>()),
      );
      await client.touch(
        'home',
        'Docs/c.txt',
        DateTime(2024, 6, 1).millisecondsSinceEpoch,
      );
      expect(
        (await File(p.join(sandbox.path, 'Docs', 'c.txt')).lastModified()).year,
        2024,
      );
      await expectLater(
        client.remove('home', 'Docs', folder: true),
        throwsA(
          isA<RemoteFsException>().having(
            (e) => e.reason,
            'reason',
            FileBrowseError.notEmpty,
          ),
        ),
      );
      await client.mkdir('home', '', 'Empty');
      await client.remove('home', 'Empty', folder: true);
      expect(await names(), ['Docs']);
      final space = await client.space('home');
      if (!Platform.isWindows) {
        expect(space, isNotNull);
        expect(space!.total, greaterThan(space.free));
      }
      await client.close();
    });

    test('a mount over the session writes through it', () async {
      final client = RemoteFilesClient('host');
      final info = await client.open();
      final tree = MountTree(
        RemoteMountSource(client, writable: info.canWrite),
        const [MountRoot(id: 'home', name: 'x')],
      );
      final docs = (await tree.lookup(MountTree.rootIno, 'Docs'))!;
      final file = await tree.create(docs.ino, 'm.txt');
      await tree.write(file.ino, 0, utf8.encode('mounted'));
      await tree.commit(file.ino);
      expect(
        await File(p.join(sandbox.path, 'Docs', 'm.txt')).readAsString(),
        'mounted',
      );
      await tree.rename(docs.ino, 'm.txt', MountTree.rootIno, 'n.txt');
      expect(
        await File(p.join(sandbox.path, 'n.txt')).readAsString(),
        'mounted',
      );
      // Made here: gone for good, not to the trash.
      await tree.unlink(MountTree.rootIno, 'n.txt');
      expect(await names(), ['Docs', 'a.txt']);
      await client.close();
    });
  });

  group('mount tree writes', () {
    late _Device device;
    late MountTree tree;

    setUp(() {
      device = _Device()
        ..folders.add('Docs')
        ..files['Docs/a.txt'] = Uint8List.fromList(utf8.encode('hello'))
        ..files['old.txt'] = Uint8List.fromList(utf8.encode('old'));
      tree = MountTree(device, const [MountRoot(id: 'home', name: 'x')]);
    });

    test('writes in a row go together, and in place at commit', () async {
      final file = await tree.create(MountTree.rootIno, 'new.bin');
      final data = _bytes(3 * 1024 * 1024 + 100);
      for (var at = 0; at < data.length; at += 128 * 1024) {
        final end = (at + 128 * 1024).clamp(0, data.length);
        await tree.write(file.ino, at, Uint8List.sublistView(data, at, end));
      }
      expect(device.files['new.bin'], isEmpty, reason: 'not in place yet');
      expect((await tree.stat(file.ino)).size, data.length);
      await tree.commit(file.ino);
      expect(device.files['new.bin'], data);
      expect(device.writes.length, 4, reason: 'in 1 MiB pieces');
      expect(device.opens, [('new.bin', true)], reason: 'nothing to copy');
    });

    test('what is being written reads back as written', () async {
      final docs = (await tree.lookup(MountTree.rootIno, 'Docs'))!;
      final file = (await tree.lookup(docs.ino, 'a.txt'))!;
      await tree.write(file.ino, 5, utf8.encode(' there'));
      expect(utf8.decode(await tree.read(file.ino, 0, 100)), 'hello there');
      // Listed again meanwhile: the device's old size does not come back.
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect((await tree.stat(file.ino)).size, 11);
      await tree.commit(file.ino);
      expect(utf8.decode(device.files['Docs/a.txt']!), 'hello there');
      expect(utf8.decode(await tree.read(file.ino, 0, 100)), 'hello there');
    });

    test('a truncating open copies nothing', () async {
      final file = (await tree.lookup(MountTree.rootIno, 'old.txt'))!;
      await tree.resize(file.ino, 0);
      await tree.write(file.ino, 0, utf8.encode('new'));
      await tree.commit(file.ino);
      expect(device.opens, [('old.txt', true)]);
      expect(utf8.decode(device.files['old.txt']!), 'new');
    });

    test('concurrent first writes share one upload', () async {
      final file = (await tree.lookup(MountTree.rootIno, 'old.txt'))!;
      await Future.wait([
        for (var i = 0; i < 4; i++)
          tree.write(file.ino, i * 3, utf8.encode('abc')),
      ]);
      await tree.commit(file.ino);
      expect(device.opens, hasLength(1));
      expect(utf8.decode(device.files['old.txt']!), 'abcabcabcabc');
    });

    test('a failed write is told when the file is closed', () async {
      final file = (await tree.lookup(MountTree.rootIno, 'old.txt'))!;
      device.failWrites = true;
      await tree.write(file.ino, 0, utf8.encode('x'));
      await expectLater(tree.commit(file.ino), _fails(MountError.offline));
      expect(utf8.decode(device.files['old.txt']!), 'old');
      // Told once; the file is as it was.
      await tree.commit(file.ino);
    });

    test('writes wait when too much is on its way', () async {
      final file = await tree.create(MountTree.rootIno, 'big.bin');
      device.holdWrites = Completer<void>();
      var written = 0;
      final writing = () async {
        for (var i = 0; i < 12; i++) {
          await tree.write(file.ino, i << 20, _bytes(1 << 20));
          written++;
        }
      }();
      await pumpEventQueue();
      expect(written, lessThan(12));
      device.holdWrites!.complete();
      await writing;
      await tree.commit(file.ino);
      expect(device.files['big.bin']!.length, 12 << 20);
    });

    test('renames move what is under them; deletes go by where from', () async {
      final docs = (await tree.lookup(MountTree.rootIno, 'Docs'))!;
      final a = (await tree.lookup(docs.ino, 'a.txt'))!;
      await tree.write(a.ino, 0, utf8.encode('HELLO'));
      await tree.rename(MountTree.rootIno, 'Docs', MountTree.rootIno, 'Papers');
      // Its writes went to where it was before the move.
      expect(utf8.decode(device.files['Papers/a.txt']!), 'HELLO');
      expect(a.path, 'Papers/a.txt');
      expect(docs.path, 'Papers');
      expect(utf8.decode(await tree.read(a.ino, 0, 10)), 'HELLO');
      expect(await tree.lookup(MountTree.rootIno, 'Docs'), isNull);

      await expectLater(
        tree.rename(
          docs.ino,
          'a.txt',
          MountTree.rootIno,
          'old.txt',
          noReplace: true,
        ),
        _fails(MountError.exists),
      );
      await tree.rename(docs.ino, 'a.txt', MountTree.rootIno, 'old.txt');
      expect(utf8.decode(device.files['old.txt']!), 'HELLO');

      final made = await tree.create(MountTree.rootIno, 'tmp.swp');
      await tree.unlink(MountTree.rootIno, made.name);
      await tree.unlink(MountTree.rootIno, 'old.txt');
      expect(device.deleted, ['tmp.swp']);
      expect(device.trashed, ['old.txt']);
      await tree.rmdir(MountTree.rootIno, 'Papers');
      expect(device.folders, ['']);
    });

    test('what is kept here never asks the device', () async {
      final kept = MountTree(device, const [
        MountRoot(id: 'home', name: 'x'),
      ], keepHere: (name) => name.startsWith('._'));
      final docs = (await kept.lookup(MountTree.rootIno, 'Docs'))!;
      final double = await kept.create(docs.ino, '._a.txt');
      await kept.write(double.ino, 0, utf8.encode('xattrs'));
      final lists = device.lists;
      expect(await kept.lookup(docs.ino, '._a.txt'), same(double));
      expect(await kept.lookup(docs.ino, '._b.txt'), isNull);
      expect((await kept.stat(double.ino)).size, 6);
      expect(device.lists, lists, reason: 'no listing asked for');
      expect(device.files.keys.where((k) => k.contains('._')), isEmpty);
      await kept.unlink(docs.ino, '._a.txt');
      expect(await kept.lookup(docs.ino, '._a.txt'), isNull);
    });

    test('a folder changed from here says so in its time', () async {
      // macOS trusts what it read of a folder until its time changes; an
      // unchanged time after a create kept it from writing `._name`.
      final docs = (await tree.lookup(MountTree.rootIno, 'Docs'))!;
      final before = docs.ticks;
      await tree.create(docs.ino, 'n.txt');
      await tree.unlink(docs.ino, 'n.txt');
      await tree.mkdir(docs.ino, 'Sub');
      await tree.rename(docs.ino, 'Sub', MountTree.rootIno, 'Sub2');
      expect(docs.ticks, before + 4);
      expect(tree.top.ticks, greaterThan(0));
    });

    test('a file deleted from here and made again is another file', () async {
      // copyfile drops and remakes `._name`: handing the system the number
      // of the one it removed failed macOS's extended attributes.
      final kept = MountTree(device, const [
        MountRoot(id: 'home', name: 'x'),
      ], keepHere: (name) => name.startsWith('._'));
      final first = await kept.create(MountTree.rootIno, '._x');
      await kept.unlink(MountTree.rootIno, '._x');
      final again = await kept.create(MountTree.rootIno, '._x');
      expect(again.ino, isNot(first.ino));
      expect(first.gone, isTrue);

      final file = await kept.create(MountTree.rootIno, 'y.txt');
      await kept.unlink(MountTree.rootIno, 'y.txt');
      final remade = await kept.create(MountTree.rootIno, 'y.txt');
      expect(remade.ino, isNot(file.ino));
    });

    test('a device that takes no changes leaves the mount read-only', () async {
      final readOnly = MountTree(_ReadOnly(), const [
        MountRoot(id: 'home', name: 'x'),
      ]);
      expect(readOnly.writable, isFalse);
      await expectLater(
        readOnly.create(MountTree.rootIno, 'x'),
        _fails(MountError.readOnly),
      );
    });

    test('a file left alone is put in place where nothing says so', () async {
      final idle = MountTree(device, const [
        MountRoot(id: 'home', name: 'x'),
      ], idleCommit: const Duration(milliseconds: 20));
      final file = (await idle.lookup(MountTree.rootIno, 'old.txt'))!;
      await idle.write(file.ino, 0, utf8.encode('NEW'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(utf8.decode(device.files['old.txt']!), 'NEW');
    });
  });

  group('FUSE writes', () {
    late _Device device;
    late FuseMount fuse;
    final replies = <int, (int, Uint8List)>{};
    var unique = 0;

    setUp(() {
      device = _Device()
        ..files['a.txt'] = Uint8List.fromList(utf8.encode('hello'));
      fuse = FuseMount(
        MountTree(device, const [MountRoot(id: 'home', name: 'x')]),
        mountPoint: '/nowhere',
        name: 'x',
      )..debugReplies = (id, error, data) => replies[id] = (error, data);
      replies.clear();
    });

    Future<(int, ByteData)> ask(int opcode, int node, List<int> args) async {
      final id = ++unique;
      final header = ByteData(40)
        ..setUint32(0, 40 + args.length, Endian.little)
        ..setUint32(4, opcode, Endian.little)
        ..setUint64(8, id, Endian.little)
        ..setUint64(16, node, Endian.little);
      await fuse.debugHandle(
        Uint8List.fromList([...header.buffer.asUint8List(), ...args]),
      );
      final reply = replies[id]!;
      return (reply.$1, ByteData.sublistView(reply.$2));
    }

    List<int> le(List<(int, int)> fields) {
      final out = BytesBuilder();
      for (final (size, value) in fields) {
        final b = ByteData(size);
        size == 4
            ? b.setUint32(0, value, Endian.little)
            : b.setUint64(0, value, Endian.little);
        out.add(b.buffer.asUint8List());
      }
      return out.toBytes();
    }

    List<int> name(String n) => [...utf8.encode(n), 0];

    test('creates, writes, closes and renames', () async {
      // CREATE: fuse_create_in, then the name.
      final (error, created) = await ask(35, 1, [
        ...le([(4, 0x241), (4, 0x81a4), (4, 0x12), (4, 0)]),
        ...name('new.txt'),
      ]);
      expect(error, 0);
      expect(created.lengthInBytes, 128 + 16);
      final ino = created.getUint64(0, Endian.little);
      // fuse_attr.mode: a plain file the user may write
      expect(created.getUint32(40 + 60, Endian.little), 0x81a4);

      final data = utf8.encode('written through FUSE');
      final (writeError, wrote) = await ask(16, ino, [
        ...le([
          (8, 0),
          (8, 0),
          (4, data.length),
          (4, 0),
          (8, 0),
          (4, 0),
          (4, 0),
        ]),
        ...data,
      ]);
      expect(writeError, 0);
      expect(wrote.getUint32(0, Endian.little), data.length);
      expect(device.files['new.txt'], isEmpty);
      // FLUSH: close() waits for it to be in place.
      expect((await ask(25, ino, le([(8, 0), (4, 0), (4, 0), (8, 0)]))).$1, 0);
      expect(utf8.decode(device.files['new.txt']!), 'written through FUSE');

      // RENAME2 with RENAME_NOREPLACE onto a file there: refused.
      final (refused, _) = await ask(45, 1, [
        ...le([(8, 1), (4, 1), (4, 0)]),
        ...name('new.txt'),
        ...name('a.txt'),
      ]);
      expect(refused, -17);
      final (renamed, _) = await ask(12, 1, [
        ...le([(8, 1)]),
        ...name('new.txt'),
        ...name('b.txt'),
      ]);
      expect(renamed, 0);
      expect(device.files.keys, containsAll(['a.txt', 'b.txt']));
      expect((await ask(10, 1, name('b.txt'))).$1, 0, reason: 'UNLINK');
      expect(device.deleted, ['b.txt']);
    });

    test('truncates through SETATTR and sets times', () async {
      final (_, a) = await ask(1, 1, name('a.txt'));
      final ino = a.getUint64(0, Endian.little);
      // fuse_setattr_in: valid = SIZE | MTIME, size 2, mtime 2024-01-01.
      final args = Uint8List(88);
      final view = ByteData.sublistView(args)
        ..setUint32(0, 8 | 32, Endian.little)
        ..setUint64(16, 2, Endian.little)
        ..setUint64(40, 1704067200, Endian.little);
      expect(view.lengthInBytes, 88);
      final (error, attr) = await ask(4, ino, args);
      expect(error, 0);
      expect(attr.getUint64(16 + 8, Endian.little), 2, reason: 'size');
      await ask(25, ino, le([(8, 0), (4, 0), (4, 0), (8, 0)]));
      expect(utf8.decode(device.files['a.txt']!), 'he');
      expect(device.modified['a.txt'], 1704067200000);
    });

    test('mkdir, rmdir, and what a device cannot hold', () async {
      final (error, folder) = await ask(9, 1, [
        ...le([(4, 0x1ed), (4, 0x12)]),
        ...name('New'),
      ]);
      expect(error, 0);
      expect(folder.getUint32(40 + 60, Endian.little), 0x41ed);
      expect(device.folders, contains('New'));
      expect((await ask(11, 1, name('New'))).$1, 0);
      expect((await ask(6, 1, name('link'))).$1, -1, reason: 'SYMLINK');
      expect(
        (await ask(8, 1, [
          ...le([(4, 0x2000), (4, 0), (4, 0), (4, 0)]),
          ...name('dev'),
        ])).$1,
        -1,
        reason: 'only plain files',
      );
      final (_, statfs) = await ask(17, 1, const []);
      expect(
        statfs.getUint64(8, Endian.little),
        greaterThan(0),
        reason: 'free',
      );
    });
  });

  group('NFS writes', () {
    late _Device device;
    late NfsServer server;
    late _Rpc rpc;
    late Uint8List root;

    setUp(() async {
      device = _Device()
        ..files['a.txt'] = Uint8List.fromList(utf8.encode('hello'));
      server = NfsServer(
        MountTree(device, const [MountRoot(id: 'home', name: 'x')]),
        volumeName: 'x',
        readPatience: const Duration(milliseconds: 300),
      );
      await server.start();
      rpc = await _Rpc.connect(server.port);
      final mounted = await rpc.call(
        100005,
        1,
        (w) => w.string(server.exportPath),
      );
      expect(mounted.u32(), 0);
      root = mounted.opaque();
    });

    tearDown(() async {
      await rpc.close();
      await server.close();
    });

    void unset(_Writer w) {
      for (var i = 0; i < 4; i++) {
        w.u32(0); // mode, uid, gid, size: not set
      }
      w
        ..u32(0)
        ..u32(0); // atime, mtime: not changed
    }

    test('creates, writes unstable, commits, renames, removes', () async {
      final created = await rpc.call(100003, 8, (w) {
        w
          ..opaque(root)
          ..string('new.txt')
          ..u32(1); // GUARDED
        unset(w);
      });
      expect(created.u32(), 0);
      expect(created.u32(), 1);
      final handle = created.opaque();
      expect(created.postOp()!.mode & 0x1ff, 0x1a4);

      final again = await rpc.call(100003, 8, (w) {
        w
          ..opaque(root)
          ..string('new.txt')
          ..u32(1);
        unset(w);
      });
      expect(again.u32(), 17, reason: 'GUARDED: it is there');

      final data = utf8.encode('written through NFS');
      final wrote = await rpc.call(100003, 7, (w) {
        w
          ..opaque(handle)
          ..u64(0)
          ..u32(data.length)
          ..u32(0) // UNSTABLE
          ..opaque(data);
      });
      expect(wrote.u32(), 0);
      wrote
        ..u32()
        ..postOp();
      expect(wrote.u32(), data.length);
      expect(wrote.u32(), 0, reason: 'UNSTABLE');
      final verifier = wrote.fixed(8);
      expect(device.files['new.txt'], isEmpty);

      final committed = await rpc.call(100003, 21, (w) {
        w
          ..opaque(handle)
          ..u64(0)
          ..u32(0);
      });
      expect(committed.u32(), 0);
      committed
        ..u32()
        ..postOp();
      expect(committed.fixed(8), verifier);
      expect(utf8.decode(device.files['new.txt']!), 'written through NFS');

      final renamed = await rpc.call(100003, 14, (w) {
        w
          ..opaque(root)
          ..string('new.txt')
          ..opaque(root)
          ..string('b.txt');
      });
      expect(renamed.u32(), 0);
      final removed = await rpc.call(100003, 12, (w) {
        w
          ..opaque(root)
          ..string('b.txt');
      });
      expect(removed.u32(), 0);
      expect(device.deleted, ['b.txt']);

      final access = await rpc.call(100003, 4, (w) {
        w
          ..opaque(root)
          ..u32(0x3f);
      });
      expect(access.u32(), 0);
      access.postOp();
      expect(access.u32() & 0x1c, 0x1c, reason: 'modify, extend, delete');
    });

    test(
      'SETATTR truncates and sets the time; slow changes are not redone',
      () async {
        final looked = await rpc.call(100003, 3, (w) {
          w
            ..opaque(root)
            ..string('a.txt');
        });
        expect(looked.u32(), 0);
        final handle = looked.opaque();
        final set = await rpc.call(100003, 2, (w) {
          w
            ..opaque(handle)
            ..u32(0)
            ..u32(0)
            ..u32(0)
            ..u32(1)
            ..u64(2) // size
            ..u32(0)
            ..u32(2) // mtime: the client's
            ..u32(1704067200)
            ..u32(0)
            ..u32(0); // no guard
        });
        expect(set.u32(), 0);
        // In place once answered: the system sends no COMMIT after it.
        expect(utf8.decode(device.files['a.txt']!), 'he');
        expect(device.modified['a.txt'], 1704067200000);

        device.holdWrites = Completer<void>();
        Future<int> writeSync() async {
          final r = await rpc.call(100003, 7, (w) {
            w
              ..opaque(handle)
              ..u64(2)
              ..u32(3)
              ..u32(2) // FILE_SYNC
              ..opaque(utf8.encode('llo'));
          });
          return r.u32();
        }

        expect(await writeSync(), 10008, reason: 'try again');
        device.holdWrites!.complete();
        await pumpEventQueue();
        expect(await writeSync(), 0);
        expect(device.writes, hasLength(1), reason: 'the retry was the same');
        final committed = await rpc.call(100003, 21, (w) {
          w
            ..opaque(handle)
            ..u64(0)
            ..u32(0);
        });
        expect(committed.u32(), 0);
        expect(utf8.decode(device.files['a.txt']!), 'hello');
      },
    );
  });

  test('a read-only mount is mounted read-only', () {
    expect(MacNfsMount.options(1, writable: false), contains('rdonly'));
    expect(MacNfsMount.options(1, writable: true), isNot(contains('rdonly')));
    final fuse = File(
      'lib/remote_files/mount/fuse_linux.dart',
    ).readAsStringSync();
    expect(fuse, contains("if (!tree.writable) 'ro'"));
  });

  test('the socket layer carries writes to the browse host', () {
    expect(WhisperFrameType.browseWrite.code, 16);
    final svr = File('lib/socket/svrmanager.dart').readAsStringSync();
    expect(svr, contains('case WhisperFrameType.browseWrite:'));
    expect(svr, contains('FileBrowseHost.shared'));
    expect(svr, contains('RemoteFilesClient.sendWrite = _sendFileBrowseWrite'));
    expect(svr, contains('frame.type == WhisperFrameType.browseWrite) &&'));
    final mounts = File(
      'lib/remote_files/mount/remote_mounts.dart',
    ).readAsStringSync();
    expect(mounts, contains('writable: info.canWrite && !info.readOnly'));
  });
}

class _ReadOnly extends MountSource {
  @override
  Future<List<FsEntry>> list(String root, String path) async => const [];

  @override
  Future<Uint8List> read(String root, String path, int offset, int length) =>
      Future.value(Uint8List(0));
}

/// Speaks ONC RPC to an [NfsServer] the way the system's client does.
class _Rpc {
  _Rpc(this._socket) {
    _socket.listen((chunk) {
      _buffer.add(chunk);
      _drain();
    });
  }

  static Future<_Rpc> connect(int port) async =>
      _Rpc(await Socket.connect(InternetAddress.loopbackIPv4, port));

  final Socket _socket;
  final _buffer = BytesBuilder();
  final _waiting = <int, Completer<_Reader>>{};
  int _xid = 1;

  static final uid = DynamicLibrary.process()
      .lookupFunction<Uint32 Function(), int Function()>('getuid')();

  void _drain() {
    while (true) {
      final bytes = _buffer.toBytes();
      if (bytes.length < 4) {
        return;
      }
      final length = ByteData.sublistView(bytes).getUint32(0) & 0x7fffffff;
      if (bytes.length < 4 + length) {
        return;
      }
      final record = Uint8List.sublistView(bytes, 4, 4 + length);
      _buffer
        ..clear()
        ..add(Uint8List.sublistView(bytes, 4 + length));
      final reader = _Reader(Uint8List.fromList(record));
      _waiting.remove(reader.u32())?.complete(reader);
    }
  }

  Future<_Reader> call(
    int program,
    int procedure,
    void Function(_Writer w) args,
  ) async {
    final xid = _xid++;
    final w = _Writer()
      ..u32(xid)
      ..u32(0)
      ..u32(2)
      ..u32(program)
      ..u32(3)
      ..u32(procedure);
    final credential = _Writer()
      ..u32(0)
      ..string('test')
      ..u32(uid)
      ..u32(20)
      ..u32(0);
    w
      ..u32(1)
      ..opaque(credential.bytes())
      ..u32(0)
      ..u32(0);
    args(w);
    final body = w.bytes();
    final header = ByteData(4)..setUint32(0, 0x80000000 | body.length);
    final reply = Completer<_Reader>();
    _waiting[xid] = reply;
    _socket
      ..add(header.buffer.asUint8List())
      ..add(body);
    final r = await reply.future;
    expect(r.u32(), 1);
    expect(r.u32(), 0);
    r
      ..u32()
      ..opaque();
    expect(r.u32(), 0);
    return r;
  }

  Future<void> close() => _socket.close();
}

class _Writer {
  final _out = BytesBuilder();

  void u32(int v) =>
      _out.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());
  void u64(int v) =>
      _out.add((ByteData(8)..setUint64(0, v)).buffer.asUint8List());
  void opaque(List<int> data) {
    u32(data.length);
    _out.add(data);
    _out.add(Uint8List((4 - data.length % 4) % 4));
  }

  void string(String s) => opaque(utf8.encode(s));
  Uint8List bytes() => _out.toBytes();
}

class _Reader {
  _Reader(this._data);

  final Uint8List _data;
  late final _view = ByteData.sublistView(_data);
  int _at = 0;

  int u32() {
    final v = _view.getUint32(_at);
    _at += 4;
    return v;
  }

  int u64() {
    final v = _view.getUint64(_at);
    _at += 8;
    return v;
  }

  Uint8List fixed(int n) {
    final v = Uint8List.sublistView(_data, _at, _at + n);
    _at += n;
    return Uint8List.fromList(v);
  }

  Uint8List opaque() {
    final n = u32();
    final v = Uint8List.sublistView(_data, _at, _at + n);
    _at += n + (4 - n % 4) % 4;
    return v;
  }

  ({int type, int mode, int size, int ino}) attr() {
    final type = u32();
    final mode = u32();
    u32(); // nlink
    u32(); // uid
    u32(); // gid
    final size = u64();
    u64(); // used
    u32();
    u32(); // rdev
    u64(); // fsid
    final ino = u64();
    for (var i = 0; i < 6; i++) {
      u32();
    }
    return (type: type, mode: mode, size: size, ino: ino);
  }

  ({int type, int mode, int size, int ino})? postOp() =>
      u32() == 1 ? attr() : null;
}
