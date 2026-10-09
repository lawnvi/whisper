import 'package:path/path.dart' as p;

final _container = RegExp(
  r'^/(?:private/)?var/mobile/Containers/Data/Application/'
  r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}/',
);

/// iOS can move the app's data container during an update or test install.
/// Stored local paths must follow that move, while external paths stay intact.
String rebaseIosSandboxPath(String path, String documentsDirectory) {
  final current = _container.firstMatch(documentsDirectory);
  final previous = _container.firstMatch(path);
  if (current == null || previous == null) return path;
  if (documentsDirectory.substring(current.end) != 'Documents') return path;
  final relative = path.substring(previous.end);
  final parts = p.posix.split(relative);
  if (parts.isEmpty ||
      !const {'Documents', 'Library', 'tmp'}.contains(parts.first) ||
      parts.any((part) => part == '.' || part == '..') ||
      path.contains('\u0000')) {
    return path;
  }
  return p.posix.join(documentsDirectory.substring(0, current.end), relative);
}
