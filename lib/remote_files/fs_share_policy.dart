import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../helper/app_private_paths.dart';

/// What a path is resolved for. On a computer that decides how much of it
/// another device may have (see [FsSharePolicy]).
enum FsUse {
  /// A listing. A folder on the way to a shared one lists only that way.
  browse,

  /// Opening, reading, a thumbnail.
  read,

  /// Copying out whole: a folder takes everything in it along.
  copy,

  /// A folder something new goes into, such as a copy that arrives.
  fill,

  /// Writing, renaming, moving, deleting, setting the time.
  change,
}

/// Unicode format characters that HFS+ leaves out of names when it compares
/// them, as git does when it looks for `.git` (`is_hfs_dotgit`).
final _ignorable = RegExp(
  r'[\u200b-\u200f\u202a-\u202e\u2060-\u2064\u206a-\u206f\ufeff]',
  unicode: true,
);

/// [text] as a file system that ignores case and the characters above would
/// compare it. For refusing, never for allowing.
String fsFold(String text) =>
    text.replaceAll(_ignorable, '').toUpperCase().toLowerCase();

bool _within(String base, String path) =>
    p.equals(base, path) || p.isWithin(base, path);

/// The real path for [path], also when its end does not exist (yet): the
/// part that exists has its symlinks followed, the rest is kept.
Future<String> fsCanonical(String path) async {
  var head = p.normalize(p.absolute(path));
  final tail = <String>[];
  while (true) {
    try {
      final real = await File(head).resolveSymbolicLinks();
      return p.joinAll([real, ...tail.reversed]);
    } on FileSystemException {
      final parent = p.dirname(head);
      if (parent == head) {
        return p.normalize(p.absolute(path));
      }
      tail.add(p.basename(head));
      head = parent;
    }
  }
}

/// Places another device never reaches on a computer, whatever is shared:
/// what starts with a dot directly in the home folder (.ssh, .config,
/// .zshrc…), ~/Library on macOS, AppData on Windows, Whisper's own data, and
/// other devices' files mounted here. In a git repository, the hooks and
/// config that git runs on its own (editors run `git status` when a folder
/// opens) and the `.git` entry itself can be read but never changed.
class FsProtectedAreas {
  /// [private] are folders (or files) never reached, [files] Whisper's own
  /// files, which folder copies leave out (`scanFolderInBackground`).
  FsProtectedAreas({
    required String home,
    Iterable<String> private = const [],
    Iterable<String> files = const [],
    Iterable<String> Function()? mounts,
  }) : _home = home.isEmpty ? '' : fsFold(home),
       _private = [for (final path in private) fsFold(path)],
       _files = [for (final path in files) fsFold(path)],
       _mounts = mounts ?? _noMounts;

  static Iterable<String> _noMounts() => const [];

  final String _home;
  final List<String> _private;
  final List<String> _files;
  final Iterable<String> Function() _mounts;

  /// This computer's, with everything resolved the way requests are.
  static Future<FsProtectedAreas> forThisDevice({
    Iterable<String> Function()? mounts,
  }) async {
    final env = Platform.environment;
    final homeVariable = env[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    final home = homeVariable == null || homeVariable.isEmpty
        ? ''
        : await fsCanonical(homeVariable);
    final variables = Platform.isWindows
        ? const ['APPDATA', 'LOCALAPPDATA']
        : Platform.isLinux
        ? const [
            'XDG_CONFIG_HOME',
            'XDG_DATA_HOME',
            'XDG_STATE_HOME',
            'XDG_CACHE_HOME',
          ]
        : const <String>[];
    final private = <String>[
      if (home.isNotEmpty && Platform.isMacOS) p.join(home, 'Library'),
      if (home.isNotEmpty && Platform.isWindows) p.join(home, 'AppData'),
      for (final name in variables)
        if (env[name] case final value? when p.isAbsolute(value)) value,
    ];
    for (final directory in [
      getApplicationSupportDirectory,
      getApplicationCacheDirectory,
    ]) {
      try {
        private.add((await directory()).path);
      } catch (_) {
        // A platform without it (tests).
      }
    }
    return FsProtectedAreas(
      home: home,
      private: {
        for (final path in private) ...[path, await fsCanonical(path)],
      },
      files: {
        for (final path in AppPrivatePaths.all) ...[
          path,
          await fsCanonical(path),
        ],
      },
      mounts: mounts,
    );
  }

  /// Never read, listed or changed.
  bool blocksRead(String path) {
    final folded = fsFold(path);
    if (_home.isNotEmpty && p.isWithin(_home, folded)) {
      final first = p.split(p.relative(folded, from: _home)).first;
      if (first.startsWith('.')) {
        return true;
      }
    }
    return [..._private, ..._files].any((area) => _within(area, folded)) ||
        _mounts().any((mount) => _within(fsFold(mount), folded));
  }

  /// Never created, overwritten, renamed (from or to) or deleted.
  bool blocksWrite(String path) => blocksRead(path) || isGitControl(path);

  /// Something that never leaves is inside [path]: copying it out whole
  /// would take that along. Whisper's own files do not count, folder copies
  /// leave them out.
  bool holdsProtected(String path) {
    final folded = fsFold(path);
    return (_home.isNotEmpty && _within(folded, _home)) ||
        _private.any((area) => p.isWithin(folded, area)) ||
        _mounts().any((mount) => p.isWithin(folded, fsFold(mount)));
  }

  /// Something here is inside [path], Whisper's own files too: renaming,
  /// moving or deleting [path] would take it out from under these rules,
  /// which know it by where it is, or delete it.
  bool holdsAny(String path) =>
      holdsProtected(path) ||
      _files.any((file) => p.isWithin(fsFold(path), file));

  /// A `.git` entry (folder, or the file that points git elsewhere), and in
  /// a `.git` folder any `hooks` folder and its contents and any `config`,
  /// `config.worktree` (submodules and worktrees have their own) or
  /// `commondir` (where a worktree's config is read from).
  static bool isGitControl(String path) {
    final parts = [for (final part in p.split(path)) fsFold(part)];
    final git = parts.indexOf('.git');
    if (git < 0) {
      return false;
    }
    final last = parts.last;
    return last == '.git' ||
        last == 'config' ||
        last == 'config.worktree' ||
        last == 'commondir' ||
        parts.skip(git + 1).contains('hooks');
  }
}

/// What other devices may do where on a computer: inside a shared folder
/// (a whole disk, as the settings share them) what [FsProtectedAreas]
/// allows, less [excluded]; in a folder that leads to one, only see the way
/// there; elsewhere nothing. Paths are real ones, symlinks followed.
class FsSharePolicy {
  FsSharePolicy({
    required Iterable<String> shared,
    required this.protected,
    Iterable<String> excluded = const [],
  }) : shared = List.unmodifiable(shared),
       excluded = List.unmodifiable(excluded),
       _folded = [for (final folder in shared) fsFold(folder)],
       _excludedFolded = [for (final folder in excluded) fsFold(folder)];

  /// Nothing shared (yet).
  static final none = FsSharePolicy(
    shared: const [],
    protected: FsProtectedAreas(home: ''),
  );

  /// The shared folders, as real paths.
  final List<String> shared;

  /// Folders inside them that are not shared, with everything in them: the
  /// system's own (C:\Windows, /usr…) and those the user left out.
  final List<String> excluded;
  final FsProtectedAreas protected;
  final List<String> _folded;
  final List<String> _excludedFolded;

  bool _inShared(String path) => shared.any((folder) => _within(folder, path));

  /// One of the shared folders itself, which stays where it is.
  bool _isSharedFolder(String path) {
    final folded = fsFold(path);
    return _folded.any((folder) => p.equals(folder, folded));
  }

  bool _leadsToShared(String path) =>
      shared.any((folder) => p.isWithin(path, folder));

  /// The shared folder nearest to [path] (folded), the innermost of those
  /// holding it.
  String? _nearest(String folded) {
    String? nearest;
    for (final folder in _folded) {
      if (_within(folder, folded) &&
          (nearest == null || folder.length > nearest.length)) {
        nearest = folder;
      }
    }
    return nearest;
  }

  /// An exclusion counts inside the shared folder nearest to it: the
  /// system disk's /Volumes or /mnt does not hide a disk shared on its own
  /// that is mounted there.
  bool _counts(String exclusion, String folded) {
    final nearest = _nearest(folded);
    return nearest != null && _within(nearest, exclusion);
  }

  bool _isExcluded(String path) {
    final folded = fsFold(path);
    return _excludedFolded.any(
      (exclusion) => _within(exclusion, folded) && _counts(exclusion, folded),
    );
  }

  /// An exclusion is inside [path]: copying it out whole would take it along.
  bool _holdsExcluded(String path) {
    final folded = fsFold(path);
    return _excludedFolded.any(
      (exclusion) =>
          p.isWithin(folded, exclusion) && _counts(exclusion, exclusion),
    );
  }

  bool allows(String path, FsUse use) => switch (use) {
    FsUse.browse =>
      allows(path, FsUse.read) ||
          (_leadsToShared(path) && !protected.blocksRead(path)),
    FsUse.read =>
      _inShared(path) && !_isExcluded(path) && !protected.blocksRead(path),
    FsUse.copy =>
      allows(path, FsUse.read) &&
          !protected.holdsProtected(path) &&
          !_holdsExcluded(path),
    FsUse.fill => allows(path, FsUse.read) && !protected.blocksWrite(path),
    // A folder holding something left out or never reached stays where it
    // is: both are known by where they are.
    FsUse.change =>
      allows(path, FsUse.read) &&
          !_isSharedFolder(path) &&
          !protected.blocksWrite(path) &&
          !protected.holdsAny(path) &&
          !_holdsExcluded(path),
  };

  /// What [folder] lists when it only leads to shared folders: the names of
  /// the folders in it on the way to them.
  List<String> waysOn(String folder) => {
    for (final target in shared)
      if (p.isWithin(folder, target))
        p.split(p.relative(target, from: folder)).first,
  }.toList();
}
