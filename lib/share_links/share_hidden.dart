import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win32;

/// Whether the file system marks [path] hidden apart from its name: the
/// hidden attribute on Windows (Explorer hides `AppData`), the UF_HIDDEN
/// flag on macOS (Finder hides `~/Library`). Linux has only dot names.
/// False when it cannot be told.
bool shareHiddenFlag(String path) {
  try {
    if (Platform.isWindows) {
      return _windowsHidden(path);
    }
    if (Platform.isMacOS) {
      return _darwinHidden(path);
    }
  } on Object {
    // Unknown means visible; names still decide.
  }
  return false;
}

bool _windowsHidden(String path) {
  final native = path.toNativeUtf16();
  try {
    final attributes = win32.GetFileAttributes(native);
    // 0xFFFFFFFF is INVALID_FILE_ATTRIBUTES: the path could not be read.
    return attributes != 0xFFFFFFFF &&
        attributes & win32.FILE_ATTRIBUTE_HIDDEN != 0;
  } finally {
    calloc.free(native);
  }
}

typedef _StatNative = Int32 Function(Pointer<Utf8> path, Pointer<Uint8> buf);
typedef _StatDart = int Function(Pointer<Utf8> path, Pointer<Uint8> buf);

/// `stat` with the 64-bit inode layout (the only one on Apple silicon,
/// `stat$INODE64` on Intel), where `st_flags` sits at byte 116.
final _StatDart? _darwinStat = () {
  final process = DynamicLibrary.process();
  try {
    return process.lookupFunction<_StatNative, _StatDart>(r'stat$INODE64');
  } on ArgumentError {
    if (Abi.current() != Abi.macosArm64) {
      // The plain symbol has another layout on Intel.
      return null;
    }
    return process.lookupFunction<_StatNative, _StatDart>('stat');
  }
}();

const _darwinStatSize = 144;
const _darwinFlagsOffset = 116;
const _ufHidden = 0x8000;

bool _darwinHidden(String path) {
  final stat = _darwinStat;
  if (stat == null) {
    return false;
  }
  final native = path.toNativeUtf8();
  final buffer = calloc<Uint8>(_darwinStatSize + 16);
  try {
    if (stat(native, buffer) != 0) {
      return false;
    }
    final flags = buffer.cast<Uint32>()[_darwinFlagsOffset ~/ 4];
    return flags & _ufHidden != 0;
  } finally {
    calloc.free(native);
    calloc.free(buffer);
  }
}
