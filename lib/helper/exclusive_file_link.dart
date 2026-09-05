import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

enum ExclusiveFileLinkResult { linked, destinationExists, unavailable }

typedef ExclusiveFileLink =
    ExclusiveFileLinkResult Function(String source, String destination);
typedef _CreateHardLinkNative =
    Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>);
typedef _CreateHardLink =
    int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>);
typedef _LastErrorNative = Uint32 Function();
typedef _LastError = int Function();

/// Windows cannot rename a file while Dart's read handle is open. An NTFS
/// hard link publishes the same verified bytes without closing that handle or
/// copying the file; the caller removes the temporary name after committing.
ExclusiveFileLinkResult linkFileWithoutOverwrite(
  String source,
  String destination,
) =>
    _nativeLink?.call(source, destination) ??
    ExclusiveFileLinkResult.unavailable;

final ExclusiveFileLink? _nativeLink = _loadNativeLink();

ExclusiveFileLink? _loadNativeLink() {
  if (!Platform.isWindows) return null;
  final library = DynamicLibrary.open('kernel32.dll');
  final link = library.lookupFunction<_CreateHardLinkNative, _CreateHardLink>(
    'CreateHardLinkW',
  );
  final lastError = library.lookupFunction<_LastErrorNative, _LastError>(
    'GetLastError',
  );
  return (source, destination) {
    final from = _extendedPath(source).toNativeUtf16(allocator: calloc);
    final to = _extendedPath(destination).toNativeUtf16(allocator: calloc);
    try {
      if (link(to, from, nullptr) != 0) return ExclusiveFileLinkResult.linked;
      final error = lastError();
      if (error == 80 || error == 183) {
        return ExclusiveFileLinkResult.destinationExists;
      }
      // Unsupported volumes, cross-volume paths, sharing restrictions, or the
      // NTFS link-count limit retain the existing verified copy fallback.
      if (<int>{1, 5, 17, 32, 50, 1142}.contains(error)) {
        return ExclusiveFileLinkResult.unavailable;
      }
      throw FileSystemException(
        'Exclusive file link failed',
        source,
        OSError('CreateHardLinkW', error),
      );
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  };
}

String _extendedPath(String path) {
  final absolute = File(path).absolute.path.replaceAll('/', r'\');
  if (absolute.startsWith(r'\\?\')) return absolute;
  if (absolute.startsWith(r'\\')) return r'\\?\UNC\' + absolute.substring(2);
  return r'\\?\' + absolute;
}
