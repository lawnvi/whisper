import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

enum AtomicFileMoveResult { moved, destinationExists, unavailable }

typedef AtomicFileMove =
    AtomicFileMoveResult Function(String source, String destination);
typedef _RenameExclusiveNative =
    Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32);
typedef _RenameExclusive = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _RenameAtNative =
    Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Uint32);
typedef _RenameAt = int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int);
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _Errno = Pointer<Int32> Function();

/// Moves a file without ever replacing an existing destination, including a
/// symlink. Unsupported platforms/filesystems retain the copy-based publisher.
AtomicFileMoveResult moveFileWithoutOverwrite(
  String source,
  String destination,
) => _nativeMove?.call(source, destination) ?? AtomicFileMoveResult.unavailable;

final AtomicFileMove? _nativeMove = _loadNativeMove();

AtomicFileMove? _loadNativeMove() {
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
        if (rename(from, to, 0) == 0) return AtomicFileMoveResult.moved;
        final error = errno().value;
        if (error == 17) return AtomicFileMoveResult.destinationExists;
        // EXDEV, EINVAL and platform-specific unsupported-operation errors.
        if (<int>{18, 22, 38, 45, 78, 95, 102}.contains(error)) {
          return AtomicFileMoveResult.unavailable;
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
