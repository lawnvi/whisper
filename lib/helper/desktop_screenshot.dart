import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/helper/linux_screenshot_portal.dart';
import 'package:whisper/helper/screenshot_shortcut.dart';

enum ScreenshotNotice { copied, permissionDenied, unavailable, failed }

abstract class ScreenshotBackend {
  void Function()? onShortcut;
  Map<String, String> captureLabels = const {};
  Future<bool> captureRegion();
  Future<String?> setShortcut(ScreenshotShortcut? shortcut, String description);
  Future<void> close();
}

class NativeScreenshotBackend extends ScreenshotBackend {
  static const channel = MethodChannel('com.vireen.whisper/screenshot');
  LinuxScreenshotPortal? _portal;

  NativeScreenshotBackend() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'shortcutPressed') onShortcut?.call();
    });
    if (Platform.isLinux &&
        (Platform.environment['XDG_SESSION_TYPE'] == 'wayland' ||
            Platform.environment.containsKey('WAYLAND_DISPLAY'))) {
      _portal = LinuxScreenshotPortal(onShortcut: () => onShortcut?.call());
    }
  }

  @override
  Future<bool> captureRegion() async => _portal != null
      ? _portal!.captureRegion()
      : await channel.invokeMethod<bool>('captureRegion', captureLabels) ??
            false;

  @override
  Future<String?> setShortcut(
    ScreenshotShortcut? shortcut,
    String description,
  ) async {
    if (_portal != null) return _portal!.setShortcut(shortcut, description);
    await channel.invokeMethod<void>('setShortcut', shortcut?.toJson());
    return null;
  }

  @override
  Future<void> close() async {
    await setShortcut(null, '');
    await _portal?.close();
    channel.setMethodCallHandler(null);
  }
}

class DesktopScreenshotController extends ChangeNotifier {
  DesktopScreenshotController({
    required ScreenshotBackend backend,
    required this.macOS,
    required Future<String?> Function() load,
    required Future<void> Function(String) save,
  }) : _backend = backend,
       _load = load,
       _save = save,
       shortcut = ScreenshotShortcut.defaultFor(macOS: macOS) {
    _backend.onShortcut = () {
      if (!shortcutsPaused) unawaited(capture());
    };
  }

  static final shared = DesktopScreenshotController(
    backend: NativeScreenshotBackend(),
    macOS: Platform.isMacOS,
    load: () async => (await SharedPreferences.getInstance()).getString(
      'screenshot_shortcut_v1',
    ),
    save: (value) async {
      if (!await (await SharedPreferences.getInstance()).setString(
        'screenshot_shortcut_v1',
        value,
      )) {
        throw StateError('Unable to save screenshot shortcut');
      }
    },
  );

  final ScreenshotBackend _backend;
  final bool macOS;
  final Future<String?> Function() _load;
  final Future<void> Function(String) _save;
  ScreenshotShortcut shortcut;
  bool enabled = true;
  bool registered = false;
  bool capturing = false;
  bool configuring = false;
  bool shortcutsPaused = false;
  String? systemShortcutLabel;
  String _description = 'Whisper';
  Future<void>? _initialization;
  void Function(ScreenshotNotice)? onNotice;

  String get shortcutLabel =>
      systemShortcutLabel ?? shortcut.label(macOS: macOS);

  Future<void> initialize(
    String description, {
    Map<String, String> captureLabels = const {},
  }) {
    _description = description;
    if (captureLabels.isNotEmpty) _backend.captureLabels = captureLabels;
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      final saved = await _load();
      if (saved != null) {
        final json = jsonDecode(saved) as Map<String, dynamic>;
        shortcut = ScreenshotShortcut.fromJson(json);
        enabled = json['enabled'] != false;
      }
    } catch (_) {
      shortcut = ScreenshotShortcut.defaultFor(macOS: macOS);
    }
    if (enabled) {
      try {
        systemShortcutLabel = await _backend.setShortcut(
          shortcut,
          _description,
        );
        registered = true;
      } catch (_) {
        registered = false;
      }
    }
    notifyListeners();
  }

  Future<void> configure(
    ScreenshotShortcut candidate, {
    required bool enabled,
  }) async {
    await initialize(_description);
    if (!candidate.isValid || candidate.isQuickSendShortcut(macOS: macOS)) {
      throw PlatformException(code: 'shortcut-invalid');
    }
    if (configuring) throw PlatformException(code: 'shortcut-busy');
    if (candidate == shortcut &&
        enabled == this.enabled &&
        (!enabled || registered)) {
      return;
    }
    configuring = true;
    notifyListeners();
    final previous = registered ? shortcut : null;
    try {
      // Native registration keeps the old binding until the replacement succeeds.
      final label = await _backend.setShortcut(
        enabled ? candidate : null,
        _description,
      );
      try {
        await _save(jsonEncode({...candidate.toJson(), 'enabled': enabled}));
      } catch (_) {
        try {
          systemShortcutLabel = await _backend.setShortcut(
            previous,
            _description,
          );
        } catch (_) {
          registered = false;
        }
        rethrow;
      }
      shortcut = candidate;
      this.enabled = enabled;
      registered = enabled;
      systemShortcutLabel = label;
    } finally {
      configuring = false;
      notifyListeners();
    }
  }

  Future<void> capture() async {
    if (capturing || configuring) return;
    capturing = true;
    notifyListeners();
    try {
      if (await _backend.captureRegion()) {
        onNotice?.call(ScreenshotNotice.copied);
      }
    } on MissingPluginException {
      onNotice?.call(ScreenshotNotice.unavailable);
    } on PlatformException catch (error) {
      onNotice?.call(switch (error.code) {
        'permission-denied' => ScreenshotNotice.permissionDenied,
        'unavailable' => ScreenshotNotice.unavailable,
        _ => ScreenshotNotice.failed,
      });
    } catch (_) {
      onNotice?.call(ScreenshotNotice.failed);
    } finally {
      capturing = false;
      notifyListeners();
    }
  }

  Future<void> shutdown() async {
    onNotice = null;
    _backend.onShortcut = null;
    await _backend.close();
  }
}
