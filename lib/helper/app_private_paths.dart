/// Files that are Whisper's own wherever the platform put them, such as its
/// database in the Documents folder on Linux and Windows. Nothing Whisper
/// serves to other devices reaches them, even inside a folder shared with
/// them (see `FsProtectedAreas`).
abstract final class AppPrivatePaths {
  static final _paths = <String>{};

  /// [path] is Whisper's own from now on.
  static void add(String path) => _paths.add(path);

  static Iterable<String> get all => _paths;
}
