import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';

typedef _DlopenNative = Pointer<Void> Function(Pointer<Utf8> name, Int32 mode);
typedef _Dlopen = Pointer<Void> Function(Pointer<Utf8> name, int mode);

const int _rtldLazy = 0x1;
const int _rtldGlobal = 0x100;

bool _linuxLibmpvSearched = false;
String? _linuxLibmpv;

/// The libmpv this Linux system has, by the name it was loaded under, or
/// null when it has none.
///
/// The video plugin is built without a link to libmpv here, because with one
/// the whole app fails to start wherever the build machine's libmpv.so.N is
/// missing; see linux/CMakeLists.txt. The plugin's calls into libmpv bind
/// the first time they are made, and for that libmpv has to be loaded where
/// every library sees it. Opening it from Dart alone keeps it private.
String? linuxSystemLibmpv() {
  if (_linuxLibmpvSearched) {
    return _linuxLibmpv;
  }
  _linuxLibmpvSearched = true;
  final dlopen = DynamicLibrary.process()
      .lookupFunction<_DlopenNative, _Dlopen>('dlopen');
  for (final name in const <String>[
    'libmpv.so.2',
    'libmpv.so.1',
    'libmpv.so',
  ]) {
    final nativeName = name.toNativeUtf8();
    try {
      if (dlopen(nativeName, _rtldLazy | _rtldGlobal) != nullptr) {
        return _linuxLibmpv = name;
      }
    } finally {
      calloc.free(nativeName);
    }
  }
  return null;
}

/// Gets the video library ready, or reports that this system has none.
/// Thumbnails of videos, the video window and casting all go through it.
bool ensureDesktopVideoLibrary() {
  if (!Platform.isLinux) {
    MediaKit.ensureInitialized();
    return true;
  }
  final libmpv = linuxSystemLibmpv();
  if (libmpv == null) {
    return false;
  }
  MediaKit.ensureInitialized(libmpv: libmpv);
  return true;
}
