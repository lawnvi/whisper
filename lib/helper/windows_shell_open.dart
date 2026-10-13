import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _ShellExecuteNative =
    IntPtr Function(
      IntPtr window,
      Pointer<Utf16> operation,
      Pointer<Utf16> file,
      Pointer<Utf16> parameters,
      Pointer<Utf16> directory,
      Int32 show,
    );
typedef _ShellExecute =
    int Function(
      int window,
      Pointer<Utf16> operation,
      Pointer<Utf16> file,
      Pointer<Utf16> parameters,
      Pointer<Utf16> directory,
      int show,
    );

const int _showNormal = 1;

/// Opens the file at [path] with the program Windows associates with it,
/// and reports whether the shell accepted it.
///
/// The path is handed to the shell as it is. Going through `cmd /c start`
/// instead lets cmd read the path as a command line, and a file that arrived
/// from another device carries the name its sender chose: `a&calc&.txt` in a
/// folder without spaces ran `calc`.
bool openWithWindowsShell(String path) {
  if (path.isEmpty) {
    return false;
  }
  final shellExecute = DynamicLibrary.open(
    'shell32.dll',
  ).lookupFunction<_ShellExecuteNative, _ShellExecute>('ShellExecuteW');
  final operation = 'open'.toNativeUtf16();
  final file = path.toNativeUtf16();
  try {
    // Anything up to 32 is an error code.
    return shellExecute(0, operation, file, nullptr, nullptr, _showNormal) >
        32;
  } finally {
    calloc.free(operation);
    calloc.free(file);
  }
}
