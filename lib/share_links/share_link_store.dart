import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../helper/helper.dart'
    show
        LocalIpv4Candidate,
        getLocalIpAddress,
        localNetworkInterfaceDescriptions,
        selectLocalIpv4Address;
import '../helper/local.dart';
import 'share_lan.dart';
import 'share_link.dart';
import 'share_password.dart';
import 'share_routes.dart';
import 'share_server.dart';

export 'share_link.dart';
export 'share_routes.dart' show ShareRouteException, ShareRouteProblem;

/// Platforms that offer share links: the ones with local files the file
/// manager can browse (not iOS for now, not the web).
bool shareLinksSupported() =>
    !kIsWeb &&
    (Platform.isAndroid ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux);

/// Why a link could not be made, apart from its route.
enum ShareLinkProblem { itemsMissing }

class ShareLinkException implements Exception {
  const ShareLinkException(this.problem);

  final ShareLinkProblem problem;

  @override
  String toString() => 'ShareLinkException(${problem.name})';
}

enum ShareServerPhase { stopped, starting, running, failed }

enum ShareServerFailure { portsBusy, other }

/// Where the file server is. [port] while running; [failure] (and the
/// [ports] that were tried) after a failed start.
@immutable
class ShareServerState {
  const ShareServerState._(this.phase, {this.port, this.failure, this.ports});

  static const stopped = ShareServerState._(ShareServerPhase.stopped);
  static const starting = ShareServerState._(ShareServerPhase.starting);

  factory ShareServerState.running(int port) =>
      ShareServerState._(ShareServerPhase.running, port: port);

  factory ShareServerState.failed(
    ShareServerFailure failure, {
    List<int> ports = const [],
  }) => ShareServerState._(
    ShareServerPhase.failed,
    failure: failure,
    ports: ports,
  );

  final ShareServerPhase phase;
  final int? port;
  final ShareServerFailure? failure;
  final List<int>? ports;

  bool get isRunning => phase == ShareServerPhase.running;

  Map<String, Object?> toJson() => {
    'phase': phase.name,
    'port': ?port,
    'failure': ?failure?.name,
  };

  @override
  bool operator ==(Object other) =>
      other is ShareServerState &&
      other.phase == phase &&
      other.port == port &&
      other.failure == failure;

  @override
  int get hashCode => Object.hash(phase, port, failure);
}

/// Key-value storage for the store; SharedPreferences in the app.
abstract interface class ShareLinkPreferences {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<bool?> getBool(String key);
  Future<void> setBool(String key, bool value);
  Future<int?> getInt(String key);
  Future<void> setInt(String key, int value);
}

class SharedShareLinkPreferences implements ShareLinkPreferences {
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _sp async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<String?> getString(String key) async => (await _sp).getString(key);

  @override
  Future<void> setString(String key, String value) async =>
      (await _sp).setString(key, value);

  @override
  Future<bool?> getBool(String key) async => (await _sp).getBool(key);

  @override
  Future<void> setBool(String key, bool value) async =>
      (await _sp).setBool(key, value);

  @override
  Future<int?> getInt(String key) async => (await _sp).getInt(key);

  @override
  Future<void> setInt(String key, int value) async =>
      (await _sp).setInt(key, value);
}

/// Every share link on this device and the file server that serves them.
/// The server only listens while the service is on and at least one link
/// is enabled; changes to either start or stop it, one step at a time.
class ShareLinkStore extends ChangeNotifier implements ShareServerSource {
  ShareLinkStore({
    ShareLinkPreferences? preferences,
    ShareServer Function(ShareServerSource source)? server,
    Future<List<String>> Function()? addresses,
    Future<String> Function()? deviceName,
    DateTime Function()? clock,
    this.defaultPort = 10003,
    this.portSpan = 20,
    this.flushDelay = const Duration(seconds: 2),
  }) : _prefs = preferences ?? SharedShareLinkPreferences(),
       _serverFactory = server ?? ((source) => ShareServer(source: source)),
       _listAddresses = addresses ?? shareLanAddresses,
       _deviceName = deviceName ?? _localDeviceName,
       _clock = clock ?? DateTime.now;

  static final shared = ShareLinkStore();

  static const linksKey = 'share_links.v1';
  static const serviceKey = 'share_links.service_on';
  static const portKey = 'share_links.port';
  static const secretKey = 'share_links.secret';

  final int defaultPort;

  /// Ports after [defaultPort] tried when it is taken.
  final int portSpan;

  /// Counters are written at most this often.
  final Duration flushDelay;

  final ShareLinkPreferences _prefs;
  final ShareServer Function(ShareServerSource source) _serverFactory;
  final Future<List<String>> Function() _listAddresses;
  final Future<String> Function() _deviceName;
  final DateTime Function() _clock;

  late final ShareServer server = _serverFactory(this);

  List<ShareLink> _links = const [];
  bool _serviceOn = true;
  int _port = 0;
  ShareCookieSigner? _cookies;
  ShareServerState _state = ShareServerState.stopped;
  List<String> _addresses = const [];
  final _availability = <String, ShareAvailability>{};
  Future<void>? _loading;
  Future<void>? _initializing;
  bool _loaded = false;
  Future<void> _tail = Future<void>.value();
  Timer? _flushTimer;
  Timer? _notifyTimer;
  Timer? _retryTimer;
  Timer? _addressTimer;
  Timer? _missingTimer;
  bool _dirty = false;
  bool _disposed = false;

  /// Newest first.
  List<ShareLink> get links => List.unmodifiable(_links.reversed);
  bool get loaded => _loaded;

  /// Links that are switched on (whether or not the server is).
  int get enabledCount => _links.where((link) => link.enabled).length;
  bool get serviceOn => _serviceOn;
  ShareServerState get serverState => _state;

  /// This device's LAN addresses, the one other devices most likely reach
  /// first.
  List<String> get addresses => _addresses;

  /// The port links use: the running one, else the one last used.
  int get port => _state.port ?? (_port == 0 ? defaultPort : _port);

  /// The ports a start tries, for the "all taken" message.
  (int, int) get portRange => (defaultPort, defaultPort + portSpan);

  ShareAvailability availabilityOf(ShareLink link) =>
      _availability[link.id] ?? ShareAvailability.available;

  ShareLink? linkById(String id) {
    for (final link in _links) {
      if (link.id == id) {
        return link;
      }
    }
    return null;
  }

  /// `http://<address>:<port>/<route>`.
  String urlFor(ShareLink link, [String? address]) {
    final host = address ?? (_addresses.isEmpty ? null : _addresses.first);
    return 'http://${host ?? '127.0.0.1'}:$port/${link.route}';
  }

  /// A route that no link uses yet, for the create sheet's placeholder.
  String suggestRoute({bool short = false}) => ShareRoutes.generate(
    short: short,
    taken: {for (final link in _links) link.route},
  );

  /// Loads the saved links and starts the server when it should run.
  /// Safe to call more than once; later calls return at once.
  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    await _ensureLoaded();
    await _enqueue(_reconcile);
    unawaited(refreshAvailability());
  }

  /// Makes a link for [paths] (files and folders). [route] is used as
  /// typed (lowercased); without one a random one is made, 4 characters
  /// when [short]. Throws [ShareRouteException] for a route that cannot be
  /// used and [ShareLinkException] when none of the paths exist.
  Future<ShareLink> create({
    required List<String> paths,
    String? route,
    bool short = false,
    String? password,
    String? name,
  }) => _enqueue(() async {
    await _ensureLoaded();
    final taken = {for (final link in _links) link.route};
    final String chosen;
    final typed = route == null ? '' : ShareRoutes.normalize(route);
    if (typed.isEmpty) {
      chosen = ShareRoutes.generate(short: short, taken: taken);
    } else {
      final problem = ShareRoutes.check(typed);
      if (problem != null) {
        throw ShareRouteException(problem, typed);
      }
      if (taken.contains(typed)) {
        throw ShareRouteException(ShareRouteProblem.taken, typed);
      }
      chosen = typed;
    }
    final items = await shareItemsFor(paths);
    if (items.isEmpty) {
      throw const ShareLinkException(ShareLinkProblem.itemsMissing);
    }
    final hash = password == null || password.isEmpty
        ? null
        : await SharePasswordHash.create(password);
    final trimmed = name?.trim() ?? '';
    final link = ShareLink(
      id: _newId(),
      route: chosen,
      // Several unnamed items are named in each reader's language.
      name: trimmed.isNotEmpty
          ? trimmed
          : items.length == 1
          ? items.first.name
          : '',
      items: items,
      password: hash,
      createdAt: _clock(),
    );
    _links = [..._links, link];
    _availability[link.id] = ShareAvailability.available;
    await _persist();
    _notify();
    await _reconcile();
    return link;
  });

  Future<void> setEnabled(String id, bool enabled) => _enqueue(() async {
    await _ensureLoaded();
    final link = linkById(id);
    if (link == null || link.enabled == enabled) {
      return;
    }
    link.enabled = enabled;
    if (!enabled) {
      server.dropLink(id);
    }
    await _persist();
    _notify();
    await _reconcile();
  });

  Future<void> remove(String id) => _enqueue(() async {
    await _ensureLoaded();
    final link = linkById(id);
    if (link == null) {
      return;
    }
    _links = [
      for (final other in _links)
        if (other.id != id) other,
    ];
    _availability.remove(id);
    server.dropLink(id);
    await _persist();
    _notify();
    await _reconcile();
  });

  /// Turns the whole file server on or off; links are kept either way.
  Future<void> setServiceOn(bool on) => _enqueue(() async {
    await _ensureLoaded();
    if (_serviceOn == on) {
      await _reconcile();
      return;
    }
    _serviceOn = on;
    await _prefs.setBool(serviceKey, on);
    _notify();
    await _reconcile();
  });

  /// Tries again after a failed start.
  Future<void> retry() => _enqueue(_reconcile);

  /// Looks again at the network interfaces.
  Future<void> refreshAddresses() async {
    List<String> found;
    try {
      found = await _listAddresses();
    } on Object {
      found = const [];
    }
    if (!listEquals(found, _addresses)) {
      _addresses = List.unmodifiable(found);
      _notify();
    }
  }

  /// Checks whether every link's files are still there.
  Future<void> refreshAvailability() async {
    await _ensureLoaded();
    var changed = false;
    for (final link in _links.toList()) {
      var present = 0;
      for (final item in link.items) {
        if (await _exists(item)) {
          present++;
        }
      }
      final availability = present == link.items.length
          ? ShareAvailability.available
          : present == 0
          ? ShareAvailability.missing
          : ShareAvailability.partlyMissing;
      if (_availability[link.id] != availability) {
        _availability[link.id] = availability;
        changed = true;
      }
    }
    if (changed) {
      _notify();
    }
  }

  /// Writes pending counters and closes the port, keeping the setting.
  Future<void> shutdown() => _enqueue(() async {
    await _flush();
    _cancelTimers();
    if (server.isRunning) {
      await server.stop();
    }
    _state = ShareServerState.stopped;
  });

  // ShareServerSource

  @override
  ShareLink? linkForRoute(String route) {
    if (!_serviceOn) {
      return null;
    }
    for (final link in _links) {
      if (link.enabled && link.route == route) {
        return link;
      }
    }
    return null;
  }

  @override
  ShareCookieSigner get cookies => _cookies!;

  @override
  Future<String> deviceName() => _deviceName();

  @override
  void linkVisited(ShareLink link, {required bool counted}) {
    if (counted) {
      link.visits++;
    }
    link.lastVisitAt = _clock();
    _statsChanged();
  }

  @override
  void linkDownloaded(ShareLink link) {
    link.downloads++;
    _statsChanged();
  }

  @override
  void linkServed(ShareLink link, int bytes) {
    link.bytesServed += bytes;
    _statsChanged();
  }

  @override
  void linkMissing(ShareLink link) {
    _missingTimer ??= Timer(const Duration(milliseconds: 500), () {
      _missingTimer = null;
      unawaited(refreshAvailability());
    });
  }

  // Internals

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final raw = await _prefs.getString(linksKey);
    final links = <ShareLink>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final seen = <String>{};
          for (final entry in decoded) {
            final link = ShareLink.fromJson(entry);
            if (link != null && seen.add(link.route)) {
              links.add(link);
            }
          }
        }
      } on FormatException {
        // A damaged list starts over rather than breaking the app.
      }
    }
    _links = links;
    _serviceOn = await _prefs.getBool(serviceKey) ?? true;
    _port = await _prefs.getInt(portKey) ?? 0;
    var secret = await _prefs.getString(secretKey);
    List<int>? key;
    if (secret != null) {
      try {
        key = base64.decode(secret);
      } on FormatException {
        key = null;
      }
    }
    if (key == null || key.length < 32) {
      final rng = Random.secure();
      key = List<int>.generate(32, (_) => rng.nextInt(256));
      secret = base64.encode(key);
      await _prefs.setString(secretKey, secret);
    }
    _cookies = ShareCookieSigner(key);
    _loaded = true;
    _notify();
  }

  List<int> _candidatePorts() {
    final ports = <int>[];
    if (_port > 0) {
      ports.add(_port);
    }
    for (var port = defaultPort; port <= defaultPort + portSpan; port++) {
      if (!ports.contains(port)) {
        ports.add(port);
      }
    }
    return ports;
  }

  Future<void> _reconcile() async {
    if (_disposed) {
      return;
    }
    final wanted = _serviceOn && _links.any((link) => link.enabled);
    if (wanted) {
      if (server.isRunning) {
        _setState(ShareServerState.running(server.port!));
        return;
      }
      _retryTimer?.cancel();
      _retryTimer = null;
      _setState(ShareServerState.starting);
      try {
        final port = await server.start(_candidatePorts());
        if (port != _port) {
          _port = port;
          await _prefs.setInt(portKey, port);
        }
        _setState(ShareServerState.running(port));
        await refreshAddresses();
        _addressTimer ??= Timer.periodic(
          const Duration(seconds: 20),
          (_) => unawaited(refreshAddresses()),
        );
      } on ShareServerBindException catch (error) {
        _setState(
          ShareServerState.failed(
            ShareServerFailure.portsBusy,
            ports: error.ports,
          ),
        );
        _scheduleRetry();
      } on Object {
        _setState(ShareServerState.failed(ShareServerFailure.other));
        _scheduleRetry();
      }
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    _addressTimer?.cancel();
    _addressTimer = null;
    if (server.isRunning) {
      await server.stop();
    }
    _setState(ShareServerState.stopped);
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 15), () {
      _retryTimer = null;
      unawaited(_enqueue(_reconcile));
    });
  }

  void _setState(ShareServerState state) {
    if (_state == state) {
      return;
    }
    _state = state;
    _notify();
  }

  void _statsChanged() {
    _dirty = true;
    _flushTimer ??= Timer(flushDelay, () {
      _flushTimer = null;
      unawaited(_flush());
    });
    _notifyTimer ??= Timer(const Duration(milliseconds: 400), () {
      _notifyTimer = null;
      _notify();
    });
  }

  Future<void> _flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_dirty) {
      return;
    }
    await _persist();
  }

  Future<void> _persist() async {
    _dirty = false;
    final json = jsonEncode([for (final link in _links) link.toJson()]);
    await _prefs.setString(linksKey, json);
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _cancelTimers() {
    for (final timer in [
      _flushTimer,
      _notifyTimer,
      _retryTimer,
      _addressTimer,
      _missingTimer,
    ]) {
      timer?.cancel();
    }
    _flushTimer = null;
    _notifyTimer = null;
    _retryTimer = null;
    _addressTimer = null;
    _missingTimer = null;
  }

  String _newId() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random.secure();
    return List.generate(
      20,
      (_) => alphabet[rng.nextInt(alphabet.length)],
    ).join();
  }

  static Future<bool> _exists(ShareItem item) async {
    try {
      final type = await FileSystemEntity.type(item.path);
      return item.isDir
          ? type == FileSystemEntityType.directory
          : type == FileSystemEntityType.file;
    } on FileSystemException {
      return false;
    }
  }

  static Future<String> _localDeviceName() async {
    try {
      final name = await LocalSetting().deviceDisplayName();
      if (name.trim().isNotEmpty) {
        return name;
      }
    } on Object {
      // Falls through to the host name.
    }
    return Platform.localHostname;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    unawaited(server.stop());
    super.dispose();
  }
}

/// [paths] as link items: absolute, existing, without repeats, each with
/// a name of its own (`a.txt`, `a (2).txt`).
Future<List<ShareItem>> shareItemsFor(List<String> paths) async {
  final items = <ShareItem>[];
  final seenPaths = <String>{};
  final names = <String>{};
  for (final raw in paths) {
    if (raw.trim().isEmpty) {
      continue;
    }
    final path = p.normalize(p.absolute(raw));
    if (!seenPaths.add(Platform.isWindows ? path.toLowerCase() : path)) {
      continue;
    }
    FileSystemEntityType type;
    try {
      type = await FileSystemEntity.type(path);
    } on FileSystemException {
      continue;
    }
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      continue;
    }
    final isDir = type == FileSystemEntityType.directory;
    var base = p.basename(path);
    if (base.isEmpty || base == p.separator) {
      base = path.replaceAll(RegExp(r'[\\/:]+'), '_');
    }
    var name = base;
    var copy = 2;
    while (names.contains(name.toLowerCase())) {
      final ext = isDir ? '' : p.extension(base);
      final stem = ext.isEmpty
          ? base
          : base.substring(0, base.length - ext.length);
      name = '$stem ($copy)$ext';
      copy++;
    }
    names.add(name.toLowerCase());
    items.add(ShareItem(path: path, name: name, isDir: isDir));
  }
  return items;
}

/// This device's IPv4 addresses on the local network, the one
/// [getLocalIpAddress] picks first, then the rest by how likely they are
/// a real LAN (Wi-Fi and Ethernet before VPNs and virtual adapters).
/// Mobile-data interfaces are left out.
Future<List<String>> shareLanAddresses() async {
  String? primary;
  try {
    primary = await getLocalIpAddress();
  } on Object {
    primary = null;
  }
  final candidates = <LocalIpv4Candidate>[];
  try {
    final descriptions = await localNetworkInterfaceDescriptions();
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: true,
    )) {
      final name = interface.name.toLowerCase();
      final description = (descriptions[interface.index] ?? '').toLowerCase();
      // Mobile data, and bridges only this device's containers and virtual
      // machines can reach.
      const skipped = [
        'rmnet',
        'ccmni',
        'pdp',
        'v4-',
        'clat',
        'docker',
        'br-',
        'veth',
        'virbr',
        'vmnet',
        'vboxnet',
        'vethernet',
      ];
      if (skipped.any(name.startsWith) ||
          description.contains('hyper-v') ||
          description.contains('virtualbox') ||
          description.contains('vmware')) {
        continue;
      }
      for (final address in interface.addresses) {
        if (address.isLoopback || !isShareLanAddress(address)) {
          continue;
        }
        candidates.add((
          address: address.address,
          interfaceName:
              '${interface.name} ${descriptions[interface.index] ?? ''}',
        ));
      }
    }
  } on SocketException {
    // Fall back to the primary address alone.
  }
  final ordered = <String>[];
  final parsed = primary == null ? null : InternetAddress.tryParse(primary);
  if (parsed != null && !parsed.isLoopback && isShareLanAddress(parsed)) {
    ordered.add(parsed.address);
  }
  final rest = candidates.where((c) => c.address != primary).toList();
  while (rest.isNotEmpty) {
    final best = selectLocalIpv4Address(rest);
    if (best == null) {
      break;
    }
    if (!ordered.contains(best)) {
      ordered.add(best);
    }
    rest.removeWhere((c) => c.address == best);
  }
  return ordered;
}
