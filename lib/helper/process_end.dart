import 'dart:ffi';
import 'dart:io';

import 'package:whisper/helper/app_log.dart';

/// On Windows the process is ended here, once everything of ours is
/// closed, instead of letting the engine take the plugins down.
///
/// Left to the engine, every exit ends in an access violation inside
/// flutter_windows.dll, and the couple of seconds Windows spends on a crash
/// are what closing the app seemed to take. It is in the crash records of
/// 0.0.53 to 0.0.56 and newer plugin versions have not changed it; which
/// plugin is behind it is not known. [exit] was not enough either, see
/// [endProcessNow]. Discovery is not stopped on the way out (the app's
/// `_shutdownDesktopResources`). The log is written out first: it keeps up
/// to a second of lines.
Future<void> endWindowsProcess() async {
  if (!Platform.isWindows) return;
  try {
    await AppLog.shared.flush().timeout(const Duration(milliseconds: 300));
  } on Object {
    // Gone with the process, as before.
  }
  endProcessNow();
}

/// Ends this process at once.
///
/// On Windows by `TerminateProcess` on itself. [exit] ends in
/// `ExitProcess`, which runs every library's unload code while the engine
/// is half gone, and flutter_windows.dll crashes in it now and then: 0.0.59
/// and 0.0.60 on a Windows laptop, an access violation at 0x1d7b0 and a
/// second exception five seconds later, which is when the process went.
/// Nothing of the engine or the plugins runs after this.
Never endProcessNow([int code = 0]) {
  if (Platform.isWindows) {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final current = kernel32
          .lookupFunction<IntPtr Function(), int Function()>(
            'GetCurrentProcess',
          );
      final terminate = kernel32
          .lookupFunction<
            Int32 Function(IntPtr, Uint32),
            int Function(int, int)
          >('TerminateProcess');
      terminate(current(), code);
    } on Object {
      // Not there or refused: the usual way.
    }
  }
  exit(code);
}
