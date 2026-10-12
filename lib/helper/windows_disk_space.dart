import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _GetDiskFreeSpaceExNative =
    Int32 Function(
      Pointer<Utf16> directory,
      Pointer<Uint64> availableToCaller,
      Pointer<Uint64> total,
      Pointer<Uint64> totalFree,
    );
typedef _GetDiskFreeSpaceEx =
    int Function(
      Pointer<Utf16> directory,
      Pointer<Uint64> availableToCaller,
      Pointer<Uint64> total,
      Pointer<Uint64> totalFree,
    );

/// The bytes the current user may still write on the volume holding the
/// existing directory [directory], or null when Windows cannot tell.
///
/// Asked of the system directly: starting PowerShell for the same number
/// took 0.7 to 0.9 s, which every incoming transfer waited for.
int? windowsAvailableBytes(String directory) {
  final getDiskFreeSpaceEx = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<_GetDiskFreeSpaceExNative, _GetDiskFreeSpaceEx>(
        'GetDiskFreeSpaceExW',
      );
  final path = directory.toNativeUtf16();
  final available = calloc<Uint64>();
  try {
    if (getDiskFreeSpaceEx(path, available, nullptr, nullptr) == 0) {
      return null;
    }
    return available.value;
  } finally {
    calloc.free(path);
    calloc.free(available);
  }
}
