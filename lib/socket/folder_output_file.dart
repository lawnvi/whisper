import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Whether [error] says the disk has no room left, which ends a transfer
/// where any other failure only costs the file it happened on.
bool folderWriteHitFullDisk(FileSystemException error) {
  final code = error.osError?.errorCode;
  if (code == null) return false;
  if (Platform.isWindows) return code == 112 || code == 39;
  // ENOSPC, then EDQUOT as Linux and as the BSDs number it.
  return code == 28 || code == (Platform.isLinux ? 122 : 69);
}

/// A file being written while a folder is received.
abstract interface class FolderOutputFile {
  void write(Uint8List bytes, int start, int end);

  void flush();

  /// Closes the file. With a positive [modifiedMs] it is left carrying that
  /// modification time.
  void close({int modifiedMs = 0});
}

/// Opens the files of a folder being received.
///
/// On Windows this goes to the Win32 API directly so that the modification
/// time is set through the handle the file was written with. Opening a file
/// again right after closing it waits for the real-time scanner to finish
/// with it: measured on source files of a few kilobytes, that second open
/// took 16 to 20 ms per file against 1 ms for the whole write.
abstract class FolderFileWriter {
  factory FolderFileWriter() =>
      Platform.isWindows ? _Win32FolderFileWriter() : _IoFolderFileWriter();

  /// Creates [path], replacing whatever file is there.
  FolderOutputFile create(String path);

  /// Opens the existing [path] to continue at its end.
  FolderOutputFile append(String path);

  void dispose();
}

final class _IoFolderFileWriter implements FolderFileWriter {
  @override
  FolderOutputFile create(String path) =>
      _IoOutputFile(path, File(path).openSync(mode: FileMode.writeOnly));

  @override
  FolderOutputFile append(String path) =>
      _IoOutputFile(path, File(path).openSync(mode: FileMode.writeOnlyAppend));

  @override
  void dispose() {}
}

final class _IoOutputFile implements FolderOutputFile {
  _IoOutputFile(this._path, this._handle);

  final String _path;
  final RandomAccessFile _handle;

  @override
  void write(Uint8List bytes, int start, int end) =>
      _handle.writeFromSync(bytes, start, end);

  @override
  void flush() => _handle.flushSync();

  @override
  void close({int modifiedMs = 0}) {
    _handle.closeSync();
    if (modifiedMs <= 0) return;
    try {
      File(
        _path,
      ).setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(modifiedMs));
    } on FileSystemException {
      // The file is complete; only its timestamp is off.
    }
  }
}

const int _genericWrite = 0x40000000;
const int _fileShareRead = 0x00000001;
const int _createAlways = 2;
const int _openExisting = 3;
const int _fileAttributeNormal = 0x00000080;
const int _fileEnd = 2;
const int _invalidHandle = -1;

/// Milliseconds between 1601, where Windows file times start, and 1970.
const int _windowsEpochOffsetMs = 11644473600000;

final class _Win32FolderFileWriter implements FolderFileWriter {
  _Win32FolderFileWriter() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    _createFile = kernel32
        .lookupFunction<
          IntPtr Function(
            Pointer<Utf16>,
            Uint32,
            Uint32,
            Pointer<Void>,
            Uint32,
            Uint32,
            IntPtr,
          ),
          int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
        >('CreateFileW');
    _writeFile = kernel32
        .lookupFunction<
          Int32 Function(
            IntPtr,
            Pointer<Uint8>,
            Uint32,
            Pointer<Uint32>,
            Pointer<Void>,
          ),
          int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
        >('WriteFile', isLeaf: true);
    _setFileTime = kernel32
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Void>, Pointer<Void>, Pointer<Uint64>),
          int Function(int, Pointer<Void>, Pointer<Void>, Pointer<Uint64>)
        >('SetFileTime', isLeaf: true);
    _setFilePointer = kernel32
        .lookupFunction<
          Int32 Function(IntPtr, Int64, Pointer<Int64>, Uint32),
          int Function(int, int, Pointer<Int64>, int)
        >('SetFilePointerEx', isLeaf: true);
    _flushFileBuffers = kernel32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'FlushFileBuffers',
        );
    _closeHandle = kernel32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'CloseHandle',
        );
    _getLastError = kernel32.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
      isLeaf: true,
    );
  }

  static const int _bufferSize = 256 * 1024;

  late final int Function(
    Pointer<Utf16>,
    int,
    int,
    Pointer<Void>,
    int,
    int,
    int,
  )
  _createFile;
  late final int Function(
    int,
    Pointer<Uint8>,
    int,
    Pointer<Uint32>,
    Pointer<Void>,
  )
  _writeFile;
  late final int Function(int, Pointer<Void>, Pointer<Void>, Pointer<Uint64>)
  _setFileTime;
  late final int Function(int, int, Pointer<Int64>, int) _setFilePointer;
  late final int Function(int) _flushFileBuffers;
  late final int Function(int) _closeHandle;
  late final int Function() _getLastError;

  // Reused for every file: what is written goes through native memory.
  Pointer<Uint8>? _buffer = malloc<Uint8>(_bufferSize);
  Pointer<Uint32>? _written = malloc<Uint32>();
  Pointer<Uint64>? _time = malloc<Uint64>();

  @override
  FolderOutputFile create(String path) => _open(path, _createAlways);

  @override
  FolderOutputFile append(String path) {
    final file = _open(path, _openExisting);
    if (_setFilePointer(file._handle, 0, nullptr, _fileEnd) == 0) {
      final error = _failure('Seeking to the end failed', path);
      _closeHandle(file._handle);
      throw error;
    }
    return file;
  }

  @override
  void dispose() {
    final buffer = _buffer;
    final written = _written;
    final time = _time;
    _buffer = null;
    _written = null;
    _time = null;
    if (buffer != null) malloc.free(buffer);
    if (written != null) malloc.free(written);
    if (time != null) malloc.free(time);
  }

  _Win32OutputFile _open(String path, int disposition) {
    final wide = _extendedLengthPath(path).toNativeUtf16();
    final int handle;
    try {
      handle = _createFile(
        wide,
        _genericWrite,
        _fileShareRead,
        nullptr,
        disposition,
        _fileAttributeNormal,
        0,
      );
      if (handle == _invalidHandle) {
        throw _failure('Cannot open file', path);
      }
    } finally {
      malloc.free(wide);
    }
    return _Win32OutputFile(this, path, handle);
  }

  FileSystemException _failure(String message, String path) =>
      FileSystemException(message, path, OSError('', _getLastError()));
}

final class _Win32OutputFile implements FolderOutputFile {
  _Win32OutputFile(this._writer, this._path, this._handle);

  final _Win32FolderFileWriter _writer;
  final String _path;
  final int _handle;
  bool _closed = false;

  @override
  void write(Uint8List bytes, int start, int end) {
    final buffer = _writer._buffer!;
    final written = _writer._written!;
    var offset = start;
    while (offset < end) {
      final count = math.min(_Win32FolderFileWriter._bufferSize, end - offset);
      buffer.asTypedList(count).setRange(0, count, bytes, offset);
      if (_writer._writeFile(_handle, buffer, count, written, nullptr) == 0 ||
          written.value != count) {
        throw _writer._failure('Write failed', _path);
      }
      offset += count;
    }
  }

  @override
  void flush() {
    if (_writer._flushFileBuffers(_handle) == 0) {
      throw _writer._failure('Flush failed', _path);
    }
  }

  @override
  void close({int modifiedMs = 0}) {
    if (_closed) return;
    _closed = true;
    if (modifiedMs > 0) {
      // Windows counts in 100 ns steps. A time that cannot be set leaves a
      // complete file with the wrong date, which is not worth failing over.
      final time = _writer._time!
        ..value = (modifiedMs + _windowsEpochOffsetMs) * 10000;
      _writer._setFileTime(_handle, nullptr, nullptr, time);
    }
    if (_writer._closeHandle(_handle) == 0) {
      throw _writer._failure('Close failed', _path);
    }
  }
}

/// The form of [path] that Windows accepts past 260 characters. Paths that
/// are not absolute are passed on as they are.
String _extendedLengthPath(String path) {
  const prefix = r'\\?\';
  final windows = path.replaceAll('/', r'\');
  if (windows.startsWith(prefix)) return windows;
  if (windows.startsWith(r'\\')) return '${prefix}UNC${windows.substring(1)}';
  final hasDrive =
      windows.length >= 3 && windows[1] == ':' && windows[2] == r'\';
  return hasDrive ? '$prefix$windows' : windows;
}
