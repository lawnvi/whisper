import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Whether this computer is a laptop ('laptop'), a desktop ('desktop') or
/// cannot tell (''), for the picture others draw of it. A built-in battery
/// is what makes a laptop; on Linux the chassis type says so first. Read
/// once, it does not change.
String detectComputerFormFactor() {
  try {
    if (Platform.isWindows) return _windows();
    if (Platform.isMacOS) return _mac();
    if (Platform.isLinux) return _linux();
  } catch (_) {
    // Cannot tell: drawn by its name, as before.
  }
  return '';
}

const _laptop = 'laptop', _desktop = 'desktop';

/// `GetSystemPowerStatus`: BatteryFlag 128 is "no system battery", 255
/// "unknown". A desktop on a UPS may look like a laptop.
String _windows() {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final status = kernel32
      .lookupFunction<
        Int32 Function(Pointer<Uint8>),
        int Function(Pointer<Uint8>)
      >('GetSystemPowerStatus');
  final buffer = calloc<Uint8>(12);
  try {
    if (status(buffer) == 0) return '';
    final flag = buffer[1];
    if (flag == 255) return '';
    return flag & 128 != 0 ? _desktop : _laptop;
  } finally {
    calloc.free(buffer);
  }
}

/// A Mac with the smart battery service is a MacBook; the rest have none.
String _mac() {
  final iokit = DynamicLibrary.open(
    '/System/Library/Frameworks/IOKit.framework/IOKit',
  );
  final matching = iokit
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>),
        Pointer<Void> Function(Pointer<Utf8>)
      >('IOServiceMatching');
  // Takes the dictionary: nothing to release but the service.
  final service = iokit
      .lookupFunction<
        Uint32 Function(Uint32, Pointer<Void>),
        int Function(int, Pointer<Void>)
      >('IOServiceGetMatchingService');
  final release = iokit
      .lookupFunction<Int32 Function(Uint32), int Function(int)>(
        'IOObjectRelease',
      );
  final name = 'AppleSmartBattery'.toNativeUtf8();
  try {
    final dictionary = matching(name);
    if (dictionary == nullptr) return '';
    final found = service(0, dictionary);
    if (found == 0) return _desktop;
    release(found);
    return _laptop;
  } finally {
    calloc.free(name);
  }
}

/// The DMI chassis type, else a system battery (not a mouse's: those say
/// their scope is a device).
String _linux() {
  final chassis = File('/sys/class/dmi/id/chassis_type');
  if (chassis.existsSync()) {
    final type = int.tryParse(chassis.readAsStringSync().trim());
    if (const {8, 9, 10, 11, 14, 30, 31, 32}.contains(type)) return _laptop;
    if (const {3, 4, 5, 6, 7, 13, 15, 16, 24, 35, 36}.contains(type)) {
      return _desktop;
    }
  }
  final supplies = Directory('/sys/class/power_supply');
  if (!supplies.existsSync()) return '';
  for (final supply in supplies.listSync()) {
    final type = File('${supply.path}/type');
    if (!type.existsSync() || type.readAsStringSync().trim() != 'Battery') {
      continue;
    }
    final scope = File('${supply.path}/scope');
    if (scope.existsSync() && scope.readAsStringSync().trim() == 'Device') {
      continue;
    }
    return _laptop;
  }
  return _desktop;
}
