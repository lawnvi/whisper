import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'mount_tree.dart';

/// A [MountTree] mounted with FUSE, speaking the kernel's protocol
/// (fuse_kernel.h) directly: `fusermount3` (setuid, part of every desktop
/// that runs AppImages) mounts it for this user and hands back the
/// `/dev/fuse` descriptor, so nothing needs root and nothing links
/// libfuse.
///
/// One isolate blocks reading requests; this one answers them, each as it
/// can, so a slow read never holds up a listing.
class FuseMount {
  FuseMount(this.tree, {required this.mountPoint, required this.name});

  final MountTree tree;
  final String mountPoint;

  /// What the system calls it (`fsname`, shown by `mount` and `df`).
  final String name;

  /// The system took it away (`fusermount3 -u`, the file manager's eject).
  void Function()? onEnded;

  /// Replies go here instead of /dev/fuse.
  @visibleForTesting
  void Function(int unique, int error, Uint8List data)? debugReplies;

  /// Answers one request as read from /dev/fuse.
  @visibleForTesting
  Future<void> debugHandle(Uint8List request) => _handle(request);

  int _fd = -1;
  int _watchdog = -1;
  int _pid = 0;
  Isolate? _reader;
  ReceivePort? _requests;
  bool _ended = false;

  static const _maxWrite = 1024 * 1024;

  /// Whether this system can mount: FUSE in the kernel and a
  /// `fusermount3` (or `fusermount`) to do it for this user.
  static Future<String?> helper() async {
    if (!await File('/dev/fuse').exists()) {
      return null;
    }
    for (final dir in const ['/usr/bin', '/bin', '/usr/local/bin']) {
      for (final name in const ['fusermount3', 'fusermount']) {
        final path = '$dir/$name';
        if (await File(path).exists()) {
          return path;
        }
      }
    }
    return null;
  }

  /// Whether [point] is a FUSE mount right now.
  static Future<bool> isMounted(String point) async {
    try {
      final mounts = await File('/proc/mounts').readAsLines();
      return mounts.any((line) => _mountPointOf(line) == point);
    } on FileSystemException {
      return false;
    }
  }

  /// Whisper's mounts under [base] left by a run that could not take them
  /// away (its watchdog normally does).
  static Future<void> unmountAllUnder(String base) async {
    final helper = await FuseMount.helper();
    if (helper == null) {
      return;
    }
    final List<String> mounts;
    try {
      mounts = await File('/proc/mounts').readAsLines();
    } on FileSystemException {
      return;
    }
    for (final line in mounts) {
      final fields = line.split(' ');
      final point = _mountPointOf(line);
      if (fields.length > 2 &&
          fields[2] == 'fuse.whisper' &&
          point != null &&
          point.startsWith('$base/')) {
        await Process.run(helper, ['-u', '-z', point]);
      }
    }
    // Folders of mounts that went with a crash (their watchdog unmounted
    // them); only empty ones.
    try {
      await for (final entry in Directory(base).list()) {
        if (entry is Directory && !await isMounted(entry.path)) {
          try {
            await entry.delete();
          } on FileSystemException {
            // Something is in it: not ours to remove.
          }
        }
      }
      await Directory(base).delete();
    } on FileSystemException {
      // No folder, or still something in it.
    }
  }

  /// The mount point of a /proc/mounts line (spaces escaped as \040).
  static String? _mountPointOf(String line) {
    final fields = line.split(' ');
    if (fields.length < 2) {
      return null;
    }
    return fields[1].replaceAllMapped(
      RegExp(r'\\([0-7]{3})'),
      (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 8)),
    );
  }

  Future<void> start() async {
    final helper = await FuseMount.helper();
    if (helper == null) {
      throw const FileSystemException('no FUSE on this system');
    }
    await Directory(mountPoint).create(recursive: true);
    final mounted = _libc.mount(helper, mountPoint, [
      'nosuid',
      'nodev',
      'ro',
      'default_permissions',
      'auto_unmount',
      'fsname=${name.replaceAll(RegExp(r'[,\\]'), ' ')}',
      'subtype=whisper',
    ]);
    _fd = mounted.fd;
    _watchdog = mounted.socket;
    _pid = mounted.pid;
    final requests = ReceivePort();
    _requests = requests;
    requests.listen(_onRequest);
    _reader = await Isolate.spawn(_readLoop, (_fd, requests.sendPort));
  }

  /// Unmounts it: lazily, so a file manager still showing it lets go.
  Future<void> stop() async {
    if (_ended) {
      return;
    }
    final helper = await FuseMount.helper();
    if (helper != null) {
      await Process.run(helper, ['-u', '-z', mountPoint]);
    }
    _finish();
  }

  void _finish() {
    if (_ended) {
      return;
    }
    _ended = true;
    _requests?.close();
    _reader?.kill(priority: Isolate.immediate);
    if (_fd >= 0) {
      _libc.close(_fd);
    }
    // The watchdog fusermount unmounts once this closes, then exits.
    if (_watchdog >= 0) {
      _libc.close(_watchdog);
    }
    if (_pid > 0) {
      _libc.reap(_pid);
    }
    _fd = _watchdog = -1;
    try {
      Directory(mountPoint).deleteSync();
    } on FileSystemException {
      // Still busy, or something else is there.
    }
  }

  void _onRequest(Object? message) {
    if (message == null) {
      // ENODEV: unmounted from outside.
      final wasEnded = _ended;
      _finish();
      if (!wasEnded) {
        onEnded?.call();
      }
      return;
    }
    final bytes = (message as TransferableTypedData)
        .materialize()
        .asUint8List();
    unawaited(_handle(bytes));
  }

  Future<void> _handle(Uint8List request) async {
    final view = ByteData.sublistView(request);
    final opcode = view.getUint32(4, Endian.little);
    final unique = view.getUint64(8, Endian.little);
    final nodeid = view.getUint64(16, Endian.little);
    final body = Uint8List.sublistView(request, 40);
    final args = ByteData.sublistView(body);
    try {
      switch (opcode) {
        case _init:
          _reply(unique, _initReply(args));
        case _destroy:
          _reply(unique, Uint8List(0));
        case _forget:
        case _batchForget:
        case _interrupt:
          break; // no answer
        case _lookup:
          final name = _cString(body);
          final child = await tree.lookup(nodeid, name);
          if (child == null) {
            _error(unique, _enoent);
          } else {
            _reply(unique, _entry(child));
          }
        case _getattr:
          final node = await tree.stat(nodeid);
          final out = _Out(104)
            ..u64(1)
            ..u32(0)
            ..u32(0);
          _attr(out, node);
          _reply(unique, out.bytes);
        case _open:
          final flags = args.getUint32(0, Endian.little);
          final node = tree.node(nodeid);
          if (node == null || node.gone) {
            _error(unique, _enoent);
          } else if (node.isDir) {
            _error(unique, _eisdir);
          } else if (flags & 3 != 0) {
            _error(unique, _erofs);
          } else {
            // Keep what was read while it is unchanged (AUTO_INVAL_DATA
            // drops it when its size or time changes).
            _reply(
              unique,
              (_Out(16)
                    ..u64(0)
                    ..u32(_keepCache)
                    ..u32(0))
                  .bytes,
            );
          }
        case _opendir:
          final node = tree.node(nodeid);
          if (node == null || node.gone) {
            _error(unique, _enoent);
          } else if (!node.isDir) {
            _error(unique, _enotdir);
          } else {
            _reply(
              unique,
              (_Out(16)
                    ..u64(0)
                    ..u32(0)
                    ..u32(0))
                  .bytes,
            );
          }
        case _read:
          final offset = args.getUint64(8, Endian.little);
          final size = args.getUint32(16, Endian.little);
          _reply(unique, await tree.read(nodeid, offset, size));
        case _readdir:
        case _readdirplus:
          final offset = args.getUint64(8, Endian.little);
          final size = args.getUint32(16, Endian.little);
          _reply(
            unique,
            await _listing(nodeid, offset, size, plus: opcode == _readdirplus),
          );
        case _release:
        case _releasedir:
        case _flush:
        case _fsync:
        case _fsyncdir:
          _reply(unique, Uint8List(0));
        case _statfs:
          final out = _Out(80)
            ..u64(1 << 28) // blocks
            ..u64(0) // free
            ..u64(0) // available
            ..u64(1 << 24) // files
            ..u64(0)
            ..u32(4096) // bsize
            ..u32(255) // namelen
            ..u32(4096); // frsize
          _reply(unique, out.bytes);
        case _access:
          final mask = args.getUint32(0, Endian.little);
          if (mask & 2 != 0) {
            _error(unique, _erofs);
          } else {
            _reply(unique, Uint8List(0));
          }
        case _setattr:
        case _mknod:
        case _mkdir:
        case _unlink:
        case _rmdir:
        case _rename:
        case _rename2:
        case _link:
        case _symlink:
        case _write:
        case _create:
        case _setxattr:
        case _removexattr:
        case _fallocate:
        case _tmpfile:
          _error(unique, _erofs);
        default:
          // xattrs, locks, ioctl, lseek: not here.
          _error(unique, _enosys);
      }
    } on MountException catch (error) {
      _error(unique, switch (error.error) {
        MountError.notFound => _enoent,
        MountError.notDir => _enotdir,
        MountError.isDir => _eisdir,
        MountError.io || MountError.offline => _eio,
      });
    } catch (_) {
      _error(unique, _eio);
    }
  }

  Uint8List _initReply(ByteData args) {
    final major = args.getUint32(0, Endian.little);
    final minor = args.getUint32(4, Endian.little);
    final readahead = args.getUint32(8, Endian.little);
    final offered = args.getUint32(12, Endian.little);
    if (major != 7) {
      // Only major 7 has ever existed; the kernel retries with ours.
      return (_Out(8)
            ..u32(7)
            ..u32(31))
          .bytes;
    }
    const wanted =
        _asyncRead |
        _autoInvalData |
        _doReaddirplus |
        _parallelDirops |
        _maxPages;
    final out = _Out(64)
      ..u32(7)
      ..u32(minor < 31 ? minor : 31)
      ..u32(readahead < _maxWrite ? readahead : _maxWrite)
      ..u32(offered & wanted)
      ..u16(16) // max_background
      ..u16(12) // congestion_threshold
      ..u32(_maxWrite)
      ..u32(1) // time_gran: 1 ns
      ..u16(_maxWrite ~/ 4096) // max_pages
      ..u16(0)
      ..u32(0);
    return out.bytes;
  }

  Future<Uint8List> _listing(
    int ino,
    int offset,
    int size, {
    required bool plus,
  }) async {
    final node = tree.node(ino);
    if (node == null) {
      throw const MountException(MountError.notFound);
    }
    final children = await tree.children(ino);
    final entries = <(String, MountNode?, int)>[
      ('.', node, ino),
      ('..', tree.node(node.parent), node.parent),
      for (final child in children) (child.name, child, child.ino),
    ];
    final out = BytesBuilder(copy: false);
    var used = 0;
    for (var i = offset; i < entries.length; i++) {
      final (name, entry, entryIno) = entries[i];
      final nameBytes = utf8.encode(name);
      final direntSize = (24 + nameBytes.length + 7) & ~7;
      final total = direntSize + (plus ? 128 : 0);
      if (used + total > size) {
        break;
      }
      if (plus) {
        if (i < 2 || entry == null) {
          // The system ignores "." and ".." here; no inode is lent.
          out.add(Uint8List(128));
        } else {
          out.add(_entry(entry));
        }
      }
      final dirent = _Out(direntSize)
        ..u64(entryIno)
        ..u64(i + 1)
        ..u32(nameBytes.length)
        ..u32(entry?.isDir ?? true ? 4 : 8)
        ..raw(nameBytes);
      out.add(dirent.bytes);
      used += total;
    }
    return out.takeBytes();
  }

  Uint8List _entry(MountNode node) {
    final out = _Out(128)
      ..u64(node.ino)
      ..u64(0) // generation
      ..u64(1) // entry_valid: seconds
      ..u64(1) // attr_valid
      ..u32(0)
      ..u32(0);
    _attr(out, node);
    return out.bytes;
  }

  void _attr(_Out out, MountNode node) {
    final size = node.isDir ? 4096 : node.size;
    final seconds = node.modifiedMs ~/ 1000;
    final nanos = (node.modifiedMs % 1000) * 1000000;
    out
      ..u64(node.ino)
      ..u64(size)
      ..u64((size + 511) ~/ 512)
      ..u64(seconds)
      ..u64(seconds)
      ..u64(seconds)
      ..u32(nanos)
      ..u32(nanos)
      ..u32(nanos)
      ..u32(node.isDir ? 0x416d : 0x8124) // dir 0555, file 0444
      ..u32(node.isDir ? 2 : 1)
      ..u32(_libc.uid)
      ..u32(_libc.gid)
      ..u32(0) // rdev
      ..u32(4096) // blksize
      ..u32(0);
  }

  void _reply(int unique, Uint8List data) => _send(unique, 0, data);

  void _error(int unique, int errno) => _send(unique, -errno, Uint8List(0));

  void _send(int unique, int error, Uint8List data) {
    if (debugReplies case final replies?) {
      replies(unique, error, data);
      return;
    }
    if (_ended || _fd < 0) {
      return;
    }
    final header = ByteData(16)
      ..setUint32(0, 16 + data.length, Endian.little)
      ..setInt32(4, error, Endian.little)
      ..setUint64(8, unique, Endian.little);
    _libc.writeAll(_fd, header.buffer.asUint8List(), data);
  }

  static String _cString(Uint8List body) {
    final end = body.indexOf(0);
    return utf8.decode(
      end < 0 ? body : Uint8List.sublistView(body, 0, end),
      allowMalformed: true,
    );
  }

  /// The reading isolate: one request per read(2), until the mount goes.
  static void _readLoop((int, SendPort) args) {
    final (fd, port) = args;
    final libc = _Libc();
    const size = _maxWrite + 64 * 1024;
    final buffer = malloc<Uint8>(size);
    try {
      while (true) {
        final n = libc.read(fd, buffer, size);
        if (n > 0) {
          port.send(
            TransferableTypedData.fromList([
              Uint8List.fromList(buffer.asTypedList(n)),
            ]),
          );
          continue;
        }
        final errno = libc.errno;
        // EINTR, or ENOENT (a request taken back before it was read).
        if (n < 0 && (errno == 4 || errno == 2 || errno == 11)) {
          continue;
        }
        port.send(null); // ENODEV: unmounted
        return;
      }
    } finally {
      malloc.free(buffer);
    }
  }

  static final _libc = _Libc();

  static const _lookup = 1;
  static const _forget = 2;
  static const _getattr = 3;
  static const _setattr = 4;
  static const _symlink = 6;
  static const _mknod = 8;
  static const _mkdir = 9;
  static const _unlink = 10;
  static const _rmdir = 11;
  static const _rename = 12;
  static const _link = 13;
  static const _open = 14;
  static const _read = 15;
  static const _write = 16;
  static const _statfs = 17;
  static const _release = 18;
  static const _fsync = 20;
  static const _setxattr = 21;
  static const _removexattr = 24;
  static const _flush = 25;
  static const _init = 26;
  static const _opendir = 27;
  static const _readdir = 28;
  static const _releasedir = 29;
  static const _fsyncdir = 30;
  static const _access = 34;
  static const _create = 35;
  static const _interrupt = 36;
  static const _destroy = 38;
  static const _batchForget = 42;
  static const _fallocate = 43;
  static const _readdirplus = 44;
  static const _rename2 = 45;
  static const _tmpfile = 51;

  static const _asyncRead = 1 << 0;
  static const _autoInvalData = 1 << 12;
  static const _doReaddirplus = 1 << 13;
  static const _parallelDirops = 1 << 18;
  static const _maxPages = 1 << 22;
  static const _keepCache = 1 << 1;

  static const _enoent = 2;
  static const _eio = 5;
  static const _enotdir = 20;
  static const _eisdir = 21;
  static const _erofs = 30;
  static const _enosys = 38;
}

/// Little-endian struct writer of a fixed size (zero-filled tail).
class _Out {
  _Out(int size) : bytes = Uint8List(size) {
    _view = ByteData.sublistView(bytes);
  }

  final Uint8List bytes;
  late final ByteData _view;
  int _at = 0;

  void u16(int v) {
    _view.setUint16(_at, v, Endian.little);
    _at += 2;
  }

  void u32(int v) {
    _view.setUint32(_at, v, Endian.little);
    _at += 4;
  }

  void u64(int v) {
    _view.setUint64(_at, v, Endian.little);
    _at += 8;
  }

  void raw(List<int> data) {
    bytes.setRange(_at, _at + data.length, data);
    _at += data.length;
  }
}

/// The few libc calls mounting takes.
class _Libc {
  _Libc() : _lib = DynamicLibrary.process();

  final DynamicLibrary _lib;

  late final _socketpair = _lib
      .lookupFunction<
        Int32 Function(Int32, Int32, Int32, Pointer<Int32>),
        int Function(int, int, int, Pointer<Int32>)
      >('socketpair');
  // fcntl is variadic: its third argument goes as one.
  late final _fcntl = _lib
      .lookupFunction<
        Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
        int Function(int, int, int)
      >('fcntl');
  late final _posixSpawn = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<Int32>,
          Pointer<Utf8>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Pointer<Utf8>>,
          Pointer<Pointer<Utf8>>,
        ),
        int Function(
          Pointer<Int32>,
          Pointer<Utf8>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Pointer<Utf8>>,
          Pointer<Pointer<Utf8>>,
        )
      >('posix_spawn');
  late final _recvmsg = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, Int32),
        int Function(int, Pointer<Uint8>, int)
      >('recvmsg');
  late final _waitpid = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Int32>, Int32),
        int Function(int, Pointer<Int32>, int)
      >('waitpid');
  late final _close = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  late final _read = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('read');
  late final _writev = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, Int32),
        int Function(int, Pointer<Uint8>, int)
      >('writev');
  late final _errnoLocation = _lib
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__errno_location',
      );
  late final uid = _lib.lookupFunction<Uint32 Function(), int Function()>(
    'getuid',
  )();
  late final gid = _lib.lookupFunction<Uint32 Function(), int Function()>(
    'getgid',
  )();

  int get errno => _errnoLocation().value;

  int read(int fd, Pointer<Uint8> buffer, int size) => _read(fd, buffer, size);

  int close(int fd) => _close(fd);

  /// Leaves no zombie behind; the watchdog exits once its socket closes.
  void reap(int pid) {
    final status = calloc<Int32>();
    _waitpid(pid, status, 1); // WNOHANG
    calloc.free(status);
  }

  /// One reply in one write, as /dev/fuse wants it.
  void writeAll(int fd, Uint8List header, Uint8List data) {
    final total = header.length + data.length;
    final buffer = malloc<Uint8>(total);
    final iov = calloc<Uint8>(16);
    try {
      buffer.asTypedList(total)
        ..setAll(0, header)
        ..setAll(header.length, data);
      final view = iov.cast<IntPtr>();
      view[0] = buffer.address;
      view[1] = total;
      _writev(fd, iov, 1);
    } finally {
      malloc.free(buffer);
      calloc.free(iov);
    }
  }

  /// Runs [helper] (fusermount3) to mount [mountPoint] with [options];
  /// it passes the `/dev/fuse` descriptor back over a socket pair
  /// (`_FUSE_COMMFD`), and with `auto_unmount` stays on as a watchdog that
  /// unmounts when that socket closes (Whisper quit, or crashed).
  ({int fd, int socket, int pid}) mount(
    String helper,
    String mountPoint,
    List<String> options,
  ) {
    final fds = calloc<Int32>(2);
    final pid = calloc<Int32>();
    final allocated = <Pointer>[];
    Pointer<Utf8> s(String value) {
      final p = value.toNativeUtf8();
      allocated.add(p);
      return p;
    }

    try {
      if (_socketpair(1 /* AF_UNIX */, 1 /* SOCK_STREAM */, 0, fds) != 0) {
        throw FileSystemException('socketpair failed ($errno)');
      }
      final ours = fds[1];
      final theirs = fds[0];
      _fcntl(ours, 2 /* F_SETFD */, 1 /* FD_CLOEXEC */);
      final args = [helper, '-o', options.join(','), '--', mountPoint];
      final argv = calloc<Pointer<Utf8>>(args.length + 1);
      allocated.add(argv);
      for (var i = 0; i < args.length; i++) {
        argv[i] = s(args[i]);
      }
      argv[args.length] = nullptr;
      final env = [
        '_FUSE_COMMFD=$theirs',
        'PATH=/usr/bin:/bin:/usr/sbin:/sbin',
      ];
      final envp = calloc<Pointer<Utf8>>(env.length + 1);
      allocated.add(envp);
      for (var i = 0; i < env.length; i++) {
        envp[i] = s(env[i]);
      }
      envp[env.length] = nullptr;
      final spawned = _posixSpawn(pid, argv[0], nullptr, nullptr, argv, envp);
      _close(theirs);
      if (spawned != 0) {
        _close(ours);
        throw FileSystemException('could not run $helper ($spawned)');
      }
      final fd = _receiveFd(ours);
      if (fd < 0) {
        _close(ours);
        reap(pid.value);
        throw FileSystemException('$helper did not mount $mountPoint');
      }
      _fcntl(fd, 2, 1);
      return (fd: fd, socket: ours, pid: pid.value);
    } finally {
      for (final p in allocated) {
        calloc.free(p);
      }
      calloc.free(fds);
      calloc.free(pid);
    }
  }

  /// One descriptor sent with SCM_RIGHTS.
  int _receiveFd(int socket) {
    // struct msghdr (56 bytes on 64-bit Linux), one iovec of one byte, and
    // room for one cmsghdr carrying an int.
    final msg = calloc<Uint8>(56);
    final iov = calloc<IntPtr>(2);
    final byte = calloc<Uint8>(8);
    final control = calloc<Uint8>(64);
    try {
      iov[0] = byte.address;
      iov[1] = 1;
      final m = msg.cast<IntPtr>();
      // msg_name, msg_namelen, msg_iov, msg_iovlen, msg_control,
      // msg_controllen, msg_flags
      m[2] = iov.address;
      m[3] = 1;
      m[4] = control.address;
      m[5] = 24; // CMSG_SPACE(sizeof(int))
      int n;
      do {
        n = _recvmsg(socket, msg, 0);
      } while (n < 0 && errno == 4);
      if (n <= 0) {
        return -1;
      }
      final header = control.cast<IntPtr>();
      final level = control.cast<Int32>()[2];
      final type = control.cast<Int32>()[3];
      if (header[0] < 20 || level != 1 /* SOL_SOCKET */ || type != 1) {
        return -1; // not SCM_RIGHTS
      }
      return control.cast<Int32>()[4];
    } finally {
      calloc.free(msg);
      calloc.free(iov);
      calloc.free(byte);
      calloc.free(control);
    }
  }
}
