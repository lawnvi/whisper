import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import 'fs_host_files.dart';
import 'fs_paths.dart';

/// Platform pieces of the remote file manager: the system trash, file
/// thumbnails, Windows drives and hidden attributes.
///
/// The runner's `com.vireen.whisper/file_manager` channel answers
/// `thumbnail {path, size, video}` → JPEG bytes (macOS, Android, Windows,
/// Linux, iOS) and `trash {path}` → bool (macOS, Linux); a runner without
/// it falls back to what Dart can do alone.
abstract final class FsPlatform {
  static const _channel = MethodChannel('com.vireen.whisper/file_manager');

  /// The runner has no thumbnail handler; don't ask again this run.
  static bool _noThumbnails = false;

  /// Whether deletions can go to a trash here (not on Android).
  static bool get hasTrash =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Moves [path] to the system trash. False when it could not, in which
  /// case nothing was deleted.
  static Future<bool> trash(String path) async {
    try {
      if (Platform.isMacOS) {
        return await _channel.invokeMethod<bool>('trash', {'path': path}) ??
            false;
      }
      if (Platform.isWindows) {
        return _windowsRecycle(path);
      }
      if (Platform.isLinux) {
        return await _linuxTrash(path);
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// GIO's trash (g_file_trash: the right trash on every filesystem,
  /// removable drives included) through the runner; without it, a rename
  /// into the home trash, which works on the home's filesystem only.
  static Future<bool> _linuxTrash(String path) async {
    try {
      final trashed = await _channel.invokeMethod<bool>('trash', {
        'path': path,
      });
      if (trashed == true) {
        return true;
      }
    } on MissingPluginException {
      // An older runner.
    } on PlatformException {
      // GIO refused; try the plain rename below.
    }
    return _freedesktopTrash(path);
  }

  /// Tells Android's media index that files moved (galleries, pickers).
  static Future<void> mediaScan(List<String> paths) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('scan', {'paths': paths});
    } catch (_) {
      // The index catches up on its own eventually.
    }
  }

  /// A JPEG thumbnail of an image or video (and of documents where the
  /// system draws them: Quick Look on macOS and iOS, the shell on
  /// Windows), or null.
  static Future<Uint8List?> thumbnail(String path, {int size = 256}) async {
    final kind = fsKindOf(path);
    if (!thumbnailsWanted(kind) || _noThumbnails) {
      return null;
    }
    try {
      return await _channel.invokeMethod<Uint8List>('thumbnail', {
        'path': path,
        'size': size,
        'video': kind == FsKind.video,
      });
    } on MissingPluginException {
      _noThumbnails = true;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Whether this platform's runner is asked for a thumbnail of [kind].
  static bool thumbnailsWanted(FsKind kind, {String? platform}) {
    final os = platform ?? Platform.operatingSystem;
    const everywhere = {'macos', 'android', 'windows', 'linux', 'ios'};
    if (!everywhere.contains(os)) {
      return false;
    }
    return kind == FsKind.image ||
        kind == FsKind.video ||
        (kind == FsKind.document &&
            (os == 'macos' || os == 'ios' || os == 'windows'));
  }

  /// Hidden on Windows: the hidden or system attribute (AppData,
  /// desktop.ini, the recycle bin…), as Explorer hides them.
  static bool isHiddenWindows(String path) {
    if (!Platform.isWindows) {
      return false;
    }
    final native = path.toNativeUtf16();
    try {
      var attributes = GetFileAttributes(native);
      if (attributes == 0xFFFFFFFF) {
        // Files the system keeps open (pagefile.sys, DumpStack.log.tmp)
        // refuse GetFileAttributes; the directory entry still has them.
        final data = calloc<WIN32_FIND_DATA>();
        try {
          final find = FindFirstFile(native, data);
          if (find != INVALID_HANDLE_VALUE) {
            attributes = data.ref.dwFileAttributes;
            FindClose(find);
          }
        } finally {
          calloc.free(data);
        }
      }
      return fsHiddenFromAttributes(attributes);
    } finally {
      calloc.free(native);
    }
  }

  /// The drives Explorer shows under "This PC": fixed, removable and RAM
  /// disks, and optical drives with a disc. Network drives are left out (a
  /// lost share can hang for half a minute). Runs off the UI isolate:
  /// waking a sleeping disk to read its name takes a moment.
  static Future<List<FsRoot>> windowsDrives() async {
    if (!Platform.isWindows) {
      return const [];
    }
    try {
      final found = await Isolate.run(_listWindowsDrives);
      return [
        for (final drive in found)
          windowsDriveRoot(
            letter: drive.letter,
            label: drive.label,
            removable: drive.removable,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static List<({String letter, String label, bool removable})>
  _listWindowsDrives() {
    final drives = <({String letter, String label, bool removable})>[];
    // No "There is no disk in the drive" box for an empty card reader.
    final oldMode = calloc<Uint32>();
    SetThreadErrorMode(
      SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX,
      oldMode,
    );
    final name = calloc<Uint16>(261).cast<Utf16>();
    final fileSystem = calloc<Uint16>(261).cast<Utf16>();
    try {
      final mask = GetLogicalDrives();
      for (var i = 0; i < 26; i++) {
        if (mask & (1 << i) == 0) {
          continue;
        }
        final letter = String.fromCharCode(0x41 + i);
        final root = '$letter:\\'.toNativeUtf16();
        try {
          final type = GetDriveType(root);
          if (type != DRIVE_FIXED &&
              type != DRIVE_REMOVABLE &&
              type != DRIVE_RAMDISK &&
              type != DRIVE_CDROM) {
            continue;
          }
          // Fails for an empty drive: nothing to browse there.
          if (GetVolumeInformation(
                root,
                name,
                261,
                nullptr,
                nullptr,
                nullptr,
                fileSystem,
                261,
              ) ==
              0) {
            continue;
          }
          drives.add((
            letter: letter,
            label: name.toDartString(),
            removable: type == DRIVE_REMOVABLE || type == DRIVE_CDROM,
          ));
        } finally {
          calloc.free(root);
        }
      }
    } finally {
      SetThreadErrorMode(oldMode.value, nullptr);
      calloc.free(oldMode);
      calloc.free(name);
      calloc.free(fileSystem);
    }
    return drives;
  }

  static bool _windowsRecycle(String path) {
    final operation = calloc<SHFILEOPSTRUCT>();
    // Double NUL-terminated list of one path.
    final from = '$path\u0000'.toNativeUtf16();
    try {
      operation.ref
        ..wFunc = FO_DELETE
        ..pFrom = from
        ..fFlags =
            FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT;
      return SHFileOperation(operation) == 0 &&
          operation.ref.fAnyOperationsAborted == 0;
    } finally {
      calloc.free(from);
      calloc.free(operation);
    }
  }

  /// The freedesktop.org trash in the user's data folder. Only when the
  /// item is on the same filesystem (a rename); otherwise false.
  static Future<bool> _freedesktopTrash(String path) async {
    final dataHome =
        Platform.environment['XDG_DATA_HOME'] ??
        p.join(Platform.environment['HOME'] ?? '', '.local', 'share');
    final files = Directory(p.join(dataHome, 'Trash', 'files'));
    final info = Directory(p.join(dataHome, 'Trash', 'info'));
    await files.create(recursive: true);
    await info.create(recursive: true);
    final base = p.basename(path);
    var name = base;
    for (
      var n = 2;
      await FileSystemEntity.type(
            p.join(files.path, name),
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound;
      n++
    ) {
      name = '${p.basenameWithoutExtension(base)} $n${p.extension(base)}';
    }
    final now = DateTime.now().toIso8601String().split('.').first;
    final record = File(p.join(info.path, '$name.trashinfo'));
    await record.writeAsString(
      '[Trash Info]\nPath=${Uri.file(path).path}\nDeletionDate=$now\n',
    );
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      final target = p.join(files.path, name);
      switch (type) {
        case FileSystemEntityType.directory:
          await Directory(path).rename(target);
        case FileSystemEntityType.link:
          await Link(path).rename(target);
        default:
          await File(path).rename(target);
      }
      return true;
    } on FileSystemException {
      await record.delete();
      return false;
    }
  }
}

/// `GetFileAttributesW` result → hidden in listings.
bool fsHiddenFromAttributes(int attributes) {
  const invalid = 0xFFFFFFFF;
  const hidden = 0x2; // FILE_ATTRIBUTE_HIDDEN
  const system = 0x4; // FILE_ATTRIBUTE_SYSTEM
  return attributes != invalid && attributes & (hidden | system) != 0;
}
