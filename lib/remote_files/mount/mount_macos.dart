import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// macOS's own NFS client mounting an [NfsServer] on 127.0.0.1: no kernel
/// extension, no administrator.
abstract final class MacNfsMount {
  /// Soft, so a call fails instead of hanging when Whisper is gone, and
  /// marked dead (unmounted by the system) ten seconds after that;
  /// `mutejukebox` keeps a slow device's "try again" out of the system's
  /// "server not responding" dialog. `dumbtimer` holds the client to
  /// `timeo`: estimated from quick answers, its timeout shrank to a second
  /// or so, and a busy phone's reads failed (ETIMEDOUT) and got the mount
  /// declared dead, though every call is answered within the server's
  /// patience. Read-only unless the device takes changes. `nobrowse`:
  /// Finder would list it under its server, whose item fails on a click
  /// (Finder asks the server for its shares, which NFS cannot list); it is
  /// put in the sidebar as a disk instead ([MacSidebar]).
  static List<String> options(int port, {bool writable = false}) => [
    'vers=3',
    'tcp',
    'port=$port',
    'mountport=$port',
    if (!writable) 'rdonly' else 'wsize=1048576',
    'locallocks',
    'soft',
    'intr',
    'timeo=100',
    'dumbtimer',
    'retrans=3',
    'deadtimeout=10',
    'mutejukebox',
    'noquota',
    'rdirplus',
    'rsize=1048576',
    'actimeo=2',
    'nobrowse',
  ];

  static Future<void> mount({
    required int port,
    required String export,
    required String mountPoint,
    bool writable = false,
  }) async {
    await Directory(mountPoint).create(recursive: true);
    final result = await Process.run('/sbin/mount_nfs', [
      '-o',
      options(port, writable: writable).join(','),
      'localhost:$export',
      mountPoint,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        '/sbin/mount_nfs',
        const [],
        '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
  }

  /// Unmounts [mountPoint], by force when something still has it open
  /// (its files are gone with the other device anyway).
  static Future<bool> unmount(String mountPoint) async {
    var result = await Process.run('/sbin/umount', [mountPoint]);
    if (result.exitCode != 0) {
      result = await Process.run('/sbin/umount', ['-f', mountPoint]);
    }
    if (result.exitCode == 0) {
      try {
        await Directory(mountPoint).delete();
      } on FileSystemException {
        // Something else was put there; leave it.
      }
    }
    return result.exitCode == 0;
  }

  /// NFS mount points under [base], Whisper's own folder: left from a run
  /// that did not get to unmount them (whatever name it mounted by).
  static Future<List<String>> mountedUnder(String base) async {
    final result = await Process.run('/sbin/mount', const []);
    if (result.exitCode != 0) {
      return const [];
    }
    return pointsIn('${result.stdout}', base);
  }

  /// [mountedUnder] from what `mount` printed.
  static List<String> pointsIn(String listing, String base) {
    final prefix = base.endsWith('/') ? base : '$base/';
    final points = <String>[];
    for (final line in listing.split('\n')) {
      // "localhost:/<token>/<name> on <point> (nfs, ...)"; the name may
      // hold spaces, the point is under [base].
      final at = line.indexOf(' on $prefix');
      final end = line.lastIndexOf(' (nfs');
      if (at < 0 || end < at) {
        continue;
      }
      points.add(line.substring(at + 4, end));
    }
    return points;
  }
}

/// The volumes in Finder's sidebar ("位置"), through LSSharedFileList:
/// deprecated since macOS 10.11 and still the only way in. A mount there
/// opens on a click, like a disk; its server's item would not (Finder asks
/// it for its shares, which NFS cannot list). Whisper's own items carry
/// [_markKey] (the mount's path): found by it even with the mount gone, and
/// nobody else's ever touched.
abstract final class MacSidebar {
  static const _markKey = 'com.vireen.whisper.mount';

  /// Puts [path] last there unless it is there already.
  static bool add(String path) => _with((list, items) {
    if (_find(items, (mark) => mark == path) != null) {
      return true;
    }
    final count = items == nullptr ? 0 : _count(items);
    // After the last one: the system's "last" marker is not an item it
    // takes from here (it crashed a test that passed it).
    final after = count > 0
        ? _at(items, count - 1)
        : _services.lookup<Pointer<Void>>('kLSSharedFileListItemLast').value;
    final native = path.toNativeUtf8();
    final url = _fileUrl(nullptr, native.cast(), native.length, 1);
    final key = _string(_markKey);
    final value = _string(path);
    final keys = calloc<Pointer<Void>>()..value = key;
    final values = calloc<Pointer<Void>>()..value = value;
    final properties = _dictionary(
      nullptr,
      keys,
      values,
      1,
      _foundation.lookup<Void>('kCFTypeDictionaryKeyCallBacks'),
      _foundation.lookup<Void>('kCFTypeDictionaryValueCallBacks'),
    );
    final item = _insert(
      list,
      after,
      nullptr,
      nullptr,
      url,
      properties,
      nullptr,
    );
    for (final object in [url, key, value, properties]) {
      _release(object);
    }
    calloc
      ..free(native)
      ..free(keys)
      ..free(values);
    if (item == nullptr) {
      return false;
    }
    _release(item);
    return true;
  });

  /// Takes [path] out again.
  static bool remove(String path) => _removeAll((mark) => mark == path);

  /// Takes out every one of Whisper's: what a run before this one left.
  static bool removeAll() => _removeAll((_) => true);

  static bool _removeAll(bool Function(String mark) which) {
    // One at a time, each from a fresh look at the list.
    for (var i = 0; i < 64; i++) {
      var found = false;
      final ok = _with((list, items) {
        final item = _find(items, which);
        if (item == null) {
          return true;
        }
        found = true;
        return _remove(list, item) == 0;
      });
      if (!ok) {
        return false;
      }
      if (!found) {
        return true;
      }
    }
    return true;
  }

  static bool _with(
    bool Function(Pointer<Void> list, Pointer<Void> items) work,
  ) {
    try {
      final list = _create(
        nullptr,
        _services
            .lookup<Pointer<Void>>('kLSSharedFileListFavoriteVolumes')
            .value,
        nullptr,
      );
      if (list == nullptr) {
        return false;
      }
      final items = _snapshot(list, nullptr);
      try {
        return work(list, items);
      } finally {
        if (items != nullptr) {
          _release(items);
        }
        _release(list);
      }
    } catch (_) {
      return false;
    }
  }

  /// The first of Whisper's items whose mark [which] takes.
  static Pointer<Void>? _find(
    Pointer<Void> items,
    bool Function(String mark) which,
  ) {
    if (items == nullptr) {
      return null;
    }
    final key = _string(_markKey);
    final buffer = calloc<Uint8>(_pathMax);
    try {
      for (var i = 0; i < _count(items); i++) {
        final item = _at(items, i);
        final mark = _property(item, key);
        if (mark == nullptr) {
          continue;
        }
        final text =
            _typeOf(mark) == _stringType() &&
            _cString(mark, buffer.cast(), _pathMax, _utf8) != 0;
        _release(mark);
        if (text && which(buffer.cast<Utf8>().toDartString())) {
          return item;
        }
      }
      return null;
    } finally {
      _release(key);
      calloc.free(buffer);
    }
  }

  static Pointer<Void> _string(String text) {
    final native = text.toNativeUtf8();
    try {
      return _createString(nullptr, native, _utf8);
    } finally {
      calloc.free(native);
    }
  }

  static const _pathMax = 1024;

  /// kCFStringEncodingUTF8.
  static const _utf8 = 0x08000100;

  static final _foundation = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
  );
  static final _services = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreServices.framework/CoreServices',
  );

  static final _create = _services
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)
      >('LSSharedFileListCreate');

  static final _snapshot = _services
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint32>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint32>)
      >('LSSharedFileListCopySnapshot');

  static final _property = _services
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>)
      >('LSSharedFileListItemCopyProperty');

  static final _insert = _services
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
        )
      >('LSSharedFileListInsertItemURL');

  static final _remove = _services
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)
      >('LSSharedFileListItemRemove');

  static final _count = _foundation
      .lookupFunction<
        IntPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CFArrayGetCount');

  static final _at = _foundation
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int)
      >('CFArrayGetValueAtIndex');

  static final _fileUrl = _foundation
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, IntPtr, Uint8),
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, int, int)
      >('CFURLCreateFromFileSystemRepresentation');

  static final _createString = _foundation
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32),
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int)
      >('CFStringCreateWithCString');

  static final _cString = _foundation
      .lookupFunction<
        Uint8 Function(Pointer<Void>, Pointer<Utf8>, IntPtr, Uint32),
        int Function(Pointer<Void>, Pointer<Utf8>, int, int)
      >('CFStringGetCString');

  static final _typeOf = _foundation
      .lookupFunction<
        UintPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CFGetTypeID');

  static final _stringType = _foundation
      .lookupFunction<UintPtr Function(), int Function()>('CFStringGetTypeID');

  static final _dictionary = _foundation
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          IntPtr,
          Pointer<Void>,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          int,
          Pointer<Void>,
          Pointer<Void>,
        )
      >('CFDictionaryCreate');

  static final _release = _foundation
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CFRelease');
}
