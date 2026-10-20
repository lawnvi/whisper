import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'mount_tree.dart';

/// A [MountTree] as a Cloud Files sync root (windows/cloud_files): a
/// folder in Explorer's navigation pane, like OneDrive's, whose folders
/// are listed and files read only when something opens them.
///
/// Reads hand over at most [_firstServing] of what the system asks for (it
/// asks for whole files, Defender's scan of an opened file among them) and
/// tell it the rest is not coming, so it asks again for what a reader
/// really needs: a video can be skipped through without fetching all of
/// it. Read on from there, more goes each time.
class CloudFilesMount {
  CloudFilesMount(
    this.tree, {
    required this.path,
    required this.device,
    required this.name,
  });

  final MountTree tree;

  /// The sync root: %USERPROFILE%\Whisper\<name>.
  final String path;

  /// Which device it is (part of the sync root's id).
  final String device;
  final String name;

  int _session = 0;
  NativeCallable<Void Function(Pointer<_Request>)>? _listener;
  final _listed = <int, _Listed>{};
  final _canceled = <int>{};
  final _runs = <int, ({int frontier, int window})>{};

  /// Folders lately shown or read from, and when.
  final _inUse = <int, DateTime>{};
  Timer? _looking;
  bool _lookingNow = false;

  static const _chunk = 1024 * 1024;
  static const _firstServing = 4 * 1024 * 1024;
  static const _mostServing = 64 * 1024 * 1024;
  static const _refreshAfter = Duration(seconds: 3);
  static const _lookEvery = Duration(seconds: 5);
  static const _inUseFor = Duration(minutes: 10);
  static const _mostLookedAt = 32;

  static _Bridge? _loaded;

  static _Bridge get _bridge =>
      _loaded ??= _Bridge(DynamicLibrary.open('whisper_cloud_files.dll'));

  /// Takes away sync roots a run before this one left (it quit abruptly).
  static void unregisterStale() {
    try {
      _bridge.unregisterStale();
    } on ArgumentError {
      // No library next to the executable: nothing was ever mounted.
    }
  }

  Future<void> start() async {
    await Directory(path).create(recursive: true);
    final listener = NativeCallable<Void Function(Pointer<_Request>)>.listener(
      _onRequest,
    );
    _listener = listener;
    final error = calloc<Int32>();
    final nativePath = path.toNativeUtf16();
    final nativeDevice = device.toNativeUtf16();
    final nativeName = name.toNativeUtf16();
    final icon = '${Platform.resolvedExecutable},0'.toNativeUtf16();
    try {
      _session = _bridge.start(
        nativePath,
        nativeDevice,
        nativeName,
        icon,
        listener.nativeFunction,
        error,
      );
      if (_session == 0) {
        listener.close();
        _listener = null;
        throw FileSystemException(
          'Cloud Files refused the folder '
          '(0x${(error.value & 0xffffffff).toRadixString(16)})',
          path,
        );
      }
      _looking = Timer.periodic(_lookEvery, (_) => unawaited(_lookAgain()));
    } finally {
      for (final p in [nativePath, nativeDevice, nativeName, icon]) {
        calloc.free(p);
      }
      calloc.free(error);
    }
  }

  /// Disconnects, takes it out of Explorer and deletes what was read.
  Future<void> stop() async {
    final session = _session;
    if (session == 0) {
      return;
    }
    _session = 0;
    _looking?.cancel();
    _looking = null;
    _bridge.stop(session);
    _listener?.close();
    _listener = null;
    try {
      await Directory(path).delete(recursive: true);
    } on FileSystemException catch (error) {
      mountLog('mount: could not clear the folder: ${error.osError}');
    }
    try {
      await Directory(File(path).parent.path).delete();
    } on FileSystemException {
      // Another device is still mounted there.
    }
  }

  void _onRequest(Pointer<_Request> request) {
    unawaited(_handle(request));
  }

  Future<void> _handle(Pointer<_Request> request) async {
    final kind = request.ref.kind;
    try {
      switch (kind) {
        case 1:
          await _list(request);
        case 2:
          await _read(request);
        case 3:
          _canceled.add(request.ref.transferKey);
      }
    } catch (error) {
      mountLog('mount: request $kind failed: $error');
    } finally {
      _bridge.free(request);
    }
  }

  /// The system lists a folder each time it is shown: the first time it
  /// gets everything, later only what is new on the device, and what went
  /// or changed there is put right here once it has its answer.
  Future<void> _list(Pointer<_Request> request) async {
    if (_session == 0) {
      return;
    }
    final ino = request.ref.ino;
    final folder = _pathOf(request);
    _inUse[ino] = DateTime.now();
    final listed = _listed[ino];
    if (listed != null &&
        DateTime.now().difference(listed.at) < _refreshAfter) {
      _bridge.list(request, nullptr, 0, 0);
      return;
    }
    List<MountNode> children;
    try {
      children = await tree.children(ino);
    } on MountException {
      _bridge.list(request, nullptr, 0, listed == null ? 1 : 0);
      return;
    }
    final now = _snapshot(children);
    final added = listed == null
        ? children
        : [
            for (final child in children)
              if (!listed.items.containsKey(child.name)) child,
          ];
    _withEntries(added, (entries, count) {
      _bridge.list(request, entries, count, 0);
    });
    _listed[ino] = _Listed(folder, now);
    if (listed != null) {
      await _tidy(folder, listed.items, now, children);
    }
  }

  /// Takes away what went on the device and refreshes what changed.
  Future<void> _tidy(
    String folder,
    Map<String, ({bool isDir, int size, int modifiedMs})> before,
    Map<String, ({bool isDir, int size, int modifiedMs})> now,
    List<MountNode> children,
  ) async {
    for (final MapEntry(key: name, value: was) in before.entries) {
      final after = now[name];
      final itemPath = '$folder\\$name';
      if (after == null || after.isDir != was.isDir) {
        if (was.isDir) {
          try {
            await Directory(itemPath).delete(recursive: true);
          } on FileSystemException {
            // Open somewhere: it goes next time.
            now[name] = was;
          }
        } else {
          _bridge.remove(itemPath);
        }
      } else if (!after.isDir && await _differs(itemPath, after)) {
        final child = children.firstWhere((c) => c.name == name);
        _withEntries([child], (entries, _) {
          _bridge.update(itemPath, entries);
        });
      }
    }
  }

  /// Whether the placeholder at [itemPath] is not what the device has now.
  /// Asked of the file itself, not of what was last sent: an update that
  /// could not be made (the file was open) is made the next time.
  static Future<bool> _differs(
    String itemPath,
    ({bool isDir, int size, int modifiedMs}) now,
  ) async {
    final placed = await File(itemPath).stat();
    // Seconds only: that is all a stat on Windows gives (taken for a
    // change every time, it was emptied every few seconds).
    return placed.type == FileSystemEntityType.file &&
        (placed.size != now.size ||
            placed.modified.millisecondsSinceEpoch ~/ 1000 !=
                now.modifiedMs ~/ 1000);
  }

  /// Explorer asks for a folder only when it shows it: a file changed on
  /// the device while its folder stayed open, or opened by its path, kept
  /// what was read of it before. Folders in use are looked at again every
  /// few seconds, and what went or changed is put right; what is new comes
  /// with the folder's next listing.
  Future<void> _lookAgain() async {
    if (_lookingNow || _session == 0) {
      return;
    }
    _lookingNow = true;
    try {
      final now = DateTime.now();
      _inUse.removeWhere((_, at) => now.difference(at) > _inUseFor);
      final folders = _inUse.keys.toList()
        ..sort((a, b) => _inUse[b]!.compareTo(_inUse[a]!));
      for (final ino in folders.take(_mostLookedAt)) {
        final listed = _listed[ino];
        if (listed == null || _session == 0) {
          continue;
        }
        final List<MountNode> children;
        try {
          children = await tree.children(ino);
        } on MountException {
          continue;
        }
        final shown = {
          for (final MapEntry(:key, :value) in _snapshot(children).entries)
            if (listed.items.containsKey(key)) key: value,
        };
        await _tidy(listed.path, listed.items, shown, children);
        if (identical(_listed[ino], listed)) {
          _listed[ino] = _Listed(listed.path, shown, listed.at);
        }
      }
    } finally {
      _lookingNow = false;
    }
  }

  Future<void> _read(Pointer<_Request> request) async {
    final ino = request.ref.ino;
    final offset = request.ref.offset;
    final wanted = request.ref.length;
    final transfer = request.ref.transferKey;
    final node = tree.node(ino);
    if (node == null || node.gone || _session == 0) {
      _bridge.data(request, nullptr, offset, wanted, 1);
      return;
    }
    _inUse[node.parent] = DateTime.now();
    final size = request.ref.fileSize;
    final end = offset + wanted > size ? size : offset + wanted;
    // What may come along: the rest of the file, usually.
    final optionalStart = request.ref.optionalOffset;
    final optionalEnd = optionalStart + request.ref.optionalLength;
    final along = optionalStart == end && optionalEnd > end
        ? (optionalEnd > size ? size : optionalEnd)
        : end;
    // A whole-file ask (Defender scanning what was opened) gets a part and
    // is told the rest is not coming; the reader then asks for its part.
    // A read past all that was sent leads: it gets what it needs and as
    // much of what may come along as reading on has earned, doubling each
    // time it carries on from there. The system asks for several nearby
    // parts at once; those inside what is on its way get only what they
    // need, so nothing is sent twice.
    final run = _runs[ino];
    int until;
    if (wanted > _firstServing) {
      until = offset + _firstServing;
    } else if (run == null || offset >= run.frontier) {
      final window = run != null && offset == run.frontier
          ? (run.window * 2).clamp(_firstServing, _mostServing)
          : _firstServing;
      until = offset + window;
      if (until > along) {
        until = along;
      }
      if (until < end) {
        until = end;
      }
      _runs[ino] = (frontier: until, window: window);
    } else {
      until = end;
    }
    var at = offset;
    try {
      while (at < until) {
        if (_canceled.remove(transfer) || _session == 0) {
          return;
        }
        final length = until - at < _chunk ? until - at : _chunk;
        final data = await tree.read(ino, at, length);
        if (data.isEmpty) {
          break;
        }
        _withBytes(data, (pointer) {
          _bridge.data(request, pointer, at, data.length, 0);
        });
        at += data.length;
      }
    } on MountException {
      // Fails what is left, below.
    }
    if (at < end && _session != 0) {
      _bridge.data(request, nullptr, at, end - at, 1);
    }
  }

  static Map<String, ({bool isDir, int size, int modifiedMs})> _snapshot(
    List<MountNode> children,
  ) => {
    for (final child in children)
      child.name: (
        isDir: child.isDir,
        size: child.size,
        modifiedMs: child.modifiedMs,
      ),
  };

  static String _pathOf(Pointer<_Request> request) {
    final chars = <int>[];
    for (var i = 0; i < 1024; i++) {
      final c = request.ref.path[i];
      if (c == 0) {
        break;
      }
      chars.add(c);
    }
    return String.fromCharCodes(chars);
  }

  static void _withEntries(
    List<MountNode> nodes,
    void Function(Pointer<_Entry> entries, int count) use,
  ) {
    final entries = calloc<_Entry>(nodes.isEmpty ? 1 : nodes.length);
    final names = <Pointer<Utf16>>[];
    try {
      for (var i = 0; i < nodes.length; i++) {
        final node = nodes[i];
        final name = node.name.toNativeUtf16();
        names.add(name);
        entries[i]
          ..name = name
          ..ino = node.ino
          ..size = node.size
          ..modified = (node.modifiedMs + 11644473600000) * 10000
          ..isDir = node.isDir ? 1 : 0
          // Hidden over there: dot files from a Mac, Linux or Android
          // device too, which Explorer would otherwise show.
          ..hidden = node.hidden || node.name.startsWith('.') ? 1 : 0;
      }
      use(entries, nodes.length);
    } finally {
      for (final name in names) {
        calloc.free(name);
      }
      calloc.free(entries);
    }
  }

  static void _withBytes(Uint8List data, void Function(Pointer<Uint8>) use) {
    final pointer = malloc<Uint8>(data.length);
    try {
      pointer.asTypedList(data.length).setAll(0, data);
      use(pointer);
    } finally {
      malloc.free(pointer);
    }
  }
}

class _Listed {
  _Listed(this.path, this.items, [DateTime? at]) : at = at ?? DateTime.now();

  final String path;
  final Map<String, ({bool isDir, int size, int modifiedMs})> items;
  final DateTime at;
}

/// WcfRequest (cloud_files_bridge.cpp).
final class _Request extends Struct {
  @Int32()
  external int kind;
  @Int32()
  external int isDir;
  @Int64()
  external int ino;
  @Int64()
  external int offset;
  @Int64()
  external int length;
  @Int64()
  external int fileSize;
  @Int64()
  external int optionalOffset;
  @Int64()
  external int optionalLength;
  @Int64()
  external int connectionKey;
  @Int64()
  external int transferKey;
  @Int64()
  external int requestKey;
  @Array(1024)
  external Array<Uint16> path;
}

/// WcfEntry (cloud_files_bridge.cpp).
final class _Entry extends Struct {
  external Pointer<Utf16> name;
  @Int64()
  external int ino;
  @Int64()
  external int size;
  @Int64()
  external int modified;
  @Int32()
  external int isDir;
  @Int32()
  external int hidden;
}

class _Bridge {
  _Bridge(DynamicLibrary library)
    : start = library
          .lookupFunction<
            Int64 Function(
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<NativeFunction<Void Function(Pointer<_Request>)>>,
              Pointer<Int32>,
            ),
            int Function(
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<NativeFunction<Void Function(Pointer<_Request>)>>,
              Pointer<Int32>,
            )
          >('wcf_start'),
      stop = library.lookupFunction<Void Function(Int64), void Function(int)>(
        'wcf_stop',
      ),
      unregisterStale = library
          .lookupFunction<Int32 Function(), int Function()>(
            'wcf_unregister_stale',
          ),
      list = library
          .lookupFunction<
            Int32 Function(Pointer<_Request>, Pointer<_Entry>, Int32, Int32),
            int Function(Pointer<_Request>, Pointer<_Entry>, int, int)
          >('wcf_list'),
      data = library
          .lookupFunction<
            Int32 Function(
              Pointer<_Request>,
              Pointer<Uint8>,
              Int64,
              Int64,
              Int32,
            ),
            int Function(Pointer<_Request>, Pointer<Uint8>, int, int, int)
          >('wcf_data'),
      _remove = library
          .lookupFunction<
            Int32 Function(Pointer<Utf16>),
            int Function(Pointer<Utf16>)
          >('wcf_remove'),
      _update = library
          .lookupFunction<
            Int32 Function(Pointer<Utf16>, Pointer<_Entry>),
            int Function(Pointer<Utf16>, Pointer<_Entry>)
          >('wcf_update'),
      free = library
          .lookupFunction<
            Void Function(Pointer<_Request>),
            void Function(Pointer<_Request>)
          >('wcf_free');

  final int Function(
    Pointer<Utf16>,
    Pointer<Utf16>,
    Pointer<Utf16>,
    Pointer<Utf16>,
    Pointer<NativeFunction<Void Function(Pointer<_Request>)>>,
    Pointer<Int32>,
  )
  start;
  final void Function(int) stop;
  final int Function() unregisterStale;
  final int Function(Pointer<_Request>, Pointer<_Entry>, int, int) list;
  final int Function(Pointer<_Request>, Pointer<Uint8>, int, int, int) data;
  final int Function(Pointer<Utf16>, Pointer<_Entry>) _update;
  final int Function(Pointer<Utf16>) _remove;
  final void Function(Pointer<_Request>) free;

  int remove(String file) {
    final path = file.toNativeUtf16();
    try {
      return _remove(path);
    } finally {
      calloc.free(path);
    }
  }

  int update(String file, Pointer<_Entry> entry) {
    final path = file.toNativeUtf16();
    try {
      return _update(path, entry);
    } finally {
      calloc.free(path);
    }
  }
}
