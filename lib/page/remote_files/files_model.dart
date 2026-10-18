import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../helper/desktop_clipboard_image.dart';
import '../../helper/helper.dart';

import '../../model/file_transfer.dart';
import '../../remote_files/files_log.dart';
import '../../remote_files/fs_browser.dart';
import '../../remote_files/fs_client.dart';
import '../../remote_files/fs_copies.dart';
import '../../remote_files/fs_host_files.dart';
import '../../remote_files/fs_paths.dart';
import '../../remote_files/fs_placement.dart';
import '../../remote_files/fs_protocol.dart';
import '../../socket/svrmanager.dart';

/// A device in the sidebar ("位置"): this one, or a trusted peer.
enum FilesDeviceState {
  ready,
  idle,
  waiting,
  denied,

  /// Asked, but nobody answered on that device in time.
  noAnswer,
  offline,
  unsupported,
}

class FilesDevice {
  FilesDevice.local(this.platform, LocalFsBrowser this.browser)
    : id = localId,
      name = '',
      client = null,
      state = FilesDeviceState.ready;

  FilesDevice.remote(this.id, this.name, this.platform)
    : browser = null,
      client = RemoteFilesClient(id),
      state = FilesDeviceState.idle;

  static const localId = 'local';

  final String id;
  String name;
  final String platform;
  FsBrowser? browser;
  RemoteFilesClient? client;
  FilesDeviceState state;

  bool get isLocal => id == localId;
  bool get isPhone => platform == 'android' || platform == 'ios';
}

/// Where a folder is: device, root, path inside the root.
@immutable
class FilesLocation {
  const FilesLocation(this.deviceId, this.root, this.path);

  final String deviceId;
  final String root;
  final String path;

  String child(String name) => path.isEmpty ? name : '$path/$name';

  List<String> get crumbs => path.isEmpty ? const [] : path.split('/');

  FilesLocation get parent {
    final parts = crumbs;
    return FilesLocation(
      deviceId,
      root,
      parts.isEmpty ? '' : parts.sublist(0, parts.length - 1).join('/'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FilesLocation &&
      other.deviceId == deviceId &&
      other.root == root &&
      other.path == path;

  @override
  int get hashCode => Object.hash(deviceId, root, path);
}

/// Something copied with ⌘C (or picked to copy on a phone).
class FilesItem {
  const FilesItem(this.location, this.name, {required this.isDir});

  /// The folder it is in.
  final FilesLocation location;
  final String name;
  final bool isDir;

  String get path => location.child(name);
}

enum FilesSort { name, modified, size, kind }

enum FilesView { list, icons }

/// Why a copy could not even start.
enum FilesCopyProblem { sameDevice, betweenOthers, notConnected }

/// What the file manager needs to know about the other devices.
class FilesPeers {
  const FilesPeers({
    required this.connected,
    required this.canBrowse,
    required this.describe,
  });

  factory FilesPeers.live() {
    final sockets = WsSvrManager();
    return FilesPeers(
      connected: () => sockets.connectedPeerIds,
      canBrowse: sockets.canBrowseFilesOf,
      describe: (peerId) {
        final device = sockets.remoteProfileFor(peerId)?.device;
        return device == null
            ? null
            : (name: device.name, platform: device.platform);
      },
    );
  }

  final Set<String> Function() connected;
  final bool Function(String peerId) canBrowse;
  final ({String name, String platform})? Function(String peerId) describe;
}

/// The system clipboard's list of files, which Finder, Explorer and Linux
/// file managers paste from.
class FilesSystemClipboard {
  const FilesSystemClipboard();

  static const _channel = MethodChannel(
    DesktopClipboardImageReader.channelName,
  );

  Future<bool> write(List<String> paths) {
    // Clipboard sync must not send these to another device.
    markOwnClipboardFiles(paths);
    return const DesktopClipboardFileWriter().writeFilePaths(paths);
  }

  Future<List<String>> read() async {
    try {
      return await _channel.invokeListMethod<String>('readFilePaths') ??
          const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Empties the clipboard; only done while it holds this app's own files.
  Future<bool> clear() async {
    try {
      return await _channel.invokeMethod<bool>('clearFilePaths') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

/// The file browser's whole state: devices, where it is, history, what is
/// listed and selected, the copy clipboard and copies in flight.
class FilesController extends ChangeNotifier {
  FilesController({
    String? focusPeerId,
    FilesPeers? peers,
    LocalFsBrowser? local,
    FilesSystemClipboard? systemClipboard,
    FileCopies? copyList,
  }) : _peers = peers ?? FilesPeers.live(),
       copyList = copyList ?? FileCopies.shared,
       _system =
           systemClipboard ??
           (isDesktop() ? const FilesSystemClipboard() : null),
       _focusPeerId = focusPeerId {
    devices.add(
      FilesDevice.local(Platform.operatingSystem, local ?? LocalFsBrowser()),
    );
    _refreshDevices();
    _devicesTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshDevices(),
    );
    _updates = TransferPlacements.shared.updates.listen(_onTransfer);
    _placed = TransferPlacements.shared.placed.listen((placed) {
      if (_stagedArrived(placed.transferId, placed.path)) {
        return;
      }
      if (copies.containsKey(placed.transferId)) {
        if (location?.deviceId == FilesDevice.localId) {
          unawaited(reload());
        }
        return;
      }
      _remember(_earlyPlaced, placed.transferId, placed.path);
    });
    _unplaced = TransferPlacements.shared.unplaced.listen((transferId) {
      if (!_stagedGone(transferId)) {
        _remember(_earlyPlaced, transferId, null);
      }
    });
    unawaited(_cleanStaging());
    unawaited(_loadView());
    final focus = _focusPeerId == null ? null : deviceById(_focusPeerId);
    unawaited(open(focus ?? devices.first));
  }

  final FilesPeers _peers;
  final String? _focusPeerId;

  /// Every copy made in the file manager, for the island and the list.
  final FileCopies copyList;
  final devices = <FilesDevice>[];
  Timer? _devicesTimer;
  StreamSubscription<TransferSnapshot>? _updates;
  StreamSubscription<PlacedTransfer>? _placed;
  StreamSubscription<String>? _unplaced;

  FilesLocation? location;

  /// The folder [entries] are from: the last one loaded, which stays on
  /// screen while the next loads (no blank or stale in-between).
  FilesLocation? shownLocation;

  /// [entries] are still the previous folder's.
  bool get showingPrevious => shownLocation != location;

  /// The list of copies is shown instead of a folder (desktop).
  bool transfersOpen = false;

  void openTransfers() {
    transfersOpen = true;
    sharesOpen = false;
    selection.clear();
    _notify();
  }

  /// This device's share links are shown instead of a folder (desktop).
  bool sharesOpen = false;

  void openShares() {
    sharesOpen = true;
    transfersOpen = false;
    selection.clear();
    _notify();
  }

  /// Copies or share links are shown instead of a folder.
  bool get panelOpen => transfersOpen || sharesOpen;

  /// Devices whose own places are listed under them in the sidebar. None
  /// at first: going to a device does not unfold it.
  final sidebarExpanded = <String>{};

  void toggleSidebarDevice(String deviceId) {
    if (!sidebarExpanded.remove(deviceId)) {
      sidebarExpanded.add(deviceId);
    }
    _notify();
  }

  /// Bumped when [selection] was set to items to bring into view.
  final revealed = ValueNotifier<int>(0);

  /// Shows where a copy went, its items selected: opens its device first
  /// if need be.
  Future<void> reveal(FileCopyBatch batch) async {
    final where = batch.target;
    if (where is! FilesLocation) {
      return;
    }
    final device = deviceById(where.deviceId);
    if (device == null) {
      return;
    }
    if (device.browser == null) {
      await open(device, root: where.root, path: where.path);
    } else {
      await go(where);
    }
    // Gone somewhere else meanwhile, or the folder could not be listed.
    if (_disposed || shownLocation != where || error != null) {
      return;
    }
    final present = {for (final entry in _entries) entry.name};
    final names = batch.landedNames.where(present.contains).toList();
    if (names.isEmpty) {
      return;
    }
    if (query.isNotEmpty &&
        !entries.any((entry) => entry.name == names.first)) {
      query = '';
    }
    selection
      ..clear()
      ..addAll(names);
    _anchor = names.first;
    _notify();
    revealed.value++;
  }

  final _back = <FilesLocation>[];
  final _forward = <FilesLocation>[];
  List<FsEntry> _entries = const [];
  int total = 0;
  bool loading = false;
  Object? error;
  final selection = <String>{};
  String query = '';
  FilesSort sort = FilesSort.name;
  bool ascending = true;
  FilesView view = FilesView.list;
  bool showHidden = false;
  final thumbnails = <String, Uint8List?>{};
  List<FilesItem> clipboard = const [];
  final copies = <String, TransferSnapshot?>{};
  int _generation = 0;
  bool _disposed = false;

  FilesDevice? deviceById(String id) {
    for (final device in devices) {
      if (device.id == id) {
        return device;
      }
    }
    return null;
  }

  FilesDevice? get device =>
      location == null ? null : deviceById(location!.deviceId);

  bool get canGoBack => _back.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;

  /// Entries after search and sort.
  List<FsEntry> get entries {
    final needle = query.trim().toLowerCase();
    final shown = needle.isEmpty
        ? List.of(_entries)
        : _entries.where((e) => e.name.toLowerCase().contains(needle)).toList();
    int compare(FsEntry a, FsEntry b) {
      if (a.isDir != b.isDir && sort == FilesSort.name) {
        return a.isDir ? -1 : 1;
      }
      final c = switch (sort) {
        FilesSort.name => FsHostFiles.naturalCompare(a.name, b.name),
        FilesSort.modified => a.modifiedMs.compareTo(b.modifiedMs),
        FilesSort.size => a.size.compareTo(b.size),
        FilesSort.kind => a.kind.index.compareTo(b.kind.index),
      };
      final ordered = ascending ? c : -c;
      return ordered != 0
          ? ordered
          : FsHostFiles.naturalCompare(a.name, b.name);
    }

    return shown..sort(compare);
  }

  List<FilesItem> get selectedItems {
    final here = shownLocation ?? location;
    if (here == null) {
      return const [];
    }
    return [
      for (final entry in _entries)
        if (selection.contains(entry.name))
          FilesItem(here, entry.name, isDir: entry.isDir),
    ];
  }

  void _refreshDevices() {
    final connected = _peers.connected();
    var changed = false;
    for (final peerId in connected) {
      final known = deviceById(peerId);
      final capable = _peers.canBrowse(peerId);
      if (known != null) {
        if (capable && known.state == FilesDeviceState.unsupported) {
          known.state = FilesDeviceState.idle;
          changed = true;
        }
        continue;
      }
      // A peer on an older Whisper only shows when it was asked for, to
      // say why it cannot be browsed.
      if (!capable && peerId != _focusPeerId) {
        continue;
      }
      final about = _peers.describe(peerId);
      devices.add(
        FilesDevice.remote(peerId, about?.name ?? peerId, about?.platform ?? '')
          ..state = capable
              ? FilesDeviceState.idle
              : FilesDeviceState.unsupported,
      );
      changed = true;
    }
    for (final device in devices) {
      if (device.isLocal || device.state == FilesDeviceState.unsupported) {
        continue;
      }
      final online = connected.contains(device.id);
      if (!online && device.state != FilesDeviceState.offline) {
        device
          ..state = FilesDeviceState.offline
          ..browser = null;
        changed = true;
      } else if (online && device.state == FilesDeviceState.offline) {
        device
          ..state = FilesDeviceState.idle
          ..client = RemoteFilesClient(device.id);
        changed = true;
      }
    }
    if (changed) {
      _notify();
    }
  }

  /// Shows [device]'s first place, asking it for access first if needed.
  Future<void> open(
    FilesDevice device, {
    String? root,
    String path = '',
  }) async {
    if (device.browser == null) {
      final client = device.client;
      if (client == null ||
          device.state == FilesDeviceState.offline ||
          device.state == FilesDeviceState.unsupported) {
        _show(FilesLocation(device.id, '', ''));
        return;
      }
      device.state = FilesDeviceState.waiting;
      _show(FilesLocation(device.id, '', ''));
      try {
        final info = await client.open();
        device
          ..browser = RemoteFsBrowser(client, info)
          ..state = FilesDeviceState.ready;
      } on RemoteFsException catch (e) {
        device.state = switch (e.reason) {
          'denied' => FilesDeviceState.denied,
          'noAnswer' || 'timeout' => FilesDeviceState.noAnswer,
          // Stopped waiting here: back to asking when wanted.
          'canceled' => FilesDeviceState.idle,
          _ => FilesDeviceState.offline,
        };
        if (device.state != FilesDeviceState.denied) {
          device.client = RemoteFilesClient(device.id);
        }
        _notify();
        return;
      }
    }
    final browser = device.browser!;
    if (browser is LocalFsBrowser && !_localRootsRead) {
      // This device's drives and volumes, before its first place is picked
      // (they are found in the background otherwise).
      _localRootsRead = true;
      try {
        await browser.files.refreshRoots();
      } catch (_) {
        // The home folder alone, as before.
      }
    }
    final places = browser.places;
    final start = root ?? (places.isEmpty ? '' : places.first.root);
    await go(FilesLocation(device.id, start, path));
  }

  bool _localRootsRead = false;

  /// Asks again after a refusal or a lost connection.
  Future<void> retry() async {
    final current = device;
    if (current != null) {
      current.client = RemoteFilesClient(current.id);
      current.state = FilesDeviceState.idle;
      await open(current);
    }
  }

  /// Stops waiting for [target] (or the device shown) to allow browsing;
  /// the question on it goes away.
  Future<void> cancelOpen([FilesDevice? target]) async {
    final waiting = target ?? device;
    if (waiting == null || waiting.state != FilesDeviceState.waiting) {
      return;
    }
    await waiting.client?.cancelOpen();
  }

  /// A device's spot while it is still being asked (or refused): not a
  /// folder, so history skips it.
  static bool _isPlaceholder(FilesLocation? where) =>
      where == null || where.root.isEmpty;

  void _record(FilesLocation where) {
    final here = location;
    if (_isPlaceholder(here) || here == where) {
      return;
    }
    _back.add(here!);
    if (_back.length > 50) {
      _back.removeAt(0);
    }
    _forward.clear();
  }

  void _show(FilesLocation where) {
    _record(where);
    transfersOpen = false;
    sharesOpen = false;
    location = where;
    shownLocation = where;
    _entries = const [];
    selection.clear();
    query = '';
    _notify();
  }

  Future<void> go(FilesLocation where, {bool record = true}) async {
    if (record) {
      _record(where);
    }
    // What is on screen (the folder before, or the list of copies) stays,
    // selection and search included, until the new folder is ready.
    final leavingPanel = panelOpen;
    location = where;
    await reload();
    if (leavingPanel && location == where && panelOpen) {
      transfersOpen = false;
      sharesOpen = false;
      _notify();
    }
  }

  Future<void> back() async {
    if (_back.isEmpty) {
      return;
    }
    final target = _back.removeLast();
    if (!_isPlaceholder(location)) {
      _forward.add(location!);
    }
    await _visit(target);
  }

  Future<void> forward() async {
    if (_forward.isEmpty) {
      return;
    }
    final target = _forward.removeLast();
    if (!_isPlaceholder(location)) {
      _back.add(location!);
    }
    await _visit(target);
  }

  Future<void> _visit(FilesLocation target) async {
    final device = deviceById(target.deviceId);
    if (device != null && device.browser == null) {
      await open(device, root: target.root, path: target.path);
      return;
    }
    await go(target, record: false);
  }

  Future<void> up() async {
    final here = location;
    if (here == null || here.path.isEmpty) {
      return;
    }
    await go(here.parent);
  }

  Future<void> openEntry(FsEntry entry) async {
    final here = location;
    if (here == null || !entry.isDir) {
      return;
    }
    await go(FilesLocation(here.deviceId, here.root, here.child(entry.name)));
  }

  Future<void> reload() async {
    final here = location;
    final browser = device?.browser;
    if (here == null || browser == null) {
      _notify();
      return;
    }
    final generation = ++_generation;
    loading = true;
    error = null;
    _notify();
    try {
      var page = await browser.list(
        here.root,
        here.path,
        showHidden: showHidden,
      );
      var all = page.entries;
      while (all.length < page.total && generation == _generation) {
        page = await browser.list(
          here.root,
          here.path,
          offset: all.length,
          showHidden: showHidden,
        );
        if (page.entries.isEmpty) {
          break;
        }
        all = [...all, ...page.entries];
      }
      if (generation != _generation) {
        return;
      }
      final moved = shownLocation != here;
      _entries = all;
      shownLocation = here;
      total = all.length;
      if (moved) {
        _arrived();
      } else {
        selection.removeWhere((name) => !all.any((e) => e.name == name));
      }
    } catch (failure) {
      if (generation == _generation) {
        if (shownLocation != here) {
          _arrived();
        }
        _entries = const [];
        shownLocation = here;
        total = 0;
        error = failure;
      }
    } finally {
      if (generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  /// A new folder is on screen: nothing in it is selected or searched yet.
  void _arrived() {
    selection.clear();
    _anchor = null;
    query = '';
  }

  void setQuery(String value) {
    query = value;
    _notify();
  }

  void setSort(FilesSort value) {
    if (sort == value) {
      ascending = !ascending;
    } else {
      sort = value;
      ascending = value == FilesSort.name || value == FilesSort.kind;
    }
    _notify();
  }

  void setView(FilesView value) {
    if (view == value) {
      return;
    }
    view = value;
    _notify();
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setString(_viewKey, value.name),
      ),
    );
  }

  static const _viewKey = 'remote_files.view';

  /// The way the listing was last shown, list or icons.
  Future<void> _loadView() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = FilesView.values.asNameMap()[prefs.getString(_viewKey)];
      if (saved != null && saved != view && !_disposed) {
        view = saved;
        _notify();
      }
    } catch (_) {
      // No preferences (tests): the default stays.
    }
  }

  void toggleHidden() {
    showHidden = !showHidden;
    unawaited(reload());
  }

  String? _anchor;

  void select(String name, {bool toggle = false, bool extend = false}) {
    final names = entries.map((e) => e.name).toList();
    if (extend && _anchor != null && names.contains(_anchor)) {
      final a = names.indexOf(_anchor!);
      final b = names.indexOf(name);
      selection
        ..clear()
        ..addAll(names.sublist(a < b ? a : b, (a < b ? b : a) + 1));
    } else if (toggle) {
      selection.contains(name) ? selection.remove(name) : selection.add(name);
      _anchor = name;
    } else {
      selection
        ..clear()
        ..add(name);
      _anchor = name;
    }
    _notify();
  }

  void selectAll() {
    selection
      ..clear()
      ..addAll(entries.map((e) => e.name));
    _notify();
  }

  void clearSelection() {
    if (selection.isNotEmpty) {
      selection.clear();
      _notify();
    }
  }

  /// The folder the entries on screen are in (while the next one loads,
  /// still the one before).
  FilesLocation? get _entriesAt => shownLocation ?? location;

  Future<Uint8List?> thumbnail(FsEntry entry) async {
    final here = _entriesAt;
    final browser = here == null ? null : deviceById(here.deviceId)?.browser;
    if (here == null || browser == null) {
      return null;
    }
    final key = '${here.deviceId}/${here.root}/${here.child(entry.name)}';
    if (thumbnails.containsKey(key)) {
      return thumbnails[key];
    }
    if (thumbnails.length > 600) {
      thumbnails.removeWhere(
        (k, _) => !k.startsWith('${here.deviceId}/${here.root}/${here.path}'),
      );
    }
    thumbnails[key] = null;
    final bytes = await browser.thumbnail(here.root, here.child(entry.name));
    thumbnails[key] = bytes;
    if (bytes != null) {
      _notify();
    }
    return bytes;
  }

  Uint8List? cachedThumbnail(FsEntry entry) {
    final here = _entriesAt;
    if (here == null) {
      return null;
    }
    return thumbnails['${here.deviceId}/${here.root}/${here.child(entry.name)}'];
  }

  // ------------------------------------------------------------- editing

  Future<void> newFolder(String name) async {
    final here = location;
    final browser = device?.browser;
    if (here == null || browser == null) {
      return;
    }
    await browser.mkdir(here.root, here.path, name);
    await reload();
    select(name);
  }

  Future<void> rename(FsEntry entry, String name) async {
    final here = location;
    final browser = device?.browser;
    if (here == null || browser == null) {
      return;
    }
    await browser.rename(here.root, here.child(entry.name), name);
    await reload();
    select(name);
  }

  bool get hasTrash => device?.browser?.hasTrash ?? false;

  Future<void> remove(List<FilesItem> items, {bool permanent = false}) async {
    final browser = device?.browser;
    if (browser == null) {
      return;
    }
    for (final item in items) {
      await browser.remove(item.location.root, item.path, permanent: permanent);
    }
    selection.clear();
    await reload();
  }

  // ------------------------------------------------------------- copying

  void copySelection() {
    clipboard = selectedItems;
    _notify();
    unawaited(_publish(clipboard));
  }

  // The system clipboard gets real files too, so Finder and other apps can
  // paste what was copied here: this device's files at once, another
  // device's once they have been fetched into a staging folder.
  final FilesSystemClipboard? _system;

  /// The system clipboard's files as it reads back what was written here
  /// last (a platform may spell a path differently from how it was given).
  List<String> _systemPaths = const [];

  /// What is being staged for the latest copy of another device's items.
  _Staging? _staging;

  /// Every staging still waited for, by transfer: the latest and earlier
  /// ones a paste here still takes its files from.
  final _stagings = <String, _Staging>{};

  /// Where copies landed (null: they could not be moved there) before it
  /// was known which staging they belong to.
  final _earlyPlaced = <String, String?>{};

  /// Transfer updates from before their copy was being followed here.
  final _earlySnapshots = <String, TransferSnapshot?>{};

  int _clipboardGeneration = 0;

  /// Another device's items are on their way to the system clipboard.
  bool get clipboardPreparing => _staging?.settled == false;

  /// Another device's items can now be pasted in other apps.
  bool clipboardReady = false;

  int get stagedCount => _staging?.sources.length ?? 0;

  static Future<Directory> _stagingRoot() async =>
      Directory(p.join(Directory.systemTemp.path, 'whisper_files_clipboard'));

  /// Staging folders from earlier copies; a day is plenty to paste them.
  static Future<void> _cleanStaging() async {
    try {
      final root = await _stagingRoot();
      if (!await root.exists()) {
        return;
      }
      final cutoff = DateTime.now().subtract(const Duration(days: 1));
      await for (final entry in root.list()) {
        final stat = await entry.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entry.delete(recursive: true);
        }
      }
    } on FileSystemException {
      // Left for the next time.
    }
  }

  static void _remember<T>(Map<String, T> early, String transferId, T value) {
    early
      ..remove(transferId)
      ..[transferId] = value;
    if (early.length > 128) {
      early.remove(early.keys.first);
    }
  }

  Future<void> _publish(List<FilesItem> items) async {
    final system = _system;
    if (system == null || items.isEmpty) {
      return;
    }
    final generation = ++_clipboardGeneration;
    // An earlier staging keeps going for a paste that waits on it.
    _staging = null;
    clipboardReady = false;
    try {
      final local = deviceById(FilesDevice.localId)!.browser! as LocalFsBrowser;
      if (items.first.location.deviceId == FilesDevice.localId) {
        final paths = [
          for (final item in items)
            await local.realPath(item.location.root, item.path),
        ];
        if (generation == _clipboardGeneration) {
          await _writeSystem(system, paths);
        }
        return;
      }
      final client = deviceById(items.first.location.deviceId)?.client;
      if (client == null) {
        return;
      }
      final staging = _Staging([for (final item in items) _sourceKey(item)]);
      _staging = staging;
      _notify();
      FilesLog.write('clipboard: staging ${items.length} item(s)');
      // What the system clipboard holds now is an earlier copy: pasted in
      // Finder meanwhile it would be the wrong files. Whatever stays there
      // is older than this copy, so a paste here does not take it.
      await _clearOwnSystemClipboard(system);
      _systemPaths = await system.read();
      try {
        final folder = await Directory(
          p.join(
            (await _stagingRoot()).path,
            '${DateTime.now().millisecondsSinceEpoch}',
          ),
        ).create(recursive: true);
        final ids = await client.fetch([
          for (final item in items) (root: item.location.root, path: item.path),
        ], folder.path);
        FilesLog.write(
          'clipboard: staging as ${ids.map(FilesLog.id).join(',')}',
        );
        _stageArrived(staging, ids);
      } catch (error) {
        FilesLog.write('clipboard: staging failed (${error.runtimeType})');
        staging.start(const []);
      }
      if (generation == _clipboardGeneration) {
        await _publishStaged(staging);
      }
    } catch (_) {
      // The copy still works inside the file manager.
    }
  }

  /// [ids] carry [staging]: follow them, with whatever about them came in
  /// before they were known.
  void _stageArrived(_Staging staging, List<String> ids) {
    staging.start(ids);
    for (final id in ids) {
      _stagings[id] = staging;
    }
    _track(ids, refreshRemote: false);
    for (final id in ids) {
      if (_earlyPlaced.containsKey(id)) {
        final path = _earlyPlaced.remove(id);
        path == null ? _stagedGone(id) : _stagedArrived(id, path);
      }
    }
    // One the other device announced but never started does not keep the
    // clipboard "preparing" for good.
    staging.watch(FileCopies.noShowAfter, () {
      for (final id in ids) {
        if (staging.paths.containsKey(id) &&
            staging.paths[id] == null &&
            copies[id] == null) {
          FilesLog.write('clipboard: ${FilesLog.id(id)} never started');
          _stagedGone(id);
        }
      }
    });
  }

  /// A staged transfer landed at [path]; false if it is not one.
  bool _stagedArrived(String transferId, String path) {
    final staging = _stagings.remove(transferId);
    if (staging == null) {
      return false;
    }
    staging.place(transferId, path);
    unawaited(_publishStaged(staging));
    return true;
  }

  /// A staged transfer failed or could not be moved; false if it is not
  /// one.
  bool _stagedGone(String transferId) {
    final staging = _stagings.remove(transferId);
    if (staging == null) {
      return false;
    }
    staging.drop(transferId);
    unawaited(_publishStaged(staging));
    return true;
  }

  /// The staging of exactly [items], when that is what is being staged.
  _Staging? _stagingOf(List<FilesItem> items) {
    final staging = _staging;
    if (staging == null) {
      return null;
    }
    final keys = [for (final item in items) _sourceKey(item)]..sort();
    return listEquals(keys, staging.sources) ? staging : null;
  }

  /// A paste here of what is being staged: the same transfers carry it.
  /// Those still on their way land here instead, without waiting to reach
  /// the staging folder first; those already there are copied over.
  Future<void> _pasteStaged(
    FileCopyBatch batch,
    _Staging staging,
    FilesLocation target,
  ) async {
    try {
      final ids = await staging.ids;
      for (final id in ids) {
        copyList.add(batch, id);
      }
      copyList.started(batch);
      final local = deviceById(FilesDevice.localId)!.browser! as LocalFsBrowser;
      final folder = await local.realPath(target.root, target.path);
      for (final id in ids) {
        if (staging.paths.containsKey(id) &&
            staging.paths[id] == null &&
            TransferPlacements.shared.retarget(id, folder)) {
          staging.taken.add(id);
        }
      }
      await staging.settledFuture;
      // Those taken over landed here already (and are what the system
      // clipboard gets).
      final files = [
        for (final id in ids)
          if (!staging.taken.contains(id)) ?staging.paths[id],
      ];
      FilesLog.write(
        'paste: ${staging.taken.length} of ${ids.length} staged item(s) '
        'sent here, ${files.length} copied in',
      );
      for (final path in files) {
        await _copyInto(path, folder);
      }
      if (shownLocation == target) {
        await reload();
      }
    } catch (error) {
      // Shown as failed in the list of copies; pasting again retries.
      FilesLog.write('paste: staged copy failed (${error.runtimeType})');
    } finally {
      copyList.started(batch);
    }
  }

  static Future<void> _copyInto(String source, String folder) async {
    final name = p.basename(source);
    var dest = p.join(folder, name);
    final stem = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    for (
      var n = 2;
      await FileSystemEntity.type(dest, followLinks: false) !=
          FileSystemEntityType.notFound;
      n++
    ) {
      dest = p.join(folder, '$stem $n$ext');
    }
    if (await FileSystemEntity.isDirectory(source)) {
      await Directory(dest).create(recursive: true);
      await for (final entry in Directory(source).list(followLinks: false)) {
        await _copyInto(entry.path, dest);
      }
    } else {
      await File(source).copy(dest);
    }
  }

  /// Puts [staging]'s files on the system clipboard once all are there,
  /// if it is still the latest copy.
  Future<void> _publishStaged(_Staging staging) async {
    final system = _system;
    if (system == null ||
        !identical(staging, _staging) ||
        !staging.settled ||
        staging.published) {
      _notify();
      return;
    }
    staging.published = true;
    final paths = staging.files;
    // Something copied elsewhere since this copy is newer: left alone.
    if (!listEquals(await system.read(), _systemPaths)) {
      FilesLog.write('clipboard: copied elsewhere meanwhile, kept');
      _notify();
      return;
    }
    if (paths.isNotEmpty && await _writeSystem(system, paths)) {
      FilesLog.write('clipboard: ${paths.length} staged item(s) ready');
      clipboardReady = true;
      final generation = _clipboardGeneration;
      Timer(const Duration(seconds: 8), () {
        if (generation == _clipboardGeneration && clipboardReady) {
          clipboardReady = false;
          _notify();
        }
      });
    }
    _notify();
  }

  /// Writes [paths] to the system clipboard and remembers how it reads
  /// them back, which is what a later paste compares with.
  Future<bool> _writeSystem(
    FilesSystemClipboard system,
    List<String> paths,
  ) async {
    if (!await system.write(paths)) {
      FilesLog.write('clipboard: writing ${paths.length} item(s) failed');
      // What is there is older than the copy just made.
      _systemPaths = await system.read();
      return false;
    }
    final back = await system.read();
    _systemPaths = back.isEmpty ? paths : back;
    return true;
  }

  /// Takes this file manager's earlier copy off the system clipboard (and
  /// nothing someone copied elsewhere since).
  Future<void> _clearOwnSystemClipboard(FilesSystemClipboard system) async {
    if (_systemPaths.isEmpty) {
      return;
    }
    final current = await system.read();
    if (current.isNotEmpty && listEquals(current, _systemPaths)) {
      await system.clear();
    }
  }

  /// Files someone copied in another app (Finder, Explorer…), when the
  /// system clipboard holds those rather than what was copied here.
  Future<List<String>?> externalClipboardPaths() async {
    final system = _system;
    if (system == null) {
      return null;
    }
    final paths = await system.read();
    if (paths.isEmpty || listEquals(paths, _systemPaths)) {
      return null;
    }
    return paths;
  }

  /// Whether [items] can be copied into [target], and why not otherwise.
  FilesCopyProblem? copyProblem(List<FilesItem> items, FilesLocation target) {
    if (items.isEmpty) {
      return null;
    }
    final from = items.first.location.deviceId;
    final to = target.deviceId;
    if (from == to) {
      return FilesCopyProblem.sameDevice;
    }
    if (from != FilesDevice.localId && to != FilesDevice.localId) {
      return FilesCopyProblem.betweenOthers;
    }
    final remote = deviceById(from == FilesDevice.localId ? to : from);
    if (remote?.browser == null) {
      return FilesCopyProblem.notConnected;
    }
    return null;
  }

  /// What identifies a copy of [items] into [target], to notice the same
  /// one made twice.
  String copySignature(List<FilesItem> items, FilesLocation target) =>
      _signature(
        items.isNotEmpty &&
            items.first.location.deviceId == FilesDevice.localId,
        target,
        [for (final item in items) _sourceKey(item)],
      );

  /// This device's files by where they are on disk, so the same file
  /// copied here and copied in Finder is the same copy.
  String _sourceKey(FilesItem item) {
    final local = deviceById(FilesDevice.localId)?.browser;
    if (item.location.deviceId == FilesDevice.localId &&
        local is LocalFsBrowser) {
      try {
        final root = local.files.resolver.rootOf(item.location.root);
        return p.normalize(
          p.joinAll([
            root.directory,
            ...item.path.split('/').where((part) => part.isNotEmpty),
          ]),
        );
      } on FsPathException {
        // Unknown root: by its name, as for another device's files.
      }
    }
    return '${item.location.deviceId}:${item.location.root}/${item.path}';
  }

  String pathsSignature(List<String> paths, FilesLocation target) =>
      _signature(true, target, [for (final path in paths) p.normalize(path)]);

  static String _signature(
    bool upload,
    FilesLocation target,
    List<String> sources,
  ) =>
      '${upload ? 'up' : 'down'}|${target.deviceId}|${target.root}/'
      '${target.path}|${(List.of(sources)..sort()).join('|')}';

  /// Copies [items] into [target]: ordinary transfers that land in that
  /// folder when they complete. Returns how many started. [folderLabel]
  /// names the folder in the list of copies.
  Future<int> copy(
    List<FilesItem> items,
    FilesLocation target, {
    String? folderLabel,
  }) async {
    if (copyProblem(items, target) != null) {
      return 0;
    }
    final local = deviceById(FilesDevice.localId)!.browser! as LocalFsBrowser;
    final upload = items.first.location.deviceId == FilesDevice.localId;
    final remote = deviceById(
      upload ? target.deviceId : items.first.location.deviceId,
    )!;
    final client = remote.client!;
    // Copied here a moment ago, another device's files are already on
    // their way to the staging folder (for other apps to paste): this
    // paste takes them from there instead of fetching them a second time.
    // Once a paste took them over, another one fetches its own.
    final staging = !upload && target.deviceId == FilesDevice.localId
        ? _stagingOf(items)
        : null;
    if (staging != null && staging.taken.isEmpty) {
      final batch = copyList.start(
        upload: false,
        peerId: remote.id,
        deviceName: remote.name,
        folder: folderLabel ?? _folderName(target),
        names: [for (final item in items) p.basename(item.path)],
        signature: copySignature(items, target),
        target: target,
      );
      FilesLog.write('paste: ${items.length} item(s) from the staging');
      unawaited(_pasteStaged(batch, staging, target));
      return items.length;
    }
    // Shown at once, before anything is awaited: a second paste a moment
    // later finds this one under way. The other device answers shortly.
    late final FileCopyBatch batch;
    var itemOf = <String, FilesItem>{};
    final folder = upload
        ? Future.value('')
        : local.realPath(target.root, target.path);
    Future<List<String>> fetch(List<FilesItem> wanted) async {
      final ids = await client.fetch([
        for (final item in wanted) (root: item.location.root, path: item.path),
      ], await folder);
      for (var i = 0; i < ids.length && i < wanted.length; i++) {
        itemOf[ids[i]] = wanted[i];
      }
      _track(ids, refreshRemote: false);
      return ids;
    }

    batch = copyList.start(
      upload: upload,
      peerId: remote.id,
      deviceName: remote.name,
      folder: folderLabel ?? _folderName(target),
      names: [for (final item in items) p.basename(item.path)],
      signature: copySignature(items, target),
      target: target,
      again: upload
          ? null
          : () {
              // What has not arrived, asked for again.
              itemOf = {
                for (final entry in itemOf.entries)
                  if (batch.transfers.containsKey(entry.key))
                    entry.key: entry.value,
              };
              final arrived = itemOf.values.toSet();
              return fetch([
                for (final item in items)
                  if (!arrived.contains(item)) item,
              ]);
            },
    );
    FilesLog.write('copy: ${items.length} item(s) ${upload ? 'up' : 'down'}');
    try {
      List<String> ids;
      if (upload) {
        final paths = [
          for (final item in items)
            await local.realPath(item.location.root, item.path),
        ];
        ids = await client.upload(
          paths,
          target.root,
          target.path,
          onStarted: (id) => copyList.add(batch, id),
        );
        _track(ids, refreshRemote: true);
      } else {
        ids = await fetch(items);
        for (final id in ids) {
          copyList.add(batch, id);
        }
      }
      FilesLog.write('copy: as ${ids.map(FilesLog.id).join(',')}');
      return ids.length;
    } catch (error) {
      FilesLog.write('copy: failed (${error.runtimeType})');
      rethrow;
    } finally {
      copyList.started(batch);
    }
  }

  /// Local files dropped in from Finder or Explorer.
  Future<int> copyPaths(
    List<String> paths,
    FilesLocation target, {
    String? folderLabel,
  }) async {
    final remote = deviceById(target.deviceId);
    if (remote == null || remote.isLocal || remote.client == null) {
      return 0;
    }
    final batch = copyList.start(
      upload: true,
      peerId: remote.id,
      deviceName: remote.name,
      folder: folderLabel ?? _folderName(target),
      names: [for (final path in paths) p.basename(path)],
      signature: pathsSignature(paths, target),
      target: target,
    );
    FilesLog.write('copy: ${paths.length} item(s) up from elsewhere');
    try {
      final ids = await remote.client!.upload(
        paths,
        target.root,
        target.path,
        onStarted: (id) => copyList.add(batch, id),
      );
      _track(ids, refreshRemote: true);
      FilesLog.write('copy: as ${ids.map(FilesLog.id).join(',')}');
      return ids.length;
    } catch (error) {
      FilesLog.write('copy: failed (${error.runtimeType})');
      rethrow;
    } finally {
      copyList.started(batch);
    }
  }

  /// Where one of this device's items is on disk.
  Future<String> localPath(FilesItem item) {
    final local = deviceById(FilesDevice.localId)!.browser! as LocalFsBrowser;
    return local.realPath(item.location.root, item.path);
  }

  /// Another device's file fetched for an app it was dragged to (Finder,
  /// Explorer), into a folder of its own. [onProgress] hears how far the
  /// fetch is.
  FilesFetchOut fetchOut(
    FilesItem item, {
    void Function(double fraction)? onProgress,
  }) {
    final out = FilesFetchOut._(copyList.cancel);
    unawaited(_fetchOut(item, out, onProgress));
    return out;
  }

  Future<void> _fetchOut(
    FilesItem item,
    FilesFetchOut out,
    void Function(double fraction)? onProgress,
  ) async {
    final subscriptions = <StreamSubscription<Object?>>[];
    try {
      final client = deviceById(item.location.deviceId)?.client;
      if (client == null) {
        throw const RemoteFsException('offline');
      }
      final folder = out._folder = await Directory(
        p.join(
          (await _stagingRoot()).path,
          'out-${DateTime.now().microsecondsSinceEpoch}',
        ),
      ).create(recursive: true);
      final ids = await client.fetch([
        (root: item.location.root, path: item.path),
      ], folder.path);
      if (ids.length != 1) {
        throw const RemoteFsException('notFound');
      }
      final id = out._transferId = ids.single;
      FilesLog.write('drag out: as ${FilesLog.id(id)}');
      if (out._canceled) {
        out.cancel();
        return;
      }
      final placements = TransferPlacements.shared;
      var arrived = '';
      subscriptions
        ..add(
          placements.updates.listen((snapshot) {
            if (snapshot.transferId != id) {
              return;
            }
            onProgress?.call(snapshot.progress);
            switch (snapshot.state) {
              case FileTransferState.completed:
                arrived = snapshot.finalPath;
              case FileTransferState.failed || FileTransferState.canceled:
                out._fail(
                  RemoteFsException(
                    snapshot.lastError.isEmpty
                        ? snapshot.state.name
                        : snapshot.lastError,
                  ),
                );
              default:
                break;
            }
          }),
        )
        ..add(
          placements.placed.listen((placed) {
            if (placed.transferId == id) {
              out._done(placed.path);
            }
          }),
        )
        ..add(
          // Left where it arrived: handed over from there.
          placements.unplaced.listen((transferId) {
            if (transferId != id) {
              return;
            }
            arrived.isEmpty
                ? out._fail(const RemoteFsException('unplaced'))
                : out._done(arrived);
          }),
        );
      await out.path.then((_) {}, onError: (_) {});
    } catch (error) {
      FilesLog.write('drag out: failed (${error.runtimeType})');
      out._fail(error);
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
  }

  String _folderName(FilesLocation target) => target.path.isEmpty
      ? (deviceById(target.deviceId)?.name ?? '')
      : p.basename(target.path);

  final _refreshAfter = <String>{};

  void _track(List<String> ids, {required bool refreshRemote}) {
    final early = <TransferSnapshot>[];
    for (final id in ids) {
      copies[id] = null;
      if (refreshRemote) {
        _refreshAfter.add(id);
      }
      final snapshot = _earlySnapshots.remove(id);
      if (snapshot != null) {
        early.add(snapshot);
      }
    }
    early.forEach(_onTransfer);
    _notify();
  }

  void _onTransfer(TransferSnapshot snapshot) {
    if (!copies.containsKey(snapshot.transferId)) {
      // Perhaps a copy whose id is still on its way here.
      _remember(_earlySnapshots, snapshot.transferId, snapshot);
      return;
    }
    copies[snapshot.transferId] = snapshot;
    if (snapshot.state == FileTransferState.failed ||
        snapshot.state == FileTransferState.canceled) {
      _stagedGone(snapshot.transferId);
    }
    if (snapshot.state == FileTransferState.completed &&
        _refreshAfter.remove(snapshot.transferId) &&
        location?.deviceId != FilesDevice.localId) {
      Timer(const Duration(milliseconds: 600), () => unawaited(reload()));
    }
    final allDone = copies.values.every((copy) => copy != null && isDone(copy));
    if (allDone) {
      Timer(const Duration(seconds: 4), () {
        if (copies.values.every((copy) => copy != null && isDone(copy))) {
          copies.clear();
          _notify();
        }
      });
    }
    _notify();
  }

  static bool isDone(TransferSnapshot copy) =>
      copy.state == FileTransferState.completed ||
      copy.state == FileTransferState.failed ||
      copy.state == FileTransferState.canceled;

  static String errorReason(Object error) => switch (error) {
    RemoteFsException(:final reason) => reason,
    FsPathException(reason: 'exists') => FileBrowseError.exists,
    FsPathException(reason: 'not found') => FileBrowseError.notFound,
    FsPathException() => FileBrowseError.notAllowed,
    _ => FileBrowseError.io,
  };

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _devicesTimer?.cancel();
    _updates?.cancel();
    _placed?.cancel();
    _unplaced?.cancel();
    for (final staging in {..._stagings.values, ?_staging}) {
      staging.dispose();
    }
    for (final device in devices) {
      unawaited(device.client?.close());
    }
    revealed.dispose();
    super.dispose();
  }
}

/// Another device's file on its way here for another app
/// ([FilesController.fetchOut]).
class FilesFetchOut {
  FilesFetchOut._(this._cancelTransfer) {
    // Failing before anyone waits on it is not an uncaught error.
    _path.future.ignore();
  }

  final Future<void> Function(String transferId)? _cancelTransfer;
  final _path = Completer<String>();
  String? _transferId;
  Directory? _folder;
  bool _canceled = false;

  /// The file once it is all here.
  Future<String> get path => _path.future;

  /// The transfer bringing it, once the other device answered.
  String? get transferId => _transferId;

  void _done(String path) {
    if (!_path.isCompleted) {
      _path.complete(path);
    }
  }

  void _fail(Object error) {
    if (!_path.isCompleted) {
      _path.completeError(error);
    }
  }

  /// The app no longer wants it.
  void cancel() {
    _canceled = true;
    final id = _transferId;
    if (id != null && !_path.isCompleted) {
      unawaited(_cancelTransfer?.call(id));
    }
    _fail(const RemoteFsException('canceled'));
  }

  /// Handed over (or given up): the copy here goes.
  Future<void> dispose() async {
    try {
      await _folder?.delete(recursive: true);
    } on FileSystemException {
      // Cleared with the other staging folders after a day.
    }
  }
}

/// Another device's items on their way into a staging folder, for the
/// system clipboard and for a paste here to take from. Each copy has its
/// own: a paste waiting on one is not cut off by the next copy.
class _Staging {
  _Staging(List<String> sources) : sources = sources..sort();

  /// What is staged ([FilesController._sourceKey]), sorted.
  final List<String> sources;

  final _ids = Completer<List<String>>();

  /// The transfers carrying it, once the other device answered.
  Future<List<String>> get ids => _ids.future;

  /// Each transfer's file in the staging folder once there (null while on
  /// its way); one that failed is no longer listed.
  final paths = <String, String?>{};

  final _settled = Completer<void>();

  /// Everything has arrived or failed.
  bool get settled => _settled.isCompleted;
  Future<void> get settledFuture => _settled.future;

  /// Its files went to the system clipboard, or were not to.
  bool published = false;

  /// Transfers a paste took over on their way: they land in its folder.
  final taken = <String>{};

  Timer? _watch;

  List<String> get files => [for (final path in paths.values) ?path];

  void start(List<String> transferIds) {
    if (_ids.isCompleted) {
      return;
    }
    for (final id in transferIds) {
      paths[id] = null;
    }
    _ids.complete(transferIds);
    _check();
  }

  void place(String transferId, String path) {
    if (paths.containsKey(transferId)) {
      paths[transferId] = path;
      _check();
    }
  }

  void drop(String transferId) {
    paths.remove(transferId);
    _check();
  }

  /// Runs [check] after [after] unless everything has settled by then.
  void watch(Duration after, void Function() check) {
    _watch?.cancel();
    _watch = settled ? null : Timer(after, check);
  }

  void _check() {
    if (!_settled.isCompleted &&
        _ids.isCompleted &&
        !paths.values.contains(null)) {
      _watch?.cancel();
      _settled.complete();
    }
  }

  void dispose() => _watch?.cancel();
}
