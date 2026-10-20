import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'mount_tree.dart';

/// A read-only NFSv3 server on 127.0.0.1 for one [MountTree]: what macOS
/// mounts with its own `mount_nfs`, so the other device's files show in
/// Finder without a kernel extension or a paid entitlement.
///
/// Only one mount, for this user: the export path is a secret, the first
/// MNT takes it, and calls from other users (but root) are refused.
class NfsServer {
  NfsServer(
    this.tree, {
    required String volumeName,
    this.readPatience = const Duration(seconds: 6),
    Random? random,
  }) : _random = random ?? Random.secure() {
    _secret = Uint8List.fromList(List.generate(8, (_) => _random.nextInt(256)));
    final token = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    // Finder names the volume after the last part of the export path.
    exportPath = '/$token/${volumeName.replaceAll('/', '∕')}';
    _fsid = _random.nextInt(1 << 32);
  }

  final MountTree tree;
  final Random _random;
  late final Uint8List _secret;
  late final int _fsid;

  /// What `mount_nfs` asks for: `localhost:<exportPath>`.
  late final String exportPath;

  ServerSocket? _server;
  final _sockets = <Socket>{};
  bool _mounted = false;

  /// The system unmounted it (Finder's eject, `umount`): told by its UMNT,
  /// which not every unmount sends.
  void Function()? onUnmounted;

  /// The system's client hung up, as it does when unmounting (and when it
  /// reconnects).
  void Function()? onDisconnected;

  /// This process's user, who owns everything in the mount.
  static final _owner = _libc.lookupFunction<Uint32 Function(), int Function()>(
    'getuid',
  )();
  static final _ownerGroup = _libc
      .lookupFunction<Uint32 Function(), int Function()>('getgid')();
  static final _libc = DynamicLibrary.process();

  /// How long a call may wait for the other device before the system is
  /// told to try again (NFS3ERR_JUKEBOX), instead of the call failing.
  /// Every call is answered within it: the system takes a server silent
  /// for its timeout as dead and unmounts it (deadtimeout), which a busy
  /// phone otherwise caused while three computers read from it.
  final Duration readPatience;

  /// Past this, asked again and again for the same thing, the call fails:
  /// whatever waits for it (the app's own thread, even) gets an error
  /// instead of waiting for ever.
  static const _giveUpAfter = Duration(seconds: 30);
  static const _slowAnswer = Duration(seconds: 3);

  /// The procedure an RPC call names (for the log), or -1.
  static int _procedureOf(Uint8List message) =>
      message.length < 24 ? -1 : ByteData.sublistView(message).getUint32(20);
  final _retrying = <Object, DateTime>{};

  int get port => _server!.port;

  Future<void> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_serve);
  }

  Future<void> close() async {
    await _server?.close();
    _server = null;
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
  }

  void _serve(Socket socket) {
    _sockets.add(socket);
    // A connection reset fails the writing side as well; unheard, that
    // error would end the whole isolate.
    socket.done.ignore();
    final records = _RecordReader();
    socket.listen(
      (chunk) {
        records.add(chunk);
        for (final message in records.take()) {
          final asked = DateTime.now();
          unawaited(
            _call(message).then((reply) {
              final took = DateTime.now().difference(asked);
              if (took > _slowAnswer) {
                mountLog(
                  'nfs: call ${_procedureOf(message)} answered in '
                  '${took.inMilliseconds} ms',
                );
              }
              if (reply == null || !_sockets.contains(socket)) {
                return;
              }
              final header = ByteData(4)
                ..setUint32(0, 0x80000000 | reply.length);
              socket
                ..add(header.buffer.asUint8List())
                ..add(reply);
            }, onError: (Object _) {}),
          );
        }
      },
      onDone: () => _hungUp(socket),
      onError: (Object _) => _hungUp(socket),
      cancelOnError: true,
    );
  }

  void _hungUp(Socket socket) {
    // Close our half too: mount_nfs hangs up its MOUNT connection right
    // away, and left half-open it is reset a minute later.
    socket.destroy();
    if (_sockets.remove(socket) && _server != null) {
      mountLog('nfs: a client hung up, ${_sockets.length} left');
      onDisconnected?.call();
    }
  }

  Future<Uint8List?> _call(Uint8List message) async {
    final r = _Xdr(message);
    final w = _XdrOut();
    try {
      final xid = r.u32();
      if (r.u32() != 0) {
        return null; // not a CALL
      }
      w
        ..u32(xid)
        ..u32(1); // REPLY
      if (r.u32() != 2) {
        w
          ..u32(1) // MSG_DENIED
          ..u32(0) // RPC_MISMATCH
          ..u32(2)
          ..u32(2);
        return w.bytes();
      }
      final program = r.u32();
      final version = r.u32();
      final procedure = r.u32();
      final flavor = r.u32();
      final credential = r.opaque();
      r
        ..u32()
        ..opaque();
      final caller = flavor == 1 ? _unixCaller(credential) : null;
      if ((program == _nfsProgram || program == _mountProgram) &&
          version != 3) {
        w
          ..u32(0) // MSG_ACCEPTED
          ..u32(0)
          ..u32(0)
          ..u32(2) // PROG_MISMATCH
          ..u32(3)
          ..u32(3);
        return w.bytes();
      }
      final body = program == _mountProgram
          ? _mount(procedure, r)
          : program == _nfsProgram
          ? await _nfs(procedure, r, caller)
          : null;
      w
        ..u32(0) // MSG_ACCEPTED
        ..u32(0) // verifier AUTH_NONE
        ..u32(0);
      if (body == null) {
        // PROG_UNAVAIL or PROC_UNAVAIL
        w.u32(program == _mountProgram || program == _nfsProgram ? 3 : 1);
      } else {
        w
          ..u32(0)
          ..raw(body);
      }
      return w.bytes();
    } on RangeError {
      w
        ..u32(0)
        ..u32(0)
        ..u32(0)
        ..u32(4); // GARBAGE_ARGS
      return w.bytes();
    }
  }

  ({int uid, int gid})? _unixCaller(Uint8List credential) {
    try {
      final c = _Xdr(credential)
        ..u32()
        ..opaque();
      return (uid: c.u32(), gid: c.u32());
    } on RangeError {
      return null;
    }
  }

  Uint8List? _mount(int procedure, _Xdr r) {
    final w = _XdrOut();
    switch (procedure) {
      case 0:
        return w.bytes();
      case 3: // UMNT
      case 4: // UMNTALL
        if (_mounted) {
          scheduleMicrotask(() => onUnmounted?.call());
        }
        return w.bytes();
      case 1: // MNT
        final path = r.string();
        if (path != exportPath || _mounted) {
          w.u32(_errAccess);
          return w.bytes();
        }
        _mounted = true;
        w
          ..u32(0)
          ..opaque(_handle(MountTree.rootIno))
          ..u32(1)
          ..u32(1); // AUTH_UNIX
        return w.bytes();
      case 5: // EXPORT
        w.boolean(false);
        return w.bytes();
    }
    return null;
  }

  Uint8List _handle(int ino) {
    final out = Uint8List(16)..setRange(0, 8, _secret);
    ByteData.sublistView(out).setUint64(8, ino);
    return out;
  }

  int? _ino(Uint8List handle) {
    if (handle.length != 16) {
      return null;
    }
    for (var i = 0; i < 8; i++) {
      if (handle[i] != _secret[i]) {
        return null;
      }
    }
    return ByteData.sublistView(handle).getUint64(8);
  }

  Future<Uint8List?> _nfs(
    int procedure,
    _Xdr r,
    ({int uid, int gid})? caller,
  ) async {
    if (procedure == 0) {
      return Uint8List(0);
    }
    if (procedure > 21) {
      return null;
    }
    final w = _XdrOut();
    final handle = r.opaque();
    final allowed = caller != null && (caller.uid == _owner || caller.uid == 0);
    final ino = _ino(handle);
    final node = ino == null ? null : tree.node(ino);
    if (!allowed || node == null || node.gone) {
      w.u32(!allowed ? _errAccess : _errStale);
      _failureBody(procedure, w);
      return w.bytes();
    }
    try {
      switch (procedure) {
        case 1: // GETATTR
          // What is known answers when looking again takes long; the new
          // listing lands for the next one.
          final stat = tree.stat(node.ino);
          final fresh = await stat.timeout(
            _attrPatience,
            onTimeout: () {
              stat.ignore();
              return node;
            },
          );
          w.u32(_ok);
          _attr(w, fresh);
        case 3: // LOOKUP
          final name = r.string();
          MountNode? child;
          if (name == '.') {
            child = node;
          } else if (name == '..') {
            child = tree.node(node.parent);
          } else {
            child = await _patiently((
              'lookup',
              node.ino,
              name,
            ), tree.lookup(node.ino, name));
          }
          if (child == null) {
            w.u32(_errNoEntry);
            _postOp(w, node);
          } else {
            w
              ..u32(_ok)
              ..opaque(_handle(child.ino));
            _postOp(w, child);
            _postOp(w, node);
          }
        case 4: // ACCESS
          final wanted = r.u32();
          w.u32(_ok);
          _postOp(w, node);
          // Read, look up, execute; never change anything.
          w.u32(wanted & (node.isDir ? 0x23 : 0x21));
        case 6: // READ
          final offset = r.u64();
          final count = r.u32().clamp(0, _maxRead);
          if (node.isDir) {
            w.u32(_errIsDir);
            _postOp(w, node);
            break;
          }
          final data = await _patiently((
            'read',
            node.ino,
            offset,
          ), tree.read(node.ino, offset, count));
          w.u32(_ok);
          _postOp(w, node);
          w
            ..u32(data.length)
            ..boolean(offset + data.length >= node.size)
            ..opaque(data);
        case 16: // READDIR
        case 17: // READDIRPLUS
          final plus = procedure == 17;
          final cookie = r.u64();
          r.fixed(8);
          final dirCount = r.u32();
          final maxCount = plus ? r.u32() : dirCount;
          if (!node.isDir) {
            w.u32(_errNotDir);
            _postOp(w, node);
            break;
          }
          final children = await _patiently((
            'list',
            node.ino,
          ), tree.children(node.ino));
          w.u32(_ok);
          _postOp(w, node);
          w.fixed(Uint8List(8));
          var size = 0;
          var eof = true;
          for (var i = cookie; i < children.length; i++) {
            final child = children[i];
            final entry = _XdrOut()
              ..boolean(true)
              ..u64(child.ino)
              ..string(child.name)
              ..u64(i + 1);
            if (plus) {
              _postOp(entry, child);
              entry
                ..boolean(true)
                ..opaque(_handle(child.ino));
            }
            final bytes = entry.bytes();
            // Room for the reply's own fields around the entries.
            if (size + bytes.length + 128 > maxCount) {
              eof = false;
              break;
            }
            size += bytes.length;
            w.raw(bytes);
          }
          w
            ..boolean(false)
            ..boolean(eof);
        case 18: // FSSTAT
          w.u32(_ok);
          _postOp(w, node);
          w
            ..u64(1 << 40)
            ..u64(0)
            ..u64(0)
            ..u64(1 << 24)
            ..u64(0)
            ..u64(0)
            ..u32(0);
        case 19: // FSINFO
          w.u32(_ok);
          _postOp(w, node);
          w
            ..u32(_maxRead) // rtmax
            ..u32(_maxRead) // rtpref
            ..u32(4096) // rtmult
            ..u32(_maxRead) // wtmax
            ..u32(_maxRead) // wtpref
            ..u32(4096) // wtmult
            ..u32(64 * 1024) // dtpref
            ..u64(0x7fffffffffffffff) // maxfilesize
            ..u32(0) // time_delta: 1 ms
            ..u32(1000000)
            ..u32(0x08 | 0x10); // HOMOGENEOUS | CANSETTIME
        case 20: // PATHCONF
          w.u32(_ok);
          _postOp(w, node);
          w
            ..u32(1) // linkmax
            ..u32(255) // name_max
            ..boolean(true) // no_trunc
            ..boolean(true) // chown_restricted
            ..boolean(false) // case_insensitive: names are looked up as is
            ..boolean(true); // case_preserving
        case 5: // READLINK
          w.u32(_errNotSupported);
          _postOp(w, node);
        default:
          // Everything that would change something.
          w.u32(_errReadOnly);
          _failureBody(procedure, w);
      }
    } on _TryLater {
      final failure = _XdrOut()..u32(_errJukebox);
      _failureBody(procedure, failure);
      return failure.bytes();
    } on MountException catch (error) {
      final failure = _XdrOut()..u32(_status(error.error));
      _failureBody(procedure, failure, node: node);
      return failure.bytes();
    }
    return w.bytes();
  }

  /// [work] if done within [readPatience]; otherwise the system is told to
  /// try again while it goes on, for the retry to find it done.
  Future<T> _patiently<T>(Object key, Future<T> work) async {
    try {
      final result = await work.timeout(
        readPatience,
        onTimeout: () {
          work.ignore();
          final first = _retrying[key];
          if (first == null) {
            _retrying[key] = DateTime.now();
            mountLog('nfs: $key is slow, told to try again');
          } else if (DateTime.now().difference(first) > _giveUpAfter) {
            mountLog('nfs: $key gave up');
            throw const MountException(MountError.io);
          }
          throw const _TryLater();
        },
      );
      _retrying.remove(key);
      return result;
    } on MountException {
      _retrying.remove(key);
      rethrow;
    }
  }

  Duration get _attrPatience => readPatience < const Duration(seconds: 1)
      ? readPatience
      : const Duration(seconds: 1);

  int _status(MountError error) => switch (error) {
    MountError.notFound => _errNoEntry,
    MountError.notDir => _errNotDir,
    MountError.isDir => _errIsDir,
    MountError.io || MountError.offline => _errIo,
  };

  /// What follows a failure status, by procedure.
  void _failureBody(int procedure, _XdrOut w, {MountNode? node}) {
    switch (procedure) {
      case 1: // GETATTR: nothing
        break;
      case 3: // LOOKUP: dir attributes
      case 4: // ACCESS
      case 5: // READLINK
      case 6: // READ
      case 16:
      case 17:
      case 18:
      case 19:
      case 20:
        _postOp(w, node);
      case 14: // RENAME: two wcc_data
        _noWcc(w);
        _noWcc(w);
      case 15: // LINK: file attributes, then the folder's wcc_data
        w.boolean(false);
        _noWcc(w);
      default: // SETATTR, WRITE, CREATE, MKDIR, SYMLINK, MKNOD, REMOVE,
        // RMDIR, COMMIT
        _noWcc(w);
    }
  }

  void _noWcc(_XdrOut w) => w
    ..boolean(false)
    ..boolean(false);

  void _postOp(_XdrOut w, MountNode? node) {
    if (node == null) {
      w.boolean(false);
      return;
    }
    w.boolean(true);
    _attr(w, node);
  }

  void _attr(_XdrOut w, MountNode node) {
    final dir = node.isDir;
    final size = dir ? 4096 : node.size;
    w
      ..u32(dir ? 2 : 1) // NF3DIR / NF3REG
      ..u32(dir ? 0x16d : 0x124) // 0555 / 0444
      ..u32(dir ? 2 : 1)
      ..u32(_owner)
      ..u32(_ownerGroup)
      ..u64(size)
      ..u64(size)
      ..u32(0)
      ..u32(0)
      ..u64(_fsid)
      ..u64(node.ino);
    final seconds = node.modifiedMs ~/ 1000;
    final nanos = (node.modifiedMs % 1000) * 1000000;
    for (var i = 0; i < 3; i++) {
      w
        ..u32(seconds)
        ..u32(nanos);
    }
  }

  static const _mountProgram = 100005;
  static const _nfsProgram = 100003;
  static const _maxRead = 1024 * 1024;
  static const _ok = 0;
  static const _errNoEntry = 2;
  static const _errIo = 5;
  static const _errAccess = 13;
  static const _errNotDir = 20;
  static const _errIsDir = 21;
  static const _errReadOnly = 30;
  static const _errStale = 70;
  static const _errNotSupported = 10004;
  static const _errJukebox = 10008;
}

class _TryLater implements Exception {
  const _TryLater();
}

/// Record marking (RFC 5531 §11): fragments of a record, the last one
/// flagged, each with a 4-byte length.
class _RecordReader {
  final _chunks = <Uint8List>[];
  int _buffered = 0;
  final _fragments = BytesBuilder(copy: false);

  void add(Uint8List chunk) {
    _chunks.add(chunk);
    _buffered += chunk.length;
  }

  List<Uint8List> take() {
    final records = <Uint8List>[];
    while (_buffered >= 4) {
      final header = ByteData.sublistView(_peek(4)).getUint32(0);
      final length = header & 0x7fffffff;
      if (_buffered < 4 + length) {
        break;
      }
      _consume(4);
      _fragments.add(_consume(length));
      if (header & 0x80000000 != 0) {
        records.add(_fragments.takeBytes());
      }
    }
    return records;
  }

  Uint8List _peek(int count) {
    final out = Uint8List(count);
    var at = 0;
    for (final chunk in _chunks) {
      final n = min(count - at, chunk.length);
      out.setRange(at, at + n, chunk);
      at += n;
      if (at == count) {
        break;
      }
    }
    return out;
  }

  Uint8List _consume(int count) {
    final out = Uint8List(count);
    var at = 0;
    while (at < count) {
      final chunk = _chunks.first;
      final n = min(count - at, chunk.length);
      out.setRange(at, at + n, chunk);
      at += n;
      if (n == chunk.length) {
        _chunks.removeAt(0);
      } else {
        _chunks[0] = Uint8List.sublistView(chunk, n);
      }
    }
    _buffered -= count;
    return out;
  }
}

class _Xdr {
  _Xdr(this._data) : _view = ByteData.sublistView(_data);

  final Uint8List _data;
  final ByteData _view;
  int _at = 0;

  int u32() {
    final value = _view.getUint32(_at);
    _at += 4;
    return value;
  }

  int u64() {
    final value = _view.getUint64(_at);
    _at += 8;
    return value;
  }

  Uint8List fixed(int length) {
    if (_at + length > _data.length) {
      throw RangeError('short');
    }
    final value = Uint8List.sublistView(_data, _at, _at + length);
    _at += length;
    return value;
  }

  Uint8List opaque() {
    final length = u32();
    final value = fixed(length);
    _at += (4 - length % 4) % 4;
    return value;
  }

  String string() => utf8.decode(opaque(), allowMalformed: true);
}

class _XdrOut {
  final _out = BytesBuilder(copy: false);

  void u32(int value) =>
      _out.add((ByteData(4)..setUint32(0, value)).buffer.asUint8List());

  void u64(int value) =>
      _out.add((ByteData(8)..setUint64(0, value)).buffer.asUint8List());

  void boolean(bool value) => u32(value ? 1 : 0);

  void fixed(Uint8List data) {
    _out.add(data);
    final pad = (4 - data.length % 4) % 4;
    if (pad > 0) {
      _out.add(Uint8List(pad));
    }
  }

  void opaque(Uint8List data) {
    u32(data.length);
    fixed(data);
  }

  void string(String value) => opaque(utf8.encode(value));

  void raw(Uint8List data) => _out.add(data);

  Uint8List bytes() => _out.toBytes();
}
