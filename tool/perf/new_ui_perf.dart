// Step 1 of docs/design/migration.md: how the new UI's glass, blur and window
// material run in profile mode, on a real machine. It shows the throwaway probe
// with sample data, switches tabs and scrolls by itself, and prints `probe:`
// lines. It does not start the app's services or touch its data.
//
//   flutter run --profile -t tool/perf/new_ui_perf.dart
//
// It measures tab switches with and without their blur. Set WHISPER_PROBE_OUT to
// a folder to also get the results as a file, WHISPER_PROBE_MANUAL=1 to skip the
// measuring and WHISPER_PROBE_DARK=1 for the dark theme.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:whisper/new_ui/probe/window_probe.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_window.dart';

final _manual = Platform.environment['WHISPER_PROBE_MANUAL'] == '1';
final _dark = Platform.environment['WHISPER_PROBE_DARK'] == '1';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await windowManager.ensureInitialized();
    unawaited(
      windowManager.waitUntilReadyToShow(
        WhisperWindow.options(const Size(1144, 720)),
        () async {
          await WhisperWindow.enableMaterial(
            _dark ? Brightness.dark : Brightness.light,
          );
          await windowManager.show();
          await windowManager.focus();
        },
      ),
    );
  }
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      home: WindowProbe(autorun: !_manual, tray: false),
    ),
  );
}
