import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _RegGetValueNative =
    Int32 Function(
      IntPtr key,
      Pointer<Utf16> subKey,
      Pointer<Utf16> value,
      Uint32 flags,
      Pointer<Uint32> type,
      Pointer<Uint32> data,
      Pointer<Uint32> dataSize,
    );
typedef _RegGetValue =
    int Function(
      int key,
      Pointer<Utf16> subKey,
      Pointer<Utf16> value,
      int flags,
      Pointer<Uint32> type,
      Pointer<Uint32> data,
      Pointer<Uint32> dataSize,
    );

// HKEY_CURRENT_USER, which Windows defines as the 32-bit value 0x80000001
// widened with its sign.
const int _currentUser = -0x7FFFFFFF;
const int _onlyDword = 0x00000010;

/// Whether the Windows taskbar is the light one, or null when Windows does
/// not say (it had no light taskbar before 1903).
///
/// This is the mode Windows uses for itself. It can differ from the mode it
/// asks apps to use, which is what Flutter reports as the platform
/// brightness, and from Whisper's own theme. The tray icon sits on the
/// taskbar, so this is the one that decides which icon can be seen there.
bool? windowsTaskbarIsLight() {
  final regGetValue = DynamicLibrary.open(
    'advapi32.dll',
  ).lookupFunction<_RegGetValueNative, _RegGetValue>('RegGetValueW');
  final subKey = r'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
      .toNativeUtf16();
  final value = 'SystemUsesLightTheme'.toNativeUtf16();
  final data = calloc<Uint32>();
  final size = calloc<Uint32>()..value = sizeOf<Uint32>();
  try {
    final status = regGetValue(
      _currentUser,
      subKey,
      value,
      _onlyDword,
      nullptr,
      data,
      size,
    );
    return status == 0 ? data.value != 0 : null;
  } finally {
    calloc.free(subKey);
    calloc.free(value);
    calloc.free(data);
    calloc.free(size);
  }
}

/// The tray icon that shows up against the taskbar: the white one, or its
/// dark twin when the taskbar is light.
String windowsTrayIconAsset({required bool? taskbarIsLight}) =>
    taskbarIsLight == true
    ? 'assets/tray_icon_on_light.ico'
    : 'assets/tray_icon.ico';

/// Keeps the Windows tray icon matching the taskbar for as long as there is
/// a tray.
///
/// The setting is read again every couple of seconds rather than when
/// Windows announces a change. The announcement reaches the app before
/// Windows has written its own mode down, so an icon chosen at that moment
/// is the one for the taskbar as it was: it stayed one switch behind, dark
/// on dark and white on light. And when only Windows' own mode changes, with
/// the one for apps left alone, nothing is announced at all.
final class WindowsTrayIconWatch {
  WindowsTrayIconWatch({
    required Future<void> Function(String asset) apply,
    bool? Function() taskbarIsLight = windowsTaskbarIsLight,
    this.interval = const Duration(seconds: 2),
  }) : _apply = apply,
       _taskbarIsLight = taskbarIsLight;

  final Future<void> Function(String asset) _apply;
  final bool? Function() _taskbarIsLight;
  final Duration interval;
  Timer? _timer;
  String? _shown;

  /// Shows the icon for the taskbar as it is and keeps it that way.
  Future<void> start() async {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(_sync()));
    await _sync();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _shown = null;
  }

  Future<void> _sync() async {
    final asset = windowsTrayIconAsset(taskbarIsLight: _taskbarIsLight());
    if (asset == _shown) {
      return;
    }
    _shown = asset;
    try {
      await _apply(asset);
    } on Object {
      // Tried again on the next look.
      if (_shown == asset) {
        _shown = null;
      }
    }
  }
}
