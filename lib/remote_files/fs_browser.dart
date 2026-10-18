import 'dart:typed_data';

import 'fs_client.dart';
import 'fs_host_files.dart';
import 'fs_paths.dart';
import 'fs_platform.dart';

/// A place to start browsing: a root itself, or a well-known folder in it.
class FsPlace {
  const FsPlace({
    required this.root,
    required this.path,
    required this.kind,
    this.rootKind = 'home',
    this.label = '',
    this.drive = '',
    this.removable = false,
  });

  final String root;
  final String path;

  /// 'root' for the root itself, else a shortcut kind (downloads, …).
  final String kind;

  /// What the root is: home, storage, documents, drive or volume.
  final String rootKind;

  /// The volume's own name, when it has one.
  final String label;

  /// Windows drive letter, for drives.
  final String drive;
  final bool removable;
}

/// One side of the file manager: this device or another one. Both look
/// the same to the UI, so the two panes behave identically.
abstract interface class FsBrowser {
  bool get isLocal;
  bool get hasTrash;
  List<FsPlace> get places;
  Future<FsPage> list(
    String root,
    String path, {
    int offset = 0,
    bool showHidden = false,
  });
  Future<Uint8List?> thumbnail(String root, String path);
  Future<String> mkdir(String root, String parent, String name);
  Future<String> rename(String root, String path, String name);
  Future<void> remove(String root, String path, {bool permanent = false});
}

List<FsPlace> _placesOf(
  String root,
  Iterable<FsShortcut> shortcuts, {
  String rootKind = 'home',
  String label = '',
  String drive = '',
  bool removable = false,
}) => [
  FsPlace(
    root: root,
    path: '',
    kind: 'root',
    rootKind: rootKind,
    label: label,
    drive: drive,
    removable: removable,
  ),
  for (final shortcut in shortcuts)
    FsPlace(root: root, path: shortcut.path, kind: shortcut.kind),
];

class LocalFsBrowser implements FsBrowser {
  LocalFsBrowser({FsHostFiles? files}) : files = files ?? FsHostFiles();

  final FsHostFiles files;

  @override
  bool get isLocal => true;

  @override
  bool get hasTrash => FsPlatform.hasTrash;

  @override
  List<FsPlace> get places => [
    for (final root in files.resolver.roots)
      ..._placesOf(
        root.id,
        root.shortcuts,
        rootKind: root.kind.name,
        label: root.label,
        drive: root.drive,
        removable: root.removable,
      ),
  ];

  /// The real path, for handing local items to a transfer.
  Future<String> realPath(String root, String path) =>
      files.resolver.resolveExisting(root, path);

  @override
  Future<FsPage> list(
    String root,
    String path, {
    int offset = 0,
    bool showHidden = false,
  }) => files.list(root, path, offset: offset, showHidden: showHidden);

  @override
  Future<Uint8List?> thumbnail(String root, String path) async {
    try {
      return FsPlatform.thumbnail(await realPath(root, path), size: 192);
    } on FsPathException {
      return null;
    }
  }

  @override
  Future<String> mkdir(String root, String parent, String name) =>
      files.mkdir(root, parent, name);

  @override
  Future<String> rename(String root, String path, String name) =>
      files.rename(root, path, name);

  @override
  Future<void> remove(
    String root,
    String path, {
    bool permanent = false,
  }) async {
    if (hasTrash) {
      final real = await files.resolver.resolveEntry(root, path);
      if (!await FsPlatform.trash(real)) {
        throw const RemoteFsException('io');
      }
      return;
    }
    if (!permanent) {
      throw const RemoteFsException('noTrash');
    }
    await files.deletePermanently(root, path);
  }
}

class RemoteFsBrowser implements FsBrowser {
  RemoteFsBrowser(this.client, this.info);

  final RemoteFilesClient client;
  final RemoteFsInfo info;

  @override
  bool get isLocal => false;

  @override
  bool get hasTrash => info.hasTrash;

  @override
  List<FsPlace> get places => [
    for (final root in info.roots)
      ..._placesOf(
        root.id,
        root.shortcuts,
        rootKind: root.kind,
        label: root.name,
        drive: root.drive,
        removable: root.removable,
      ),
  ];

  @override
  Future<FsPage> list(
    String root,
    String path, {
    int offset = 0,
    bool showHidden = false,
  }) => client.list(root, path, offset: offset, showHidden: showHidden);

  @override
  Future<Uint8List?> thumbnail(String root, String path) =>
      client.thumbnail(root, path, size: 192);

  @override
  Future<String> mkdir(String root, String parent, String name) =>
      client.mkdir(root, parent, name);

  @override
  Future<String> rename(String root, String path, String name) =>
      client.rename(root, path, name);

  @override
  Future<void> remove(String root, String path, {bool permanent = false}) =>
      client.remove(root, path, permanent: permanent);
}
