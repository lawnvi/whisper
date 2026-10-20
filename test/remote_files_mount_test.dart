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

/// A folder tree in memory, counting what is asked of it.
class _FakeSource implements MountSource {
  final folders = <String, List<FsEntry>>{};
  final files = <String, Uint8List>{};
  final reads = <(String, int)>[];
  int lists = 0;
  Completer<void>? holdReads;
  Completer<void>? holdLists;

  /// Offsets read once as half of what was asked, like a read() that
  /// returns early.
  final shortOnce = <int>{};

  void file(String path, Uint8List data, {int modifiedMs = 1000}) {
    files[path] = data;
    _entry(
      path,
      FsEntry(
        name: p.posix.basename(path),
        isDir: false,
        size: data.length,
        modifiedMs: modifiedMs,
      ),
    );
  }

  void folder(String path) {
    folders.putIfAbsent(path, () => []);
    if (path.contains('/')) {
      _entry(
        path,
        FsEntry(
          name: p.posix.basename(path),
          isDir: true,
          size: 0,
          modifiedMs: 1000,
        ),
      );
    }
  }

  void _entry(String path, FsEntry entry) {
    final parent = p.posix.dirname(path);
    final list = folders.putIfAbsent(parent, () => []);
    list
      ..removeWhere((e) => e.name == entry.name)
      ..add(entry);
  }

  @override
  Future<List<FsEntry>> list(String root, String path) async {
    lists++;
    await holdLists?.future;
    final key = path.isEmpty ? root : '$root/$path';
    final entries = folders[key];
    if (entries == null) {
      throw const MountException(MountError.notFound);
    }
    return [...entries];
  }

  @override
  Future<Uint8List> read(
    String root,
    String path,
    int offset,
    int length,
  ) async {
    reads.add((path, offset));
    await holdReads?.future;
    final data = files['$root/$path']!;
    var end = (offset + length).clamp(0, data.length);
    if (shortOnce.remove(offset)) {
      end = offset + (end - offset) ~/ 2;
    }
    return Uint8List.sublistView(data, offset.clamp(0, end), end);
  }
}

Uint8List _bytes(int length, [int seed = 7]) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed) & 0xff));

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
      final xid = reader.u32();
      _waiting.remove(xid)?.complete(reader);
    }
  }

  /// The procedure's result body (after accept_stat SUCCESS).
  Future<_Reader> call(
    int program,
    int procedure,
    void Function(_Writer w) args, {
    int? asUid,
  }) async {
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
      ..u32(asUid ?? uid)
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
    expect(r.u32(), 1, reason: 'REPLY');
    expect(r.u32(), 0, reason: 'MSG_ACCEPTED');
    r
      ..u32()
      ..opaque();
    expect(r.u32(), 0, reason: 'SUCCESS');
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

  Uint8List opaque() {
    final n = u32();
    final v = Uint8List.sublistView(_data, _at, _at + n);
    _at += n + (4 - n % 4) % 4;
    return v;
  }

  String string() => utf8.decode(opaque());

  /// fattr3: (type, size, fileid).
  ({int type, int size, int ino, int uid}) attr() {
    final type = u32();
    u32(); // mode
    u32(); // nlink
    final uid = u32();
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
    return (type: type, size: size, ino: ino, uid: uid);
  }

  ({int type, int size, int ino, int uid})? postOp() =>
      u32() == 1 ? attr() : null;
}

const _nfs = 100003;
const _mountd = 100005;

void main() {
  group('reads through the browse session', () {
    late Directory sandbox;
    late FileBrowseHost host;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      sandbox = await Directory.systemTemp.createTemp('whisper-mount-');
      await File(p.join(sandbox.path, 'big.bin')).writeAsBytes(_bytes(300000));
      await Directory(p.join(sandbox.path, 'Folder')).create();
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
        // As a frame does: through bytes, back to the client.
        final frame = WhisperFrameV3.decode(
          WhisperFrameV3(
            type: WhisperFrameType.browseData,
            transferId: sessionId,
            offset: offset,
            sequence: requestId,
            payload: data,
          ).encode(),
        );
        scheduleMicrotask(
          () => RemoteFilesClient.handleData(
            remotePeerId: 'host',
            sessionId: frame.transferId,
            requestId: frame.sequence,
            data: Uint8List.fromList(frame.payload),
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
    });

    tearDown(() => sandbox.delete(recursive: true));

    test('a newer host says so and reads any part of a file', () async {
      final client = RemoteFilesClient('host');
      final info = await client.open();
      expect(info.canRead, isTrue);
      final expected = _bytes(300000);
      final middle = await client.read('home', 'big.bin', 123457, 65536);
      expect(middle, expected.sublist(123457, 123457 + 65536));
      // At the end of the file: what there is.
      final tail = await client.read('home', 'big.bin', 299990, 4096);
      expect(tail, expected.sublist(299990));
      expect(await client.read('home', 'big.bin', 400000, 10), isEmpty);
      await client.close();
    });

    test('bad ranges, folders and missing files fail the read only', () async {
      final client = RemoteFilesClient('host');
      await client.open();
      Matcher fails(String reason) => throwsA(
        isA<RemoteFsException>().having((e) => e.reason, 'reason', reason),
      );
      await expectLater(
        client.read('home', 'big.bin', 0, 0),
        fails(FileBrowseError.notAllowed),
      );
      await expectLater(
        client.read('home', 'big.bin', 0, FileBrowseRead.maxLength + 1),
        fails(FileBrowseError.notAllowed),
      );
      await expectLater(
        client.read('home', 'Folder', 0, 10),
        fails(FileBrowseError.io),
      );
      await expectLater(
        client.read('home', 'nope.bin', 0, 10),
        fails(FileBrowseError.notFound),
      );
      await expectLater(
        client.read('home', '../outside', 0, 10),
        fails(FileBrowseError.notAllowed),
      );
      // The session is still good.
      expect(await client.read('home', 'big.bin', 0, 4), _bytes(4));
      await client.close();
    });

    test('a host that cannot send data does not offer reads', () async {
      host.sendData = null;
      final client = RemoteFilesClient('host');
      expect((await client.open()).canRead, isFalse);
      await client.close();
    });

    test('a mount lists folders page by page', () async {
      for (var i = 0; i < FsHostFiles.pageSize + 20; i++) {
        await File(p.join(sandbox.path, 'Folder', 'f$i.txt')).writeAsString('');
      }
      final client = RemoteFilesClient('host');
      await client.open();
      final source = RemoteMountSource(client);
      final entries = await source.list('home', 'Folder');
      expect(entries, hasLength(FsHostFiles.pageSize + 20));
      await expectLater(
        source.read('home', 'nope', 0, 1),
        throwsA(
          isA<MountException>().having(
            (e) => e.error,
            'error',
            MountError.notFound,
          ),
        ),
      );
      await client.close();
    });

    test('the session ending is heard by whoever holds it', () async {
      final client = RemoteFilesClient('host');
      await client.open();
      RemoteFilesClient.peerGone('host');
      expect((await client.gone).reason, 'offline');
    });
  });

  group('mount tree', () {
    late _FakeSource source;

    setUp(() {
      source = _FakeSource()
        ..folder('home')
        ..folder('home/Docs')
        ..file('home/Docs/a.txt', utf8.encode('hello'))
        ..file('home/big.bin', _bytes(5 * MountReader.blockSize + 10))
        ..folder('sd');
    });

    test('several roots are top folders; one root is the top', () async {
      final two = MountTree(source, const [
        MountRoot(id: 'home', name: '主目录'),
        MountRoot(id: 'sd', name: 'SD 卡'),
      ]);
      final tops = await two.children(MountTree.rootIno);
      expect(tops.map((n) => n.name), ['主目录', 'SD 卡']);
      expect(source.lists, 0, reason: 'the top is not asked for');
      final home = await two.lookup(MountTree.rootIno, '主目录');
      final docs = await two.lookup(home!.ino, 'Docs');
      expect(docs!.isDir, isTrue);
      expect((await two.lookup(docs.ino, 'a.txt'))!.size, 5);

      final one = MountTree(source, const [MountRoot(id: 'home', name: 'x')]);
      final names = (await one.children(MountTree.rootIno)).map((n) => n.name);
      expect(names, containsAll(['Docs', 'big.bin']));
    });

    test('listings are kept a while, then asked for again', () async {
      var now = DateTime(2026);
      final tree = MountTree(source, const [
        MountRoot(id: 'home', name: 'x'),
      ], clock: () => now);
      await tree.children(MountTree.rootIno);
      await tree.children(MountTree.rootIno);
      expect(source.lists, 1);
      final before = (await tree.lookup(MountTree.rootIno, 'big.bin'))!;
      now = now.add(const Duration(seconds: 4));
      source.file('home/big.bin', _bytes(20, 3), modifiedMs: 2000);
      source.folders['home']!.removeWhere((e) => e.name == 'Docs');
      final after = (await tree.lookup(MountTree.rootIno, 'big.bin'))!;
      expect(source.lists, 2);
      expect(after.ino, before.ino, reason: 'a file keeps its number');
      expect(after.size, 20);
      expect(after.generation, 1);
      expect(await tree.lookup(MountTree.rootIno, 'Docs'), isNull);
    });

    test('names the system cannot show are left out', () async {
      source.folders['home']!.addAll(const [
        FsEntry(name: 'a/b', isDir: false, size: 1, modifiedMs: 0),
        FsEntry(
          name: 'NTUSER.DAT',
          isDir: false,
          size: 1,
          modifiedMs: 0,
          hidden: true,
        ),
        FsEntry(
          name: '.zshrc',
          isDir: false,
          size: 1,
          modifiedMs: 0,
          hidden: true,
        ),
      ]);
      final tree = MountTree(source, const [MountRoot(id: 'home', name: 'x')]);
      final names = (await tree.children(MountTree.rootIno)).map((n) => n.name);
      expect(names, isNot(contains('a/b')));
      expect(names, isNot(contains('a∕b')));
      // Hidden over there and not by its name: Finder would show it.
      expect(names, isNot(contains('NTUSER.DAT')));
      expect(names, contains('.zshrc'));
    });

    test('blocks are read once, ahead while reading on, and again after a '
        'change', () async {
      var now = DateTime(2026);
      final tree = MountTree(source, const [
        MountRoot(id: 'home', name: 'x'),
      ], clock: () => now);
      final big = (await tree.lookup(MountTree.rootIno, 'big.bin'))!;
      final expected = _bytes(5 * MountReader.blockSize + 10);
      // Across a block edge: two blocks, plus one read ahead.
      final edge = await tree.read(big.ino, MountReader.blockSize - 5, 10);
      expect(
        edge,
        expected.sublist(MountReader.blockSize - 5, MountReader.blockSize + 5),
      );
      await pumpEventQueue();
      expect(source.reads.map((r) => r.$2 ~/ MountReader.blockSize).toSet(), {
        0,
        1,
      });
      // Reading on from there: the next blocks are fetched before asked.
      source.reads.clear();
      await tree.read(
        big.ino,
        MountReader.blockSize + 5,
        MountReader.blockSize,
      );
      await pumpEventQueue();
      expect(
        source.reads.map((r) => r.$2 ~/ MountReader.blockSize).toSet(),
        containsAll([2, 3]),
      );
      // Two readers of the same block: one fetch.
      source.reads.clear();
      source.holdReads = Completer<void>();
      final a = tree.read(big.ino, 5 * MountReader.blockSize, 5);
      final b = tree.read(big.ino, 5 * MountReader.blockSize + 2, 5);
      source.holdReads!.complete();
      expect((await a).length, 5);
      expect((await b).length, 5);
      expect(
        source.reads.where((r) => r.$2 == 5 * MountReader.blockSize),
        hasLength(1),
      );
      // Past the end: nothing, and nothing asked.
      source.reads.clear();
      expect(await tree.read(big.ino, 99 * MountReader.blockSize, 5), isEmpty);
      expect(source.reads, isEmpty);
      // Changed over there: read again.
      now = now.add(const Duration(seconds: 4));
      source.file(
        'home/big.bin',
        _bytes(5 * MountReader.blockSize + 10, 9),
        modifiedMs: 5000,
      );
      await tree.stat(big.ino);
      final fresh = await tree.read(big.ino, 0, 4);
      expect(fresh, _bytes(4, 9));
    });

    test('a block the device sends short is read to its end', () async {
      // Read on a phone's shared storage can return early; taken as the
      // whole block, the rest of it was served as nothing (zeros on a Mac).
      final tree = MountTree(source, const [MountRoot(id: 'home', name: 'x')]);
      final big = (await tree.lookup(MountTree.rootIno, 'big.bin'))!;
      final expected = _bytes(3 * MountReader.blockSize);
      source.shortOnce.add(MountReader.blockSize);
      final read = await tree.read(
        big.ino,
        MountReader.blockSize,
        MountReader.blockSize,
      );
      expect(
        read,
        expected.sublist(MountReader.blockSize, 2 * MountReader.blockSize),
      );
      expect(
        source.reads.where(
          (r) =>
              r.$2 > MountReader.blockSize && r.$2 < 2 * MountReader.blockSize,
        ),
        hasLength(1),
        reason: 'the rest of the block is asked for',
      );
    });
  });

  group('NFS server', () {
    late _FakeSource source;
    late NfsServer server;
    late _Rpc rpc;

    setUp(() async {
      source = _FakeSource()
        ..folder('home')
        ..folder('home/Docs')
        ..file('home/Docs/a.txt', utf8.encode('hello'))
        ..file('home/big.bin', _bytes(3 * MountReader.blockSize));
      server = NfsServer(
        MountTree(source, const [MountRoot(id: 'home', name: 'x')]),
        volumeName: '小新 的/电脑',
        readPatience: const Duration(milliseconds: 300),
      );
      await server.start();
      rpc = await _Rpc.connect(server.port);
    });

    tearDown(() async {
      await rpc.close();
      await server.close();
    });

    Future<Uint8List> mount() async {
      final r = await rpc.call(_mountd, 1, (w) => w.string(server.exportPath));
      expect(r.u32(), 0);
      return r.opaque();
    }

    test('the export is named for the volume and taken once', () async {
      expect(server.exportPath, endsWith('/小新 的∕电脑'));
      final wrong = await rpc.call(_mountd, 1, (w) => w.string('/x'));
      expect(wrong.u32(), 13);
      final root = await mount();
      expect(root, hasLength(16));
      final again = await rpc.call(
        _mountd,
        1,
        (w) => w.string(server.exportPath),
      );
      expect(again.u32(), 13, reason: 'one mount only');
    });

    test('a connection the client hangs up is closed here too', () async {
      // mount_nfs hangs up its MOUNT connection at once; a half left open
      // was reset a minute later and the error ended the mount's isolate.
      var hungUp = 0;
      server.onDisconnected = () => hungUp++;
      final client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final closed = Completer<void>();
      client.listen((_) {}, onDone: closed.complete);
      await client.close();
      await closed.future.timeout(const Duration(seconds: 5));
      expect(hungUp, 1);
    });

    test('looks up, lists, reads, and changes nothing', () async {
      final root = await mount();
      final attr = await rpc.call(_nfs, 1, (w) => w.opaque(root));
      expect(attr.u32(), 0);
      final rootAttr = attr.attr();
      expect(rootAttr.type, 2);
      expect(rootAttr.uid, _Rpc.uid);

      final listed = await rpc.call(_nfs, 17, (w) {
        w
          ..opaque(root)
          ..u64(0)
          ..u64(0)
          ..u32(8192)
          ..u32(65536);
      });
      expect(listed.u32(), 0);
      listed
        ..postOp()
        ..u64();
      final names = <String, Uint8List>{};
      while (listed.u32() == 1) {
        listed.u64();
        final name = listed.string();
        listed
          ..u64()
          ..postOp();
        expect(listed.u32(), 1);
        names[name] = listed.opaque();
      }
      expect(listed.u32(), 1, reason: 'eof');
      expect(names.keys, containsAll(['Docs', 'big.bin']));

      final looked = await rpc.call(_nfs, 3, (w) {
        w
          ..opaque(names['Docs']!)
          ..string('a.txt');
      });
      expect(looked.u32(), 0);
      final aTxt = looked.opaque();
      expect(looked.postOp()!.size, 5);

      final missing = await rpc.call(_nfs, 3, (w) {
        w
          ..opaque(root)
          ..string('nope');
      });
      expect(missing.u32(), 2);

      final read = await rpc.call(_nfs, 6, (w) {
        w
          ..opaque(names['big.bin']!)
          ..u64(MountReader.blockSize + 3)
          ..u32(100);
      });
      expect(read.u32(), 0);
      read.postOp();
      expect(read.u32(), 100);
      expect(read.u32(), 0, reason: 'not the end');
      expect(
        read.opaque(),
        _bytes(
          3 * MountReader.blockSize,
        ).sublist(MountReader.blockSize + 3, MountReader.blockSize + 103),
      );

      final end = await rpc.call(_nfs, 6, (w) {
        w
          ..opaque(aTxt)
          ..u64(0)
          ..u32(4096);
      });
      expect(end.u32(), 0);
      end.postOp();
      expect(end.u32(), 5);
      expect(end.u32(), 1, reason: 'eof');
      expect(utf8.decode(end.opaque()), 'hello');

      // WRITE, CREATE, REMOVE: a read-only file system.
      for (final procedure in [7, 8, 12]) {
        final refused = await rpc.call(_nfs, procedure, (w) {
          w
            ..opaque(root)
            ..string('x');
        });
        expect(refused.u32(), 30);
      }
    });

    test('other users and made-up handles are turned away', () async {
      final root = await mount();
      final other = await rpc.call(
        _nfs,
        1,
        (w) => w.opaque(root),
        asUid: _Rpc.uid + 1,
      );
      expect(other.u32(), 13);
      final forged = Uint8List.fromList(root)..[0] ^= 0xff;
      final stale = await rpc.call(_nfs, 1, (w) => w.opaque(forged));
      expect(stale.u32(), 70);
    });

    test('a slow device is told to try again, not failed', () async {
      final root = await mount();
      final listed = await rpc.call(_nfs, 3, (w) {
        w
          ..opaque(root)
          ..string('big.bin');
      });
      expect(listed.u32(), 0);
      final big = listed.opaque();
      source.holdReads = Completer<void>();
      final slow = await rpc.call(_nfs, 6, (w) {
        w
          ..opaque(big)
          ..u64(0)
          ..u32(10);
      });
      expect(slow.u32(), 10008, reason: 'NFS3ERR_JUKEBOX');
      source.holdReads!.complete();
    });

    test('every call is answered while the device is slow', () async {
      // Silent past its timeout, the system takes the server for dead and
      // unmounts it: a phone busy serving three computers caused that.
      var now = DateTime(2026);
      final slow = NfsServer(
        MountTree(source, const [
          MountRoot(id: 'home', name: 'x'),
        ], clock: () => now),
        volumeName: 'x',
        readPatience: const Duration(milliseconds: 300),
      );
      await slow.start();
      final client = await _Rpc.connect(slow.port);
      try {
        final mounted = await client.call(
          _mountd,
          1,
          (w) => w.string(slow.exportPath),
        );
        expect(mounted.u32(), 0);
        final root = mounted.opaque();
        Future<_Reader> lookup(Uint8List folder, String name) => client.call(
          _nfs,
          3,
          (w) => w
            ..opaque(folder)
            ..string(name),
        );
        final docsFound = await lookup(root, 'Docs');
        expect(docsFound.u32(), 0);
        final docs = docsFound.opaque();
        final fileFound = await lookup(docs, 'a.txt');
        expect(fileFound.u32(), 0);
        final file = fileFound.opaque();

        // Listed a while ago, and the device now slow to list again.
        now = now.add(const Duration(seconds: 10));
        source.holdLists = Completer<void>();
        final attr = await client.call(_nfs, 1, (w) => w.opaque(file));
        expect(attr.u32(), 0, reason: 'answered with what is known');
        expect(attr.attr().size, 5);
        expect((await lookup(docs, 'a.txt')).u32(), 10008);
        final listing = await client.call(_nfs, 17, (w) {
          w
            ..opaque(docs)
            ..u64(0)
            ..u64(0)
            ..u32(8192)
            ..u32(65536);
        });
        expect(listing.u32(), 10008);
        source.holdLists!.complete();
        // The retry finds it listed.
        expect((await lookup(docs, 'a.txt')).u32(), 0);
      } finally {
        await client.close();
        await slow.close();
      }
    });
  });

  group('FUSE requests', () {
    late _FakeSource source;
    late FuseMount fuse;
    final replies = <int, (int, Uint8List)>{};
    var unique = 0;

    setUp(() {
      source = _FakeSource()
        ..folder('home')
        ..folder('home/Docs')
        ..file('home/Docs/a.txt', utf8.encode('hello'))
        ..file('home/big.bin', _bytes(2 * MountReader.blockSize));
      fuse = FuseMount(
        MountTree(source, const [MountRoot(id: 'home', name: 'x')]),
        mountPoint: '/nowhere',
        name: 'x',
      )..debugReplies = (id, error, data) => replies[id] = (error, data);
      replies.clear();
    });

    /// fuse_in_header (40 bytes) and the opcode's arguments.
    Future<(int, ByteData)?> ask(int opcode, int node, List<int> args) async {
      final id = ++unique;
      final header = ByteData(40)
        ..setUint32(0, 40 + args.length, Endian.little)
        ..setUint32(4, opcode, Endian.little)
        ..setUint64(8, id, Endian.little)
        ..setUint64(16, node, Endian.little);
      await fuse.debugHandle(
        Uint8List.fromList([...header.buffer.asUint8List(), ...args]),
      );
      final reply = replies[id];
      return reply == null ? null : (reply.$1, ByteData.sublistView(reply.$2));
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

    test('agrees on the protocol and only what both sides support', () async {
      final (error, init) = (await ask(
        26,
        0,
        le([(4, 7), (4, 38), (4, 128 * 1024), (4, 0xffffffff)]),
      ))!;
      expect(error, 0);
      expect(init.lengthInBytes, 64);
      expect(init.getUint32(0, Endian.little), 7);
      expect(init.getUint32(4, Endian.little), 31);
      expect(init.getUint32(8, Endian.little), 128 * 1024);
      final flags = init.getUint32(12, Endian.little);
      expect(flags & (1 << 13), isNot(0), reason: 'READDIRPLUS');
      expect(flags & (1 << 5), 0, reason: 'nothing it did not ask for');
    });

    test('looks up, reads and lists; refuses writes', () async {
      final (_, docs) = (await ask(1, 1, name('Docs')))!;
      final docsIno = docs.getUint64(0, Endian.little);
      expect(docs.lengthInBytes, 128);
      // fuse_attr.mode: a folder
      expect(docs.getUint32(40 + 60, Endian.little) & 0xf000, 0x4000);
      final (_, a) = (await ask(1, docsIno, name('a.txt')))!;
      final aIno = a.getUint64(0, Endian.little);
      expect(a.getUint64(40 + 8, Endian.little), 5, reason: 'size');
      expect((await ask(1, 1, name('nope')))!.$1, -2);

      expect((await ask(14, aIno, le([(4, 0), (4, 0)])))!.$1, 0);
      expect(
        (await ask(14, aIno, le([(4, 1), (4, 0)])))!.$1,
        -30,
        reason: 'opened for writing: read-only',
      );
      final (_, read) = (await ask(
        15,
        aIno,
        le([(8, 0), (8, 0), (4, 4096), (4, 0)]),
      ))!;
      expect(
        utf8.decode(
          read.buffer.asUint8List(read.offsetInBytes, read.lengthInBytes),
        ),
        'hello',
      );

      final (_, listing) = (await ask(
        44,
        1,
        le([(8, 0), (8, 0), (4, 65536), (4, 0)]),
      ))!;
      final names = <String>[];
      var at = 0;
      while (at < listing.lengthInBytes) {
        final length = listing.getUint32(at + 128 + 16, Endian.little);
        final bytes = listing.buffer.asUint8List(
          listing.offsetInBytes + at + 128 + 24,
          length,
        );
        names.add(utf8.decode(bytes));
        at += 128 + ((24 + length + 7) & ~7);
      }
      expect(names, ['.', '..', 'Docs', 'big.bin']);

      expect((await ask(9, 1, name('new')))!.$1, -30, reason: 'MKDIR');
      expect((await ask(10, 1, name('big.bin')))!.$1, -30, reason: 'UNLINK');
      expect((await ask(22, 1, name('user.x')))!.$1, -38, reason: 'xattr');
      expect((await ask(17, 1, const []))!.$2.lengthInBytes, 80);
      expect(await ask(2, aIno, le([(8, 1)])), isNull, reason: 'FORGET');
    });
  });

  test('the Windows bridge and its Dart side agree', () {
    final native = File(
      'windows/cloud_files/cloud_files_bridge.cpp',
    ).readAsStringSync();
    final dart = File(
      'lib/remote_files/mount/cloud_files_windows.dart',
    ).readAsStringSync();
    List<String> fields(String source, String start, RegExp field) {
      final from = source.indexOf(start);
      final body = source.substring(from, source.indexOf('\n}', from));
      return [for (final m in field.allMatches(body)) m.group(1)!];
    }

    final request = fields(
      native,
      'struct WcfRequest {',
      RegExp(r'^\s+(?:int32_t|int64_t|wchar_t) (\w+)', multiLine: true),
    );
    final dartRequest = fields(
      dart,
      'final class _Request extends Struct {',
      RegExp(r'external (?:int|Array<Uint16>) (\w+);'),
    );
    String camel(String name) => name.replaceAllMapped(
      RegExp(r'_(\w)'),
      (m) => m.group(1)!.toUpperCase(),
    );
    expect(request.map(camel).toList(), dartRequest);
    expect(request.last, 'path');
    // Calls that can call back into the worker never run on its thread.
    for (final call in ['wcf_update', 'wcf_remove']) {
      final body = native.substring(native.indexOf('int32_t $call('));
      expect(
        body.substring(0, body.indexOf('return S_OK;')),
        contains('std::thread'),
      );
    }
    // Explorer asks for a folder only when showing it: folders in use are
    // looked at again, and placeholders are checked as they are on disk, so
    // an update that failed (file open) is made the next time.
    expect(dart, contains('Timer.periodic(_lookEvery'));
    expect(dart, contains('await _differs(itemPath, after)'));
    final cmake = File('windows/CMakeLists.txt').readAsStringSync();
    expect(cmake, contains('add_subdirectory("cloud_files")'));
    expect(cmake, contains('install(TARGETS whisper_cloud_files'));
  });

  test('mounts run in a worker that a stuck app thread cannot block', () {
    final mounts = File(
      'lib/remote_files/mount/remote_mounts.dart',
    ).readAsStringSync();
    expect(mounts, contains('MountWorker.start('));
    final worker = File(
      'lib/remote_files/mount/mount_worker.dart',
    ).readAsStringSync();
    expect(worker, contains('onExit: exits.sendPort'));
    expect(worker, contains('errorsAreFatal: false'));
    expect(worker, contains('MountWorker._patience'));
    // A mount is never listed by the device it is mounted on.
    expect(
      File('lib/remote_files/fs_host_files.dart').readAsStringSync(),
      contains('excluded()'),
    );
  });

  test('mount options keep a dead mount from hanging or nagging', () {
    final options = MacNfsMount.options(4242);
    expect(
      options,
      containsAll(['soft', 'mutejukebox', 'rdonly', 'dumbtimer']),
    );
    expect(options, contains('port=4242'));
    expect(options, contains('mountport=4242'));
    expect(options.any((o) => o.startsWith('deadtimeout=')), isTrue);
  });

  test('the socket layer carries reads only for hosts that offer them', () {
    expect(WhisperFrameType.browseData.code, 15);
    final svr = File('lib/socket/svrmanager.dart').readAsStringSync();
    expect(svr, contains('..sendData = _sendFileBrowseData'));
    expect(svr, contains('case WhisperFrameType.browseData:'));
    expect(svr, contains('RemoteFilesClient.handleData('));
    final mounts = File(
      'lib/remote_files/mount/remote_mounts.dart',
    ).readAsStringSync();
    expect(mounts, contains('if (!info.canRead)'));
    final shutdown = File('lib/page/deviceList.dart').readAsStringSync();
    expect(shutdown, contains('RemoteMounts.shared.unmountAll'));
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('RemoteMounts.shared.cleanUpStale()'));
  });
}
