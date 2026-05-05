import 'dart:io';

import 'package:whisper/helper/helper.dart';

class DesktopStartupException implements Exception {
  const DesktopStartupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DesktopStartupManager {
  const DesktopStartupManager({
    this.appName = 'Whisper',
    this.macOSLabel = 'com.vireen.whisper.launch-at-login',
  });

  static const String _windowsRunKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  final String appName;
  final String macOSLabel;

  bool get isSupported => isDesktop();

  Future<bool> isEnabled() async {
    if (!isSupported) {
      return false;
    }
    if (Platform.isMacOS) {
      return File(_macOSLaunchAgentPath()).exists();
    }
    if (Platform.isLinux) {
      final file = File(_linuxAutostartPath());
      if (!await file.exists()) {
        return false;
      }
      final content = await file.readAsString();
      return content.contains('X-GNOME-Autostart-enabled=true');
    }
    if (Platform.isWindows) {
      final result = await Process.run(
        'reg',
        ['query', _windowsRunKey, '/v', appName],
        runInShell: true,
      );
      return result.exitCode == 0;
    }
    return false;
  }

  Future<void> setEnabled(bool enabled) async {
    if (!isSupported) {
      throw const DesktopStartupException(
        'Launch at startup is only supported on desktop platforms.',
      );
    }
    if (enabled) {
      await _enable();
    } else {
      await _disable();
    }
  }

  Future<void> _enable() async {
    if (Platform.isMacOS) {
      final file = File(_macOSLaunchAgentPath());
      await file.parent.create(recursive: true);
      await file.writeAsString(
        buildMacOSLaunchAgentPlist(
          label: macOSLabel,
          appPath: macOSAppPathFromExecutable(Platform.resolvedExecutable),
        ),
      );
      return;
    }
    if (Platform.isLinux) {
      final file = File(_linuxAutostartPath());
      await file.parent.create(recursive: true);
      await file.writeAsString(
        buildLinuxAutostartDesktopEntry(
          appName: appName,
          executablePath: Platform.resolvedExecutable,
        ),
      );
      return;
    }
    if (Platform.isWindows) {
      final result = await Process.run(
        'reg',
        [
          'add',
          _windowsRunKey,
          '/v',
          appName,
          '/t',
          'REG_SZ',
          '/d',
          buildWindowsStartupCommand(Platform.resolvedExecutable),
          '/f',
        ],
        runInShell: true,
      );
      _throwIfProcessFailed(result, 'Failed to enable launch at startup');
      return;
    }
    throw const DesktopStartupException('Unsupported desktop platform.');
  }

  Future<void> _disable() async {
    if (Platform.isMacOS) {
      await _deleteFileIfExists(_macOSLaunchAgentPath());
      return;
    }
    if (Platform.isLinux) {
      await _deleteFileIfExists(_linuxAutostartPath());
      return;
    }
    if (Platform.isWindows) {
      final result = await Process.run(
        'reg',
        ['delete', _windowsRunKey, '/v', appName, '/f'],
        runInShell: true,
      );
      if (result.exitCode != 0) {
        final query = await Process.run(
          'reg',
          ['query', _windowsRunKey, '/v', appName],
          runInShell: true,
        );
        if (query.exitCode == 0) {
          _throwIfProcessFailed(result, 'Failed to disable launch at startup');
        }
      }
      return;
    }
    throw const DesktopStartupException('Unsupported desktop platform.');
  }

  String _linuxAutostartPath() {
    final home = Platform.environment['HOME'];
    if (home == null || home.trim().isEmpty) {
      throw const DesktopStartupException('HOME is not available.');
    }
    return '$home/.config/autostart/whisper.desktop';
  }

  String _macOSLaunchAgentPath() {
    final home = Platform.environment['HOME'];
    if (home == null || home.trim().isEmpty) {
      throw const DesktopStartupException('HOME is not available.');
    }
    return '$home/Library/LaunchAgents/$macOSLabel.plist';
  }

  Future<void> _deleteFileIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  void _throwIfProcessFailed(ProcessResult result, String action) {
    if (result.exitCode == 0) {
      return;
    }
    final detail = '${result.stderr}${result.stdout}'.trim();
    throw DesktopStartupException(
      detail.isEmpty ? action : '$action: $detail',
    );
  }
}

String buildLinuxAutostartDesktopEntry({
  required String appName,
  required String executablePath,
}) {
  return '''
[Desktop Entry]
Type=Application
Name=$appName
Exec=${_desktopEntryQuote(executablePath)}
Terminal=false
X-GNOME-Autostart-enabled=true
''';
}

String buildMacOSLaunchAgentPlist({
  required String label,
  required String appPath,
}) {
  final escapedLabel = _xmlEscape(label);
  final escapedAppPath = _xmlEscape(appPath);
  return '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$escapedLabel</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>$escapedAppPath</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
''';
}

String macOSAppPathFromExecutable(String executablePath) {
  const bundleMarker = '/Contents/MacOS/';
  final markerIndex = executablePath.indexOf(bundleMarker);
  if (markerIndex <= 0) {
    return executablePath;
  }
  return executablePath.substring(0, markerIndex);
}

String buildWindowsStartupCommand(String executablePath) {
  return '"${executablePath.replaceAll('"', r'\"')}"';
}

String _desktopEntryQuote(String value) {
  final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

String _xmlEscape(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
