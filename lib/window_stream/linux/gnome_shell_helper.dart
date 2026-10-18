import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Where Whisper's GNOME Shell extension stands on this computer.
enum GnomeShellHelperState {
  /// Not GNOME on Wayland: windows of this desktop cannot be shared.
  unsupported,

  /// Never installed.
  notInstalled,

  /// Installed, but an older version than this Whisper brings.
  outdated,

  /// Installed and enabled; GNOME Shell loads it at the next login.
  needsRelogin,

  /// Installed, but turned off in GNOME's Extensions app.
  disabled,

  /// The user turned all GNOME extensions off.
  extensionsOff,

  /// Running and answering Whisper.
  ready,
}

enum GnomeShellHelperResult { applied, failed }

/// Installs and watches the GNOME Shell extension that lets this desktop
/// share its windows (assets/window_stream/gnome-shell).
///
/// On GNOME Wayland only the compositor can move other apps' windows, read
/// which field has the keyboard focus, and synthesise input in a way every
/// keyboard layout and script survives. The extension does exactly that for
/// Whisper over D-Bus (com.vireen.Whisper.Shell1) and checks every caller
/// against `allowed-exe`, which this class keeps pointing at the running
/// Whisper executable (an AppImage mounts somewhere new each launch).
///
/// GNOME Shell on Wayland loads new extensions only at login, so a first
/// install (or one that changes the protocol) needs one logout and login.
class GnomeShellHelperController extends ChangeNotifier {
  GnomeShellHelperController({
    DBusClient Function()? client,
    Future<ProcessResult> Function(String, List<String>)? run,
    Future<ByteData> Function(String key)? loadAsset,
    Map<String, String>? environment,
    String? executable,
    String? home,
    bool? isLinux,
  }) : _isLinux = isLinux ?? Platform.isLinux,
       _client = client ?? DBusClient.session,
       _run = run ?? ((exe, args) => Process.run(exe, args)),
       _loadAsset = loadAsset ?? rootBundle.load,
       _environment = environment ?? Platform.environment,
       _executable = executable,
       _home = home;

  static final shared = GnomeShellHelperController();

  static const uuid = 'whisper-window-stream@vireen.com';
  static const assetFolder = 'assets/window_stream/gnome-shell/$uuid';
  static const assetFiles = ['metadata.json', 'extension.js'];
  static const busName = 'com.vireen.Whisper.Shell';
  static const objectPath = '/com/vireen/Whisper/Shell';
  static const interfaceName = 'com.vireen.Whisper.Shell1';

  /// Executables kept in allowed-exe besides the running one (debug and
  /// release builds side by side); missing files are dropped.
  static const maxAllowed = 4;

  final DBusClient Function() _client;
  final Future<ProcessResult> Function(String, List<String>) _run;
  final Future<ByteData> Function(String key) _loadAsset;
  final Map<String, String> _environment;
  final String? _executable;
  final String? _home;
  final bool _isLinux;

  GnomeShellHelperState _state = GnomeShellHelperState.notInstalled;
  bool _busy = false;
  bool _checked = false;
  Future<void>? _refreshing;

  GnomeShellHelperState get state =>
      supported ? _state : GnomeShellHelperState.unsupported;
  bool get busy => _busy;

  /// The state has been read at least once.
  bool get checked => _checked;

  /// GNOME on Wayland, where the helper applies.
  bool get supported {
    if (!_isLinux) return false;
    final wayland =
        _environment['XDG_SESSION_TYPE'] == 'wayland' ||
        (_environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty;
    final desktop = (_environment['XDG_CURRENT_DESKTOP'] ?? '').toLowerCase();
    return wayland && desktop.split(':').contains('gnome');
  }

  String get _homeDir => _home ?? _environment['HOME'] ?? '';

  /// ~/.local/share/gnome-shell/extensions/<uuid> (XDG_DATA_HOME aware).
  String get installDir {
    final data = _environment['XDG_DATA_HOME'];
    final base = data != null && data.isNotEmpty
        ? data
        : p.join(_homeDir, '.local', 'share');
    return p.join(base, 'gnome-shell', 'extensions', uuid);
  }

  /// The path GNOME Shell sees for this process (/proc/<pid>/exe).
  String get executablePath {
    final given = _executable;
    if (given != null) return given;
    try {
      return File('/proc/self/exe').resolveSymbolicLinksSync();
    } on FileSystemException {
      return Platform.resolvedExecutable;
    }
  }

  /// Reads the state again; also keeps allowed-exe current when installed.
  Future<void> refresh() {
    if (!supported) return Future.value();
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    final next = await _readState(updateAllowed: true);
    final first = !_checked;
    _checked = true;
    if (next != _state || first) {
      _state = next;
      notifyListeners();
    }
  }

  /// Installs or updates the extension and enables it. The result is
  /// [GnomeShellHelperState.needsRelogin] unless the running copy already
  /// speaks this version's protocol.
  Future<GnomeShellHelperResult> install() async {
    if (!supported || _busy) return GnomeShellHelperResult.failed;
    _busy = true;
    notifyListeners();
    try {
      final files = <String, Uint8List>{};
      for (final name in assetFiles) {
        final data = await _loadAsset('$assetFolder/$name');
        files[name] = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
      }
      final dir = Directory(installDir);
      await dir.create(recursive: true);
      for (final entry in files.entries) {
        await _writeAtomically(p.join(dir.path, entry.key), entry.value);
      }
      await _writeAllowed();
      await _enable();
      _state = await _readState(updateAllowed: false);
      _checked = true;
      return GnomeShellHelperResult.applied;
    } on Object catch (error) {
      debugPrint('gnome helper install failed: $error');
      return GnomeShellHelperResult.failed;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Turns the extension back on after it was switched off in GNOME's
  /// Extensions app, or turns user extensions back on (the user confirmed).
  Future<GnomeShellHelperResult> enable() async {
    if (!supported || _busy) return GnomeShellHelperResult.failed;
    _busy = true;
    notifyListeners();
    try {
      if (_state == GnomeShellHelperState.extensionsOff) {
        await _gsettings([
          'set',
          'org.gnome.shell',
          'disable-user-extensions',
          'false',
        ]);
      }
      await _enable();
      // A loaded extension starts at once; wait a moment for its answer.
      for (var attempt = 0; attempt < 10; attempt++) {
        _state = await _readState(updateAllowed: false);
        if (_state == GnomeShellHelperState.ready) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return _state == GnomeShellHelperState.ready ||
              _state == GnomeShellHelperState.needsRelogin
          ? GnomeShellHelperResult.applied
          : GnomeShellHelperResult.failed;
    } on Object catch (error) {
      debugPrint('gnome helper enable failed: $error');
      return GnomeShellHelperResult.failed;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Asks GNOME to log out (it shows its own confirmation).
  Future<bool> logOut() async {
    DBusClient? client;
    try {
      client = _client();
      await DBusRemoteObject(
        client,
        name: 'org.gnome.SessionManager',
        path: DBusObjectPath('/org/gnome/SessionManager'),
      ).callMethod('org.gnome.SessionManager', 'Logout', [
        const DBusUint32(0),
      ], replySignature: DBusSignature(''));
      return true;
    } on Object {
      return false;
    } finally {
      await client?.close();
    }
  }

  // ---------------------------------------------------------------- state

  Future<GnomeShellHelperState> _readState({
    required bool updateAllowed,
  }) async {
    final installed = File(p.join(installDir, 'extension.js'));
    if (!await installed.exists()) return GnomeShellHelperState.notInstalled;
    var current = true;
    int? bundledProtocol;
    try {
      final bundled = await _loadAsset('$assetFolder/extension.js');
      final bundledBytes = bundled.buffer.asUint8List(
        bundled.offsetInBytes,
        bundled.lengthInBytes,
      );
      current = listEquals(await installed.readAsBytes(), bundledBytes);
      bundledProtocol = protocolOf(
        utf8.decode(bundledBytes, allowMalformed: true),
      );
    } on Object {
      // No bundled copy (assets missing): judge by what runs.
    }
    if (updateAllowed) await _writeAllowed(onlyIfMissing: true);
    final running = await _runningProtocol();
    if (running != null &&
        (bundledProtocol == null || running == bundledProtocol)) {
      return current
          ? GnomeShellHelperState.ready
          : GnomeShellHelperState.outdated;
    }
    if (!current) return GnomeShellHelperState.outdated;
    if (await _userExtensionsOff()) return GnomeShellHelperState.extensionsOff;
    final shellState = await _shellExtensionState();
    // 2 INACTIVE: known to the shell and switched off.
    if (shellState == 2 && !await _listedEnabled()) {
      return GnomeShellHelperState.disabled;
    }
    return GnomeShellHelperState.needsRelogin;
  }

  /// `const PROTOCOL_VERSION = N` in the extension's source.
  @visibleForTesting
  static int? protocolOf(String source) {
    final match = RegExp(r'const PROTOCOL_VERSION = (\d+);').firstMatch(source);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// The protocol the running helper speaks, or null when it does not
  /// answer (not loaded, or it refuses this executable).
  Future<int?> _runningProtocol() async {
    DBusClient? client;
    try {
      client = _client();
      final reply =
          await DBusRemoteObject(
                client,
                name: busName,
                path: DBusObjectPath(objectPath),
              )
              .callMethod(
                interfaceName,
                'GetInfo',
                const [],
                replySignature: DBusSignature('a{sv}'),
              )
              .timeout(const Duration(seconds: 2));
      final info = reply.returnValues.first.asStringVariantDict();
      final version = info['version'];
      return version is DBusUint32 ? version.value : null;
    } on Object {
      return null;
    } finally {
      await client?.close();
    }
  }

  /// ExtensionState from GNOME Shell (1 active, 2 inactive, 3 error, …), or
  /// null when the shell does not know the extension (installed after login).
  Future<int?> _shellExtensionState() async {
    DBusClient? client;
    try {
      client = _client();
      final reply =
          await DBusRemoteObject(
                client,
                name: 'org.gnome.Shell',
                path: DBusObjectPath('/org/gnome/Shell'),
              )
              .callMethod(
                'org.gnome.Shell.Extensions',
                'GetExtensionInfo',
                [const DBusString(uuid)],
                replySignature: DBusSignature('a{sv}'),
              )
              .timeout(const Duration(seconds: 2));
      final info = reply.returnValues.first.asStringVariantDict();
      final state = info['state'];
      if (state is DBusDouble) return state.value.round();
      if (state is DBusInt32) return state.value;
      if (state is DBusUint32) return state.value;
      return null;
    } on Object {
      return null;
    } finally {
      await client?.close();
    }
  }

  // ---------------------------------------------------------------- files

  Future<void> _writeAtomically(String path, List<int> bytes) async {
    final temp = File('$path.whisper-tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(path);
  }

  /// Keeps the running executable in allowed-exe (first), with up to
  /// [maxAllowed] - 1 others that still exist (debug and release builds).
  Future<void> _writeAllowed({bool onlyIfMissing = false}) async {
    final file = File(p.join(installDir, 'allowed-exe'));
    final exe = executablePath;
    var existing = <String>[];
    if (await file.exists()) {
      existing = (await file.readAsLines())
          .map((line) => line.trim())
          .where((line) => line.startsWith('/'))
          .toList();
    }
    if (onlyIfMissing && existing.contains(exe)) return;
    final keep = <String>[exe];
    for (final path in existing) {
      if (keep.length >= maxAllowed) break;
      if (path == exe || keep.contains(path)) continue;
      // An AppImage mount from an earlier launch is gone; so is its entry.
      if (await File(path).exists()) keep.add(path);
    }
    await file.parent.create(recursive: true);
    await _writeAtomically(file.path, utf8.encode('${keep.join('\n')}\n'));
  }

  // ---------------------------------------------------------------- settings

  Future<String?> _gsettings(List<String> args) async {
    try {
      final result = await _run('gsettings', args);
      if (result.exitCode != 0) return null;
      return (result.stdout as String).trim();
    } on ProcessException {
      return null;
    }
  }

  Future<bool> _userExtensionsOff() async =>
      await _gsettings(['get', 'org.gnome.shell', 'disable-user-extensions']) ==
      'true';

  Future<List<String>> _list(String key) async {
    final value = await _gsettings(['get', 'org.gnome.shell', key]);
    return parseStringList(value ?? '');
  }

  Future<bool> _listedEnabled() async =>
      (await _list('enabled-extensions')).contains(uuid);

  /// Adds the extension to enabled-extensions (and out of
  /// disabled-extensions). User extensions switched off as a whole stay off:
  /// that is the user's call (see [enable]).
  Future<void> _enable() async {
    final enabled = await _list('enabled-extensions');
    if (!enabled.contains(uuid)) {
      await _gsettings([
        'set',
        'org.gnome.shell',
        'enabled-extensions',
        formatStringList([...enabled, uuid]),
      ]);
    }
    final disabled = await _list('disabled-extensions');
    if (disabled.contains(uuid)) {
      await _gsettings([
        'set',
        'org.gnome.shell',
        'disabled-extensions',
        formatStringList(disabled.where((id) => id != uuid).toList()),
      ]);
    }
    // Known to the running shell (enabled before, switched off since): on now.
    DBusClient? client;
    try {
      client = _client();
      await DBusRemoteObject(
            client,
            name: 'org.gnome.Shell',
            path: DBusObjectPath('/org/gnome/Shell'),
          )
          .callMethod(
            'org.gnome.Shell.Extensions',
            'EnableExtension',
            [const DBusString(uuid)],
            replySignature: DBusSignature('b'),
          )
          .timeout(const Duration(seconds: 2));
    } on Object {
      // Not loaded yet: the next login does it.
    } finally {
      await client?.close();
    }
  }

  /// GVariant text of a string array (`['a', 'b']`, `@as []`).
  @visibleForTesting
  static List<String> parseStringList(String text) {
    final value = text.trim();
    if (value.isEmpty || value.startsWith('@as')) return const [];
    return RegExp(r"'((?:[^'\\]|\\.)*)'")
        .allMatches(value)
        .map((m) => m.group(1)!.replaceAll(r"\'", "'").replaceAll(r'\\', r'\'))
        .toList();
  }

  @visibleForTesting
  static String formatStringList(List<String> items) {
    if (items.isEmpty) return '@as []';
    final quoted = items
        .map(
          (item) => "'${item.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'",
        )
        .join(', ');
    return '[$quoted]';
  }
}
