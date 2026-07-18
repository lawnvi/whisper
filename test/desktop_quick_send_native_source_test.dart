import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows installer registers file and folder quick-send verbs', () {
    final installer = File('windows/installer.nsi').readAsStringSync();
    final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();
    final plugin = File(
      'windows/runner/desktop_quick_send_plugin.cpp',
    ).readAsStringSync();

    expect(installer, contains(r'Software\Classes\*\shell\Whisper.Send'));
    expect(
      installer,
      contains(r'Software\Classes\Directory\shell\Whisper.Send'),
    );
    expect(installer, contains('--quick-send-file'));
    expect(installer, contains('CONTROL|ALT|V'));
    expect(installer, contains(r'Quick Send.lnk'));
    expect(installer, contains('DeleteRegKey HKCU'));
    expect(cmake, contains('desktop_quick_send_plugin.cpp'));
    expect(plugin, contains('pending_'));
    expect(plugin, contains('pending_before_plugin'));
    expect(plugin, contains('consumePendingQuickSends'));
    expect(plugin, contains('acknowledgeQuickSend'));
    expect(plugin, contains('PersistState'));
    expect(plugin, contains('desktop_quick_send_queue.dat'));
    expect(plugin, contains('NewId("windows")'));
    expect(plugin, isNot(contains('erase(pending_before_plugin.begin())')));
    expect(plugin, contains('InvokeMethod("quickSendReceived", nullptr)'));
  });

  test('macOS exposes a Finder service through the native inbox bridge', () {
    final plist = File('macos/Runner/Info.plist').readAsStringSync();
    final appDelegate = File(
      'macos/Runner/AppDelegate.swift',
    ).readAsStringSync();
    final window = File(
      'macos/Runner/MainFlutterWindow.swift',
    ).readAsStringSync();

    expect(plist, contains('<key>NSServices</key>'));
    expect(plist, contains('<string>receiveQuickSendService</string>'));
    expect(appDelegate, contains('NSApp.servicesProvider = self'));
    expect(
      appDelegate,
      isNot(contains('super.applicationDidFinishLaunching(notification)')),
    );
    expect(appDelegate, contains('DesktopQuickSendBridge.shared.enqueue'));
    expect(appDelegate, contains('maximumPendingCount = 32'));
    expect(appDelegate, contains('acknowledgeQuickSend'));
    expect(appDelegate, contains('desktop_quick_send_queue.json'));
    expect(appDelegate, contains('UUID().uuidString'));
    expect(appDelegate, isNot(contains('pendingArguments.removeFirst()')));
    expect(window, contains('registerDesktopQuickSendChannel'));
  });

  test('Linux forwards second launch arguments and packages file entries', () {
    final application = File('linux/my_application.cc').readAsStringSync();
    final deb = File('linux/build_deb.sh').readAsStringSync();
    final rpm = File('linux/build_rpm.sh').readAsStringSync();
    final appImage = File('linux/build_appimage.sh').readAsStringSync();
    final cmake = File('linux/CMakeLists.txt').readAsStringSync();
    final plugin = File(
      'linux/desktop_quick_send_plugin.cc',
    ).readAsStringSync();

    expect(application, contains('G_APPLICATION_HANDLES_COMMAND_LINE'));
    expect(application, isNot(contains('G_APPLICATION_NON_UNIQUE')));
    expect(application, contains('desktop_quick_send_plugin_emit_arguments'));
    expect(deb, contains('--quick-send %F'));
    expect(deb, contains('ServiceMenus'));
    expect(rpm, contains('--quick-send %F'));
    expect(appImage, contains('--quick-send %F'));
    expect(cmake, contains('desktop_quick_send_plugin.cc'));
    expect(plugin, contains('pending_entries'));
    expect(plugin, contains('consumePendingQuickSends'));
    expect(plugin, contains('acknowledgeQuickSend'));
    expect(plugin, contains('PersistState'));
    expect(plugin, contains('desktop_quick_send_queue.ini'));
    expect(plugin, contains('g_uuid_string_random'));
    expect(plugin, contains('RequestsBareClipboardCapture'));
    expect(plugin, contains('clipboardSnapshotUnavailable'));
    expect(plugin, contains('discarded_legacy_bare_capture'));
    expect(plugin, contains('rejection_reason'));
    expect(plugin, isNot(contains('g_queue_pop_head(pending_entries)')));
    expect(
      plugin,
      contains('invoke_method(channel, "quickSendReceived", nullptr'),
    );
  });

  test('global shortcut captures clipboard content into the desktop inbox', () {
    final source = File(
      'lib/helper/desktop_quick_send_hotkey.dart',
    ).readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final macOSPlugins = File(
      'macos/Flutter/GeneratedPluginRegistrant.swift',
    ).readAsStringSync();
    final windowsPlugins = File(
      'windows/flutter/generated_plugins.cmake',
    ).readAsStringSync();
    final linuxPlugins = File(
      'linux/flutter/generated_plugins.cmake',
    ).readAsStringSync();

    expect(pubspec, contains('hotkey_manager: ^0.2.3'));
    expect(source, contains('HotKeyScope.system'));
    expect(source, contains('PhysicalKeyboardKey.keyV'));
    expect(source, contains('HotKeyModifier.meta'));
    expect(source, contains('HotKeyModifier.control'));
    expect(source, contains('DesktopClipboardFileReader'));
    expect(source, contains('includeDirectories: true'));
    expect(source, contains('DesktopClipboardImageReader'));
    expect(source, contains('_inbox.addClipboard'));
    expect(macOSPlugins, contains('hotkey_manager_macos'));
    expect(windowsPlugins, contains('hotkey_manager_windows'));
    expect(linuxPlugins, contains('hotkey_manager_linux'));
  });
}
