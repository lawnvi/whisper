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
///
/// For a device that takes changes, the system asks before a placeholder is
/// deleted or renamed, and it happens here only once it happened there.
/// What is made or written in the folder it does not tell: the folder is
/// watched, and a file left alone (nobody has it open to write) is sent
/// whole, then marked in sync.
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

  /// Answers of [_state] and [_mark], which run off this isolate's thread.
  NativeCallable<Void Function(Int64, Int32)>? _answers;

  /// Shown in This PC.
  bool _inThisPc = false;
  final _asked = <int, Completer<int>>{};
  int _nextAsk = 1;
  final _listed = <int, _Listed>{};
  final _canceled = <int>{};
  final _runs = <int, ({int frontier, int window})>{};

  /// Folders lately shown or read from, and when.
  final _inUse = <int, DateTime>{};
  Timer? _looking;
  bool _lookingNow = false;

  StreamSubscription<FileSystemEvent>? _watching;

  /// Paths changed here, each looked at once it has been left alone.
  final _changed = <String, Timer>{};
  final _syncing = <String>{};
  int _sending = 0;
  final _sendTurns = <Completer<void>>[];

  /// Settled after this long without another change.
  static const _settle = Duration(milliseconds: 1500);

  /// Something still has it open to write: looked at again after this.
  static const _stillOpen = Duration(seconds: 5);
  static const _mostSending = 4;

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

  /// Takes away sync roots a run before this one left (it quit abruptly),
  /// and their items in This PC.
  static void unregisterStale() {
    try {
      _bridge.pcClear();
      _bridge.unregisterStale();
    } on ArgumentError {
      // No library next to the executable: nothing was ever mounted.
    }
  }

  /// Deletes [folder], left by a run before this one. Unprovided, Cloud
  /// Files will not let go of a folder that was never listed, so it is
  /// provided again (nothing reaches a device) just long enough to empty
  /// it. False when something stayed.
  static Future<bool> clearLeftover(String folder) async {
    final dir = Directory(folder);
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      return true;
    } on FileSystemException {
      // Placeholders that need a provider.
    }
    final _Bridge bridge;
    try {
      bridge = _bridge;
    } on ArgumentError {
      return false;
    }
    final stayed = Completer<int>();
    final done = NativeCallable<Void Function(Int64, Int32)>.listener((
      int token,
      int result,
    ) {
      stayed.complete(result);
    });
    final path = folder.toNativeUtf16();
    final icon = '${Platform.resolvedExecutable},0'.toNativeUtf16();
    try {
      bridge.clearStaleAsync(path, icon, done.nativeFunction, 0);
    } finally {
      calloc.free(path);
      calloc.free(icon);
    }
    final left = await stayed.future;
    done.close();
    if (left != 0) {
      mountLog('mount: $left item(s) stayed in $folder');
    }
    try {
      await dir.delete(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> start() async {
    await Directory(path).create(recursive: true);
    final listener = NativeCallable<Void Function(Pointer<_Request>)>.listener(
      _onRequest,
    );
    _listener = listener;
    _answers = NativeCallable<Void Function(Int64, Int32)>.listener((
      int token,
      int result,
    ) {
      _asked.remove(token)?.complete(result);
    });
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
        tree.writable ? 1 : 0,
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
      if (tree.writable) {
        _watch();
      }
      // In This PC beside the drives, like a partition: where people
      // look for it.
      final label = '$name (Whisper)'.toNativeUtf16();
      try {
        _inThisPc = _bridge.pcAdd(nativePath, label, icon) == 1;
      } finally {
        calloc.free(label);
      }
      if (!_inThisPc) {
        mountLog('mount: not put in This PC');
      }
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
    if (_inThisPc) {
      final folder = path.toNativeUtf16();
      try {
        _bridge.pcRemove(folder);
      } finally {
        calloc.free(folder);
      }
      _inThisPc = false;
    }
    _looking?.cancel();
    _looking = null;
    await _watching?.cancel();
    _watching = null;
    for (final timer in _changed.values) {
      timer.cancel();
    }
    _changed.clear();
    // Emptied while still connected: unprovided, a folder never listed
    // could not be deleted, and the sync root would stay in Explorer.
    // Nothing of it reaches the device.
    final answers = _answers;
    if (answers != null) {
      final token = _nextAsk++;
      final cleared = _asked[token] = Completer<int>();
      _bridge.clearAsync(session, answers.nativeFunction, token);
      final stayed = await cleared.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => -1,
      );
      if (stayed != 0) {
        mountLog('mount: $stayed item(s) stayed in the folder');
      }
    }
    final unregistered = _bridge.stop(session);
    if (unregistered != 0) {
      mountLog(
        'mount: still in Explorer '
        '(0x${(unregistered & 0xffffffff).toRadixString(16)})',
      );
    }
    _listener?.close();
    _listener = null;
    _answers?.close();
    _answers = null;
    for (final asked in _asked.values) {
      asked.complete(-1);
    }
    _asked.clear();
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
        case 4:
          await _delete(request);
        case 5:
          await _rename(request);
        case 6:
          _opened(request.ref.ino);
      }
    } catch (error) {
      mountLog('mount: request $kind failed: $error');
    } finally {
      _bridge.free(request);
    }
  }

  /// The system lists a folder once, the first time it is shown, and gets
  /// everything; it is then fully populated (a new name made in it needs
  /// nothing from the device), and kept up to date by [_refresh]: when
  /// Explorer opens it, and every few seconds while it is in use.
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
      if (await _changedHere(itemPath)) {
        // Changed here and not sent yet: it is sent, not undone.
        continue;
      }
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

  /// Folders in use are looked at again every few seconds: a file changed
  /// on the device while its folder stayed open, or opened by its path,
  /// would keep what was read of it before.
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
        if (_session == 0) {
          break;
        }
        await _refresh(ino);
      }
    } finally {
      _lookingNow = false;
    }
  }

  /// Explorer opened folder [ino]: what changed on the device shows now.
  void _opened(int ino) {
    _inUse[ino] = DateTime.now();
    final listed = _listed[ino];
    if (listed != null &&
        DateTime.now().difference(listed.at) > _refreshAfter) {
      unawaited(_refresh(ino));
    }
  }

  final _refreshing = <int>{};

  /// Puts folder [ino] (listed already) right with the device: what is new
  /// there gets a placeholder, what went or changed is put right.
  Future<void> _refresh(int ino) async {
    final listed = _listed[ino];
    if (listed == null || _session == 0 || !_refreshing.add(ino)) {
      return;
    }
    try {
      final List<MountNode> children;
      try {
        children = await tree.children(ino);
      } on MountException {
        return;
      }
      final now = _snapshot(children);
      final added = <MountNode>[];
      for (final child in children) {
        // Not over what was made here and is not sent yet.
        if (!listed.items.containsKey(child.name) &&
            await _state('${listed.path}\\${child.name}') < 0) {
          added.add(child);
        }
      }
      if (added.isNotEmpty) {
        _withEntries(added, (entries, count) {
          _bridge.create(listed.path, entries, count);
        });
      }
      await _tidy(listed.path, listed.items, now, children);
      if (identical(_listed[ino], listed)) {
        _listed[ino] = _Listed(listed.path, now);
      }
    } finally {
      _refreshing.remove(ino);
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

  // Changes made here.

  void _watch() {
    _watching = Directory(path)
        .watch(recursive: true)
        .listen(
          (event) {
            if (event is FileSystemDeleteEvent) {
              // A placeholder's delete was asked about; a new file that
              // went again has nothing to send.
              return;
            }
            _soon(
              event is FileSystemMoveEvent
                  ? event.destination ?? event.path
                  : event.path,
            );
          },
          onError: (Object error) {
            mountLog('mount: watching the folder failed: $error');
          },
          onDone: () {
            // Too much at once (the system's buffer ran over): again.
            if (_session != 0) {
              _watch();
            }
          },
        );
  }

  /// Looks at [itemPath] once it has been left alone for a moment.
  void _soon(String itemPath, [Duration after = _settle]) {
    if (_session == 0) {
      return;
    }
    final key = itemPath.toLowerCase();
    _changed.remove(key)?.cancel();
    _changed[key] = Timer(after, () {
      _changed.remove(key);
      unawaited(_sync(itemPath));
    });
  }

  /// wcf_state: -1 not there, else 1 folder, 2 placeholder, 4 in sync,
  /// 8 open for writing. Off this thread: looking at an item in the sync
  /// root can call back into this very isolate.
  Future<int> _state(String itemPath) {
    final answers = _answers;
    if (answers == null) {
      return Future.value(-1);
    }
    final token = _nextAsk++;
    final asked = _asked[token] = Completer<int>();
    _bridge.stateAsync(itemPath, answers.nativeFunction, token);
    return asked.future;
  }

  /// wcf_mark, off this thread like [_state]; 0 when done.
  Future<int> _mark(String itemPath, int ino, {required bool isDir}) {
    final answers = _answers;
    if (answers == null) {
      return Future.value(-1);
    }
    final token = _nextAsk++;
    final asked = _asked[token] = Completer<int>();
    _bridge.markAsync(
      itemPath,
      ino,
      isDir ? 1 : 0,
      answers.nativeFunction,
      token,
    );
    return asked.future;
  }

  /// Made or changed here and not yet sent: a placeholder out of sync, or
  /// not a placeholder at all.
  Future<bool> _changedHere(String itemPath) async {
    final state = await _state(itemPath);
    return state >= 0 && (state & 2 == 0 || state & 4 == 0);
  }

  /// Sends what is at [itemPath], made or written here, unless it is
  /// already what the device has.
  Future<void> _sync(String itemPath) async {
    final key = itemPath.toLowerCase();
    if (_session == 0) {
      return;
    }
    if (!_syncing.add(key)) {
      _soon(itemPath);
      return;
    }
    try {
      final state = await _state(itemPath);
      if (state < 0) {
        return; // gone again
      }
      final isDir = state & 1 != 0;
      if (state & 2 != 0 && state & 4 != 0) {
        return; // a placeholder in sync
      }
      if (state & 8 != 0) {
        _soon(itemPath, _stillOpen);
        return;
      }
      final place = await _place(itemPath);
      if (place == null) {
        // Not in a folder that is on the device yet: that folder, once
        // sent, sends what is in it.
        return;
      }
      final (folder, name) = place;
      if (isDir) {
        final existing = await tree.lookup(folder.ino, name);
        final node = existing != null && existing.isDir
            ? existing
            : await tree.mkdir(folder.ino, name);
        final marked = await _mark(itemPath, node.ino, isDir: true);
        if (marked != 0) {
          mountLog('mount: a new folder was not marked in sync ($marked)');
        }
        _remember(folder, node);
        // What was put in it before it was sent.
        await for (final entry in Directory(itemPath).list()) {
          _soon(entry.path);
        }
      } else {
        await _send(itemPath, folder, name);
      }
    } on MountException catch (error) {
      mountLog('mount: a change was not sent: ${error.error.name}');
    } on FileSystemException catch (error) {
      mountLog('mount: a change could not be read: ${error.osError}');
    } catch (error) {
      mountLog('mount: a change failed: ${error.runtimeType}');
    } finally {
      _syncing.remove(key);
    }
  }

  /// Sends file [itemPath] whole as [name] in [folder], then marks it in
  /// sync; changed again meanwhile, it is sent again.
  Future<void> _send(String itemPath, MountNode folder, String name) async {
    if (_sending >= _mostSending) {
      final turn = Completer<void>();
      _sendTurns.add(turn);
      await turn.future;
    }
    _sending++;
    try {
      final existing = await tree.lookup(folder.ino, name);
      final node = existing != null && !existing.isDir
          ? existing
          : await tree.create(folder.ino, name);
      final local = File(itemPath);
      final before = await local.stat();
      final reader = await local.open();
      try {
        await tree.resize(node.ino, 0);
        var at = 0;
        while (true) {
          final chunk = await reader.read(_chunk);
          if (chunk.isEmpty) {
            break;
          }
          await tree.write(node.ino, at, chunk);
          at += chunk.length;
        }
        await tree.setModified(
          node.ino,
          before.modified.millisecondsSinceEpoch,
        );
        await tree.commit(node.ino);
      } finally {
        await reader.close();
      }
      final after = await local.stat();
      if (after.size != before.size || after.modified != before.modified) {
        _soon(itemPath);
        return;
      }
      final marked = await _mark(itemPath, node.ino, isDir: false);
      if (marked != 0) {
        mountLog('mount: a sent file was not marked in sync ($marked)');
      }
      _remember(folder, node);
    } finally {
      _sending--;
      if (_sendTurns.isNotEmpty) {
        _sendTurns.removeAt(0).complete();
      }
    }
  }

  /// The system asks before deleting a placeholder: it goes there first
  /// (to the device's trash, unless made from here), a folder with all in
  /// it.
  Future<void> _delete(Pointer<_Request> request) async {
    final node = tree.node(request.ref.ino);
    var done = false;
    try {
      if (node == null || node.gone) {
        done = true; // not there either
      } else if (node.isDir) {
        // A folder goes with all in it (the Recycle Bin asks this way,
        // before anything in it went): to the device's trash.
        await tree.remove(node.parent, node.name);
        done = true;
      } else {
        await tree.unlink(node.parent, node.name);
        done = true;
      }
    } on MountException catch (error) {
      // Gone there already (what went there is taken away here too).
      done = error.error == MountError.notFound;
      if (!done) {
        mountLog('mount: a delete was refused: ${error.error.name}');
      }
    }
    _bridge.ack(request, done ? 1 : 0);
    if (done && node != null) {
      _listed[node.parent]?.items.remove(node.name);
    }
  }

  /// The system asks before renaming or moving a placeholder; moved out of
  /// the folder (the Recycle Bin, another disk), it goes from the device.
  Future<void> _rename(Pointer<_Request> request) async {
    final node = tree.node(request.ref.ino);
    final target = _text(request.ref.target);
    var done = false;
    MountNode? into;
    try {
      if (node == null || node.gone) {
        done = true;
      } else if (target.isEmpty) {
        await tree.remove(node.parent, node.name);
        done = true;
      } else {
        // Into a folder made here a moment ago: it goes there first.
        final place = await _place(target, make: true);
        if (place == null) {
          throw const MountException(MountError.denied);
        }
        into = place.$1;
        await tree.rename(node.parent, node.name, into.ino, place.$2);
        done = true;
      }
    } on MountException catch (error) {
      mountLog('mount: a rename was refused: ${error.error.name}');
    }
    final from = node?.parent;
    final oldName = node?.name;
    _bridge.ack(request, done ? 1 : 0);
    if (done && node != null) {
      if (from != null && oldName != null && from != node.parent) {
        _listed[from]?.items.remove(oldName);
      }
      if (into != null) {
        _remember(into, node);
      }
    }
  }

  /// [node] is in [folder] here as on the device: its next listing does
  /// not make a placeholder of it again.
  void _remember(MountNode folder, MountNode node) {
    _listed[folder.ino]?.items[node.name] = (
      isDir: node.isDir,
      size: node.size,
      modifiedMs: node.modifiedMs,
    );
  }

  /// The folder [itemPath] is in on the device, and its name there; null
  /// when that folder is not there (yet), or is the top of several roots.
  /// With [make], folders made here and not sent yet are made there.
  Future<(MountNode, String)?> _place(
    String itemPath, {
    bool make = false,
  }) async {
    final base = '${path.toLowerCase()}\\';
    if (!itemPath.toLowerCase().startsWith(base)) {
      return null;
    }
    final parts = itemPath.substring(base.length).split('\\');
    var folder = tree.top;
    var here = path;
    for (final part in parts.sublist(0, parts.length - 1)) {
      here = '$here\\$part';
      var next = await tree.lookup(folder.ino, part);
      if (next == null && make && !folder.isTop && await _state(here) == 1) {
        next = await tree.mkdir(folder.ino, part);
        await _mark(here, next.ino, isDir: true);
        _remember(folder, next);
      }
      if (next == null || !next.isDir) {
        return null;
      }
      folder = next;
    }
    if (folder.isTop || parts.last.isEmpty) {
      return null;
    }
    return (folder, parts.last);
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

  static String _pathOf(Pointer<_Request> request) => _text(request.ref.path);

  static String _text(Array<Uint16> chars) {
    final out = <int>[];
    for (var i = 0; i < 1024; i++) {
      final c = chars[i];
      if (c == 0) {
        break;
      }
      out.add(c);
    }
    return String.fromCharCodes(out);
  }

  void _withEntries(
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
          ..hidden = node.hidden || node.name.startsWith('.') ? 1 : 0
          ..readOnly = tree.writable ? 0 : 1;
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
  @Array(1024)
  external Array<Uint16> target;
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
  @Int32()
  external int readOnly;
}

/// WcfDone (cloud_files_bridge.cpp).
typedef _Done = Void Function(Int64 token, Int32 result);

class _Bridge {
  _Bridge(DynamicLibrary library)
    : start = library
          .lookupFunction<
            Int64 Function(
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Int32,
              Pointer<NativeFunction<Void Function(Pointer<_Request>)>>,
              Pointer<Int32>,
            ),
            int Function(
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              int,
              Pointer<NativeFunction<Void Function(Pointer<_Request>)>>,
              Pointer<Int32>,
            )
          >('wcf_start'),
      stop = library.lookupFunction<Int32 Function(Int64), int Function(int)>(
        'wcf_stop',
      ),
      clearAsync = library
          .lookupFunction<
            Void Function(Int64, Pointer<NativeFunction<_Done>>, Int64),
            void Function(int, Pointer<NativeFunction<_Done>>, int)
          >('wcf_clear_async'),
      clearStaleAsync = library
          .lookupFunction<
            Void Function(
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<NativeFunction<_Done>>,
              Int64,
            ),
            void Function(
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<NativeFunction<_Done>>,
              int,
            )
          >('wcf_clear_stale_async'),
      unregisterStale = library
          .lookupFunction<Int32 Function(), int Function()>(
            'wcf_unregister_stale',
          ),
      pcAdd = library
          .lookupFunction<
            Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>),
            int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>)
          >('wcf_pc_add'),
      pcRemove = library
          .lookupFunction<
            Int32 Function(Pointer<Utf16>),
            int Function(Pointer<Utf16>)
          >('wcf_pc_remove'),
      pcClear = library.lookupFunction<Int32 Function(), int Function()>(
        'wcf_pc_clear',
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
      _create = library
          .lookupFunction<
            Int32 Function(Pointer<Utf16>, Pointer<_Entry>, Int32),
            int Function(Pointer<Utf16>, Pointer<_Entry>, int)
          >('wcf_create'),
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
      ack = library
          .lookupFunction<
            Int32 Function(Pointer<_Request>, Int32),
            int Function(Pointer<_Request>, int)
          >('wcf_ack'),
      _stateAsync = library
          .lookupFunction<
            Void Function(
              Pointer<Utf16>,
              Pointer<NativeFunction<_Done>>,
              Int64,
            ),
            void Function(Pointer<Utf16>, Pointer<NativeFunction<_Done>>, int)
          >('wcf_state_async'),
      _markAsync = library
          .lookupFunction<
            Void Function(
              Pointer<Utf16>,
              Int64,
              Int32,
              Pointer<NativeFunction<_Done>>,
              Int64,
            ),
            void Function(
              Pointer<Utf16>,
              int,
              int,
              Pointer<NativeFunction<_Done>>,
              int,
            )
          >('wcf_mark_async'),
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
    int,
    Pointer<NativeFunction<Void Function(Pointer<_Request>)>>,
    Pointer<Int32>,
  )
  start;
  final int Function(int) stop;
  final void Function(int, Pointer<NativeFunction<_Done>>, int) clearAsync;
  final void Function(
    Pointer<Utf16>,
    Pointer<Utf16>,
    Pointer<NativeFunction<_Done>>,
    int,
  )
  clearStaleAsync;
  final int Function() unregisterStale;
  final int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>) pcAdd;
  final int Function(Pointer<Utf16>) pcRemove;
  final int Function() pcClear;
  final int Function(Pointer<_Request>, Pointer<_Entry>, int, int) list;
  final int Function(Pointer<_Request>, Pointer<Uint8>, int, int, int) data;
  final int Function(Pointer<Utf16>, Pointer<_Entry>) _update;
  final int Function(Pointer<Utf16>) _remove;
  final int Function(Pointer<Utf16>, Pointer<_Entry>, int) _create;
  final int Function(Pointer<_Request>, int) ack;
  final void Function(Pointer<Utf16>, Pointer<NativeFunction<_Done>>, int)
  _stateAsync;
  final void Function(
    Pointer<Utf16>,
    int,
    int,
    Pointer<NativeFunction<_Done>>,
    int,
  )
  _markAsync;
  final void Function(Pointer<_Request>) free;

  /// The path is copied before the call returns.
  void stateAsync(String item, Pointer<NativeFunction<_Done>> done, int token) {
    final native = item.toNativeUtf16();
    try {
      _stateAsync(native, done, token);
    } finally {
      calloc.free(native);
    }
  }

  void markAsync(
    String item,
    int ino,
    int isDir,
    Pointer<NativeFunction<_Done>> done,
    int token,
  ) {
    final native = item.toNativeUtf16();
    try {
      _markAsync(native, ino, isDir, done, token);
    } finally {
      calloc.free(native);
    }
  }

  int create(String folder, Pointer<_Entry> entries, int count) {
    final native = folder.toNativeUtf16();
    try {
      return _create(native, entries, count);
    } finally {
      calloc.free(native);
    }
  }

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
