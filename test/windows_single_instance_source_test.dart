import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows runner exits second launches and wakes the existing window',
      () {
    final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();
    final main = File('windows/runner/main.cpp').readAsStringSync();
    final win32Header =
        File('windows/runner/win32_window.h').readAsStringSync();
    final win32Source =
        File('windows/runner/win32_window.cpp').readAsStringSync();

    expect(cmake, contains('"single_instance.cpp"'));
    expect(main, contains('#include "single_instance.h"'));
    expect(main, contains('SingleInstanceLock single_instance_lock'));
    expect(main, contains('!single_instance_lock.IsPrimary()'));
    expect(main, contains('NotifyExistingInstance()'));

    expect(win32Header, contains('static const wchar_t* GetWindowClassName()'));
    expect(win32Source, contains('WHISPER_RUNNER_WIN32_WINDOW'));
    expect(win32Source, contains('GetSingleInstanceWakeMessage()'));
    expect(win32Source, contains('ShowWindow(hwnd, SW_RESTORE)'));
    expect(win32Source, contains('SetForegroundWindow(hwnd)'));
  });
}
