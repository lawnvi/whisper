import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'exclusive_file_link.dart' show windowsExtendedPath;

enum AtomicFileMoveResult { moved, destinationExists, unavailable }

typedef AtomicFileMove =
    AtomicFileMoveResult Function(String source, String destination);

/// What [movePathWithoutOverwrite] did.
enum PathMoveResult { moved, destinationExists, otherVolume, unsupported }

typedef _RenameExclusiveNative =
    Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32);
typedef _RenameExclusive = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _RenameAtNative =
    Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Uint32);
typedef _RenameAt = int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int);
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _Errno = Pointer<Int32> Function();
typedef _MoveFileExNative =
    Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _MoveFileEx = int Function(Pointer<Utf16>, Pointer<Utf16>, int);
typedef _LastErrorNative = Uint32 Function();
typedef _LastError = int Function();

/// Moves a file without ever replacing an existing destination, including a
/// symlink. Unsupported platforms/filesystems retain the copy-based publisher.
/// Windows answers [AtomicFileMoveResult.unavailable]: its publisher holds
/// the file open, which a move would not get past; it links instead.
AtomicFileMoveResult moveFileWithoutOverwrite(
  String source,
  String destination,
) {
  if (Platform.isWindows) return AtomicFileMoveResult.unavailable;
  return switch (movePathWithoutOverwrite(source, destination)) {
    PathMoveResult.moved => AtomicFileMoveResult.moved,
    PathMoveResult.destinationExists => AtomicFileMoveResult.destinationExists,
    PathMoveResult.otherVolume ||
    PathMoveResult.unsupported => AtomicFileMoveResult.unavailable,
  };
}

/// Moves a file or a folder to [destination] in one step that fails when
/// anything is already there, an empty folder or a symlink included (macOS
/// `renamex_np`, Linux `renameat2`, Windows `MoveFileEx` without replacing).
/// [PathMoveResult.unsupported] where the system or the filesystem can't
/// (older Android, some network and FUSE volumes); other failures throw.
PathMoveResult movePathWithoutOverwrite(String source, String destination) =>
    _nativeMove?.call(source, destination) ?? PathMoveResult.unsupported;

final PathMoveResult Function(String, String)? _nativeMove = Platform.isWindows
    ? _loadWindowsMove()
    : _loadPosixMove();

PathMoveResult Function(String, String)? _loadPosixMove() {
  if (!Platform.isMacOS && !Platform.isLinux && !Platform.isAndroid) {
    return null;
  }
  try {
    final library = DynamicLibrary.process();
    final errno = library.lookupFunction<_ErrnoNative, _Errno>(
      Platform.isMacOS
          ? '__error'
          : Platform.isAndroid
          ? '__errno'
          : '__errno_location',
    );
    final _RenameExclusive rename;
    if (Platform.isMacOS) {
      final native = library
          .lookupFunction<_RenameExclusiveNative, _RenameExclusive>(
            'renamex_np',
          );
      // Darwin RENAME_EXCL; ordinary rename() would overwrite user files.
      rename = (source, destination, _) => native(source, destination, 0x4);
    } else {
      final native = library.lookupFunction<_RenameAtNative, _RenameAt>(
        'renameat2',
      );
      // Absolute paths ignore the directory fd; Linux RENAME_NOREPLACE = 1.
      rename = (source, destination, _) =>
          native(-100, source, -100, destination, 1);
    }
    return (source, destination) {
      final from = source.toNativeUtf8(allocator: calloc);
      final to = destination.toNativeUtf8(allocator: calloc);
      try {
        if (rename(from, to, 0) == 0) return PathMoveResult.moved;
        final error = errno().value;
        if (error == 17) return PathMoveResult.destinationExists;
        if (error == 18) return PathMoveResult.otherVolume;
        // EINVAL and platform-specific unsupported-operation errors.
        if (<int>{22, 38, 45, 78, 95, 102}.contains(error)) {
          return PathMoveResult.unsupported;
        }
        throw FileSystemException(
          'Exclusive file move failed',
          source,
          OSError('rename', error),
        );
      } finally {
        calloc.free(from);
        calloc.free(to);
      }
    };
  } on ArgumentError {
    // Older libc/Android releases may not export renameat2.
    return null;
  }
}

PathMoveResult Function(String, String)? _loadWindowsMove() {
  try {
    final library = DynamicLibrary.open('kernel32.dll');
    final move = library.lookupFunction<_MoveFileExNative, _MoveFileEx>(
      'MoveFileExW',
    );
    final lastError = library.lookupFunction<_LastErrorNative, _LastError>(
      'GetLastError',
    );
    return (source, destination) {
      final from = windowsExtendedPath(source).toNativeUtf16(allocator: calloc);
      final to = windowsExtendedPath(
        destination,
      ).toNativeUtf16(allocator: calloc);
      try {
        // No MOVEFILE_REPLACE_EXISTING: it fails when anything is there.
        if (move(from, to, 0) != 0) return PathMoveResult.moved;
        final error = lastError();
        // ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS.
        if (error == 80 || error == 183) {
          return PathMoveResult.destinationExists;
        }
        // ERROR_NOT_SAME_DEVICE.
        if (error == 17) return PathMoveResult.otherVolume;
        // ERROR_INVALID_FUNCTION, ERROR_NOT_SUPPORTED.
        if (error == 1 || error == 50) return PathMoveResult.unsupported;
        throw FileSystemException(
          'Exclusive file move failed',
          source,
          OSError('MoveFileExW', error),
        );
      } finally {
        calloc.free(from);
        calloc.free(to);
      }
    };
  } on ArgumentError {
    return null;
  }
}
