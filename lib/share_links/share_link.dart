import 'share_password.dart';

/// One file or folder a link gives out.
class ShareItem {
  const ShareItem({
    required this.path,
    required this.name,
    required this.isDir,
  });

  /// Absolute path on this device, as it was chosen.
  final String path;

  /// What visitors see; unique within the link (a second `a.txt` from
  /// another folder becomes `a (2).txt`).
  final String name;
  final bool isDir;

  Map<String, Object?> toJson() => {'p': path, 'n': name, 'd': isDir};

  static ShareItem? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final path = json['p'];
    final name = json['n'];
    if (path is! String || name is! String || path.isEmpty || name.isEmpty) {
      return null;
    }
    return ShareItem(path: path, name: name, isDir: json['d'] == true);
  }
}

/// Whether a link's files are still where they were.
enum ShareAvailability { available, partlyMissing, missing }

/// A LAN download link: what it gives out, how it is reached and what it
/// has served. The setup is fixed; [enabled] changes through the store and
/// the counters are kept up to date by the server.
class ShareLink {
  ShareLink({
    required this.id,
    required this.route,
    required this.name,
    required this.items,
    required this.createdAt,
    this.password,
    this.enabled = true,
    this.visits = 0,
    this.downloads = 0,
    this.bytesServed = 0,
    this.lastVisitAt,
  });

  final String id;
  final String route;
  final String name;
  final List<ShareItem> items;
  final SharePasswordHash? password;
  final DateTime createdAt;
  bool enabled;
  int visits;
  int downloads;
  int bytesServed;
  DateTime? lastVisitAt;

  bool get hasPassword => password != null;

  /// One folder: its contents are the link's first page.
  bool get isSingleFolder => items.length == 1 && items.first.isDir;

  /// One file: the first page is a download page.
  bool get isSingleFile => items.length == 1 && !items.first.isDir;

  Map<String, Object?> toJson() => {
    'id': id,
    'route': route,
    'name': name,
    'items': [for (final item in items) item.toJson()],
    if (password != null) 'password': password!.toJson(),
    'enabled': enabled,
    'created': createdAt.millisecondsSinceEpoch,
    'visits': visits,
    'downloads': downloads,
    'bytes': bytesServed,
    if (lastVisitAt != null) 'lastVisit': lastVisitAt!.millisecondsSinceEpoch,
  };

  /// Null for anything malformed, so one bad record never loses the rest.
  static ShareLink? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final id = json['id'];
    final route = json['route'];
    final name = json['name'];
    final rawItems = json['items'];
    final created = json['created'];
    if (id is! String ||
        route is! String ||
        name is! String ||
        rawItems is! List ||
        created is! int) {
      return null;
    }
    final items = <ShareItem>[];
    for (final raw in rawItems) {
      final item = ShareItem.fromJson(raw);
      if (item != null) {
        items.add(item);
      }
    }
    if (items.isEmpty) {
      return null;
    }
    final rawPassword = json['password'];
    final password = rawPassword == null
        ? null
        : SharePasswordHash.fromJson(rawPassword);
    if (rawPassword != null && password == null) {
      // A password we cannot read must not turn into an open link.
      return null;
    }
    int count(String key) => switch (json[key]) {
      final int value when value >= 0 => value,
      _ => 0,
    };
    final lastVisit = json['lastVisit'];
    return ShareLink(
      id: id,
      route: route,
      name: name,
      items: items,
      password: password,
      enabled: json['enabled'] != false,
      createdAt: DateTime.fromMillisecondsSinceEpoch(created),
      visits: count('visits'),
      downloads: count('downloads'),
      bytesServed: count('bytes'),
      lastVisitAt: lastVisit is int
          ? DateTime.fromMillisecondsSinceEpoch(lastVisit)
          : null,
    );
  }
}
