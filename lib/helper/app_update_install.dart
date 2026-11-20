import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import 'app_update.dart';
import 'desktop_startup.dart' show macOSAppPathFromExecutable;

/// What the Windows installer is started with for an update: it then asks
/// nothing, installs where Whisper already is and starts it again
/// (`windows/installer.nsi`).
const windowsUpdateInstallerArgument = '/UPDATE';

/// Run as root through pkexec to install a Linux package: `$1` is the
/// package, `$2` its SHA-256 and `$3` its kind (`deb` or `rpm`). The package
/// was checked where it was downloaded, but any program of the user can
/// replace it there while the password is asked for, and the package manager
/// runs its scripts as root. So root copies it somewhere only root can change
/// and checks it again there.
const linuxPackageInstallScript = r'''set -eu
dir=$(mktemp -d /var/tmp/whisper-update.XXXXXX)
trap 'rm -rf "$dir"' EXIT
chmod 755 "$dir"
pkg="$dir/whisper.$3"
cp -- "$1" "$pkg"
chmod 644 "$pkg"
echo "$2  $pkg" | sha256sum -c - >/dev/null
case "$3" in
  deb) apt-get -y install -- "$pkg" ;;
  rpm)
    if command -v dnf >/dev/null 2>&1; then
      dnf -y install "$pkg"
    elif command -v yum >/dev/null 2>&1; then
      yum -y install "$pkg"
    else
      rpm -U --replacepkgs "$pkg"
    fi
    ;;
  *) exit 2 ;;
esac
''';

/// Started detached right before Whisper quits for an update: `$1` is
/// Whisper's process, `$2` the app and `$3` the new app staged beside it (or
/// empty), the rest the command that starts Whisper again. It waits for
/// Whisper to be gone (an app still running cannot be swapped on macOS, and on
/// Linux a second Whisper would only hand over to the first and quit), puts
/// the new app in place, and if that fails leaves the old one where it was.
const updateAfterExitScript = r'''pid=$1 app=$2 new=$3
shift 3
i=0
while kill -0 "$pid" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -gt 300 ]; then
    [ -n "$new" ] && rm -rf "$new"
    exit 1
  fi
  sleep 0.2
done
if [ -n "$new" ]; then
  old="$new.old"
  rm -rf "$old"
  if mv "$app" "$old"; then
    if mv "$new" "$app"; then
      rm -rf "$old"
    else
      mv "$old" "$app"
    fi
  fi
  rm -rf "$new"
fi
exec "$@"
''';

typedef UpdateProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
typedef UpdateProcessStarter =
    Future<void> Function(String executable, List<String> arguments);

/// Puts a package that was already checked in place. On the desktops nothing
/// asks to be clicked through: Whisper quits, the new version takes its place
/// and starts. Only a Linux system package asks for the password, because root
/// installs it.
class AppUpdateInstaller {
  AppUpdateInstaller({
    required this.platform,
    required UpdateProcessRunner run,
    required UpdateProcessStarter start,
    String? executable,
    Map<String, String>? environment,
    int? processId,
  }) : _run = run,
       _start = start,
       _executable = executable ?? Platform.resolvedExecutable,
       _environment = environment ?? Platform.environment,
       _processId = processId ?? pid;

  final AppUpdatePlatform platform;
  final UpdateProcessRunner _run;
  final UpdateProcessStarter _start;
  final String _executable;
  final Map<String, String> _environment;
  final int _processId;

  Future<AppUpdateInstallDisposition> install(
    AppUpdateDownload download,
  ) async {
    switch (platform) {
      case AppUpdatePlatform.windows:
        // The installer runs by itself; Whisper only has to get out of its way.
        await _start(download.file.path, const <String>[
          windowsUpdateInstallerArgument,
        ]);
        return AppUpdateInstallDisposition.exitApplication;
      case AppUpdatePlatform.macos:
        return _installMacOS(download);
      case AppUpdatePlatform.linux:
        return _installLinux(download);
      case AppUpdatePlatform.android:
        var permission = await Permission.requestInstallPackages.status;
        if (!permission.isGranted) {
          permission = await Permission.requestInstallPackages.request();
        }
        if (!permission.isGranted) {
          throw const AppUpdateException('Package install permission denied');
        }
        await _open(download.file);
        return AppUpdateInstallDisposition.keepRunning;
      case AppUpdatePlatform.ios:
      case AppUpdatePlatform.unsupported:
        await _open(download.file);
        return AppUpdateInstallDisposition.keepRunning;
    }
  }

  /// The new app is copied out of the disk image beside the running one and
  /// swapped in once Whisper has quit. Where that can't be done (no right to
  /// write there, or Whisper runs from the disk image itself), the disk image
  /// opens for the app to be dragged over, as before.
  Future<AppUpdateInstallDisposition> _installMacOS(
    AppUpdateDownload download,
  ) async {
    final app = macOSAppPathFromExecutable(_executable);
    String? staged;
    if (app.endsWith('.app')) {
      try {
        staged = await _stageMacOSApp(download.file, app);
      } on Object {
        staged = null;
      }
    }
    if (staged == null) {
      await _open(download.file);
      return AppUpdateInstallDisposition.exitApplication;
    }
    return _restartAfterExit(
      app,
      staged: staged,
      command: ['/usr/bin/open', app],
    );
  }

  Future<String> _stageMacOSApp(File diskImage, String app) async {
    final staged = p.join(p.dirname(app), '.${p.basename(app)}.update');
    final mount = await diskImage.parent.createTemp('mount-');
    var attached = false;
    try {
      await _must('/usr/bin/hdiutil', <String>[
        'attach',
        '-nobrowse',
        '-readonly',
        '-noautoopen',
        '-mountpoint',
        mount.path,
        diskImage.path,
      ]);
      attached = true;
      final source = await mount
          .list()
          .where((entry) => entry is Directory && entry.path.endsWith('.app'))
          .first;
      await _deleteIfPresent(staged);
      await _must('/usr/bin/ditto', <String>[source.path, staged]);
      // A broken copy swapped in would leave an app macOS refuses to start.
      await _must('/usr/bin/codesign', <String>[
        '--verify',
        '--deep',
        '--strict',
        staged,
      ]);
      return staged;
    } on Object {
      await _deleteIfPresent(staged);
      rethrow;
    } finally {
      if (attached) {
        await _run('/usr/bin/hdiutil', <String>[
          'detach',
          '-force',
          mount.path,
        ]);
      }
      try {
        await mount.delete();
      } on FileSystemException {
        // Left in the temporary folder.
      }
    }
  }

  Future<AppUpdateInstallDisposition> _installLinux(
    AppUpdateDownload download,
  ) async {
    final name = download.file.path.toLowerCase();
    if (name.endsWith('.appimage')) {
      return _replaceAppImage(download.file);
    }
    final kind = name.endsWith('.deb')
        ? 'deb'
        : name.endsWith('.rpm')
        ? 'rpm'
        : null;
    if (kind == null) {
      throw const AppUpdateException('Unsupported Linux package');
    }
    // A software center may open a local package without installing it:
    // polkit asks for the password, and the package manager's result counts.
    final result = await _run('/usr/bin/pkexec', <String>[
      '/bin/sh',
      '-c',
      linuxPackageInstallScript,
      'sh',
      download.file.absolute.path,
      download.release.asset!.sha256!.toLowerCase(),
      kind,
    ]);
    await File(p.join(download.file.parent.path, 'install.log')).writeAsString(
      'exitCode=${result.exitCode}\n${result.stdout}\n${result.stderr}',
    );
    if (result.exitCode != 0) {
      throw AppUpdateException(
        'Linux package installation failed (${result.exitCode})',
      );
    }
    return _restartAfterExit(_executable, command: [_executable]);
  }

  /// A running AppImage can be replaced: what runs is mounted from the old
  /// file, which stays until Whisper quits. It keeps its path, so menus,
  /// shortcuts and starting at login still find it.
  Future<AppUpdateInstallDisposition> _replaceAppImage(File package) async {
    final target = _environment['APPIMAGE'];
    if (target == null || !p.isAbsolute(target)) {
      throw const AppUpdateException('Whisper is not running as an AppImage');
    }
    final staged = File(
      p.join(p.dirname(target), '.${p.basename(target)}.update'),
    );
    try {
      await package.copy(staged.path);
      await _must('chmod', <String>['755', staged.path]);
      await staged.rename(target);
    } on Object {
      await _deleteIfPresent(staged.path);
      throw const AppUpdateException('Unable to replace the AppImage');
    }
    return _restartAfterExit(target, command: [target]);
  }

  Future<AppUpdateInstallDisposition> _restartAfterExit(
    String app, {
    String? staged,
    required List<String> command,
  }) async {
    try {
      await _start('/bin/sh', <String>[
        '-c',
        updateAfterExitScript,
        'sh',
        '$_processId',
        app,
        staged ?? '',
        ...command,
      ]);
    } on Object {
      if (staged != null) {
        await _deleteIfPresent(staged);
        rethrow;
      }
      // Installed already: only starting again is left to the user.
      return AppUpdateInstallDisposition.installed;
    }
    return AppUpdateInstallDisposition.exitApplication;
  }

  Future<void> _must(String executable, List<String> arguments) async {
    final result = await _run(executable, arguments);
    if (result.exitCode != 0) {
      throw AppUpdateException(
        '${p.basename(executable)} failed (${result.exitCode})',
      );
    }
  }

  Future<void> _open(File file) async {
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done) {
      throw AppUpdateException(result.message);
    }
  }
}

Future<void> _deleteIfPresent(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return;
  }
  await (type == FileSystemEntityType.directory ? Directory(path) : File(path))
      .delete(recursive: true);
}
