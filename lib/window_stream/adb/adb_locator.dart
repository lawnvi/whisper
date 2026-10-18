import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/window_stream_models.dart';
import 'adb_host_client.dart';

/// Finds an adb executable and makes sure a server is running. The server is
/// shared with any other adb user on this machine (Android Studio, scrcpy):
/// two servers cannot both own a USB device.
class AdbLocator {
  AdbLocator({
    Map<String, String>? environment,
    String? resolvedExecutable,
    bool Function(String path)? fileExists,
    Future<ProcessResult> Function(String executable, List<String> arguments)?
    runProcess,
  }) : _environment = environment ?? Platform.environment,
       _resolvedExecutable = resolvedExecutable ?? Platform.resolvedExecutable,
       _fileExists = fileExists ?? ((path) => File(path).existsSync()),
       _runProcess = runProcess ?? Process.run;

  final Map<String, String> _environment;
  final String _resolvedExecutable;
  final bool Function(String path) _fileExists;
  final Future<ProcessResult> Function(String, List<String>) _runProcess;

  /// Candidate locations, most preferred first.
  List<String> candidates() {
    final executable = Platform.isWindows ? 'adb.exe' : 'adb';
    final home = _environment['HOME'] ?? _environment['USERPROFILE'] ?? '';
    final paths = <String>[];
    // Bundled next to the app executable (or in Resources on macOS).
    final appDir = p.dirname(_resolvedExecutable);
    paths.add(p.join(appDir, executable));
    if (Platform.isMacOS) {
      paths.add(p.join(appDir, '..', 'Resources', 'adb', executable));
    }
    for (final key in const ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
      final sdk = _environment[key];
      if (sdk != null && sdk.isNotEmpty) {
        paths.add(p.join(sdk, 'platform-tools', executable));
      }
    }
    if (Platform.isMacOS) {
      paths.add(
        p.join(home, 'Library', 'Android', 'sdk', 'platform-tools', executable),
      );
      paths.add('/opt/homebrew/bin/adb');
      paths.add('/usr/local/bin/adb');
    } else if (Platform.isWindows) {
      final local = _environment['LOCALAPPDATA'];
      if (local != null) {
        paths.add(
          p.join(local, 'Android', 'Sdk', 'platform-tools', executable),
        );
      }
    } else {
      paths.add(p.join(home, 'Android', 'Sdk', 'platform-tools', executable));
      paths.add('/usr/bin/adb');
      paths.add('/usr/local/bin/adb');
    }
    for (final dir in (_environment['PATH'] ?? '').split(
      Platform.isWindows ? ';' : ':',
    )) {
      if (dir.isNotEmpty) {
        paths.add(p.join(dir, executable));
      }
    }
    return paths;
  }

  String? findExecutable() {
    for (final path in candidates()) {
      if (_fileExists(path)) {
        return p.normalize(path);
      }
    }
    return null;
  }

  /// Returns a client for a running server, starting one if needed.
  Future<AdbHostClient> ensureServer({AdbHostClient? client}) async {
    final adb = client ?? AdbHostClient();
    try {
      await adb.serverVersion();
      return adb;
    } on AdbServerUnavailable {
      // Not running yet.
    }
    final executable = findExecutable();
    if (executable == null) {
      throw const WindowStreamFailure(WindowStreamFailureReason.adbUnavailable);
    }
    final result = await _runProcess(executable, const ['start-server']);
    if (result.exitCode != 0) {
      throw WindowStreamFailure(
        WindowStreamFailureReason.adbServerFailed,
        '${result.stderr}'.trim(),
      );
    }
    try {
      await adb.serverVersion();
    } on AdbServerUnavailable catch (error) {
      throw WindowStreamFailure(
        WindowStreamFailureReason.adbServerFailed,
        error.message,
      );
    }
    return adb;
  }
}
