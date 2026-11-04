import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/helper/linux_screenshot_portal.dart';
import 'package:whisper/helper/screenshot_shortcut.dart';

enum ScreenshotNotice { copied, permissionDenied, unavailable, failed }

/// One screen as it was: opaque, tightly packed RGBA rows.
class ScreenshotPicture {
  const ScreenshotPicture({
    required this.width,
    required this.height,
    required this.rgba,
    required this.scale,
    required this.frame,
  });

  final int width, height;
  final Uint8List rgba;

  /// Pixels to a point on that screen.
  final double scale;

  /// Where that screen is, as the platform's windows are placed: x, y, width,
  /// height.
  final List<double> frame;

  factory ScreenshotPicture.fromMap(Map<Object?, Object?> map) =>
      ScreenshotPicture(
        width: map['width']! as int,
        height: map['height']! as int,
        rgba: map['rgba']! as Uint8List,
        scale: (map['scale']! as num).toDouble(),
        frame: (map['frame']! as List)
            .cast<num>()
            .map((v) => v.toDouble())
            .toList(),
      );
}

/// How the overlay ended: cancelled, with the picture on the clipboard, or with
/// a selection for the app's own window to take over.
class ScreenshotResult {
  const ScreenshotResult({this.copied = false, this.selection, this.picture});

  final bool copied;

  /// x, y, width, height in points, from the top left of its screen.
  final List<double>? selection;

  /// That screen. Null when it was sent ahead, with [ScreenshotBackend.onSnapshot].
  final ScreenshotPicture? picture;
}

abstract class ScreenshotBackend {
  void Function()? onShortcut;

  /// The screen the selection is probably on, while it is being made.
  void Function(ScreenshotPicture)? onSnapshot;
  Map<String, String> captureLabels = const {};
  Future<ScreenshotResult> captureRegion();

  /// A selection was handed over: the overlay stays until the window that takes
  /// over is up, so that nothing on screen changes.
  Future<void> closeOverlay() async {}
  Future<String?> setShortcut(ScreenshotShortcut? shortcut, String description);
  Future<void> close();
}

class NativeScreenshotBackend extends ScreenshotBackend {
  static const channel = MethodChannel('com.vireen.whisper/screenshot');
  LinuxScreenshotPortal? _portal;

  NativeScreenshotBackend() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'shortcutPressed') onShortcut?.call();
      if (call.method == 'snapshot') {
        onSnapshot?.call(
          ScreenshotPicture.fromMap(call.arguments as Map<Object?, Object?>),
        );
      }
    });
    if (Platform.isLinux &&
        (Platform.environment['XDG_SESSION_TYPE'] == 'wayland' ||
            Platform.environment.containsKey('WAYLAND_DISPLAY'))) {
      _portal = LinuxScreenshotPortal(onShortcut: () => onShortcut?.call());
    }
  }

  @override
  Future<ScreenshotResult> captureRegion() async {
    // The compositor does the selecting, with nothing of ours on screen: the
    // picture is marked up after pasting it, from the composer.
    if (_portal != null) {
      return ScreenshotResult(copied: await _portal!.captureRegion());
    }
    final result = await channel.invokeMethod<Object?>(
      'captureRegion',
      captureLabels,
    );
    if (result is! Map) return ScreenshotResult(copied: result == true);
    return ScreenshotResult(
      selection: (result['selection']! as List)
          .cast<num>()
          .map((v) => v.toDouble())
          .toList(),
      picture: result['rgba'] == null
          ? null
          : ScreenshotPicture.fromMap(result.cast<Object?, Object?>()),
    );
  }

  @override
  Future<void> closeOverlay() => channel.invokeMethod<void>('closeOverlay');

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
    this.windows = false,
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
    windows: Platform.isWindows,
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
  final bool windows;
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

  /// Takes over from the overlay and, once the picture is marked up, puts it on
  /// the clipboard. Says whether it did: cancelling is not a failure, and needs
  /// no notice either. [picture] unless it came with [onPicture] before this.
  /// [closeOverlay] once it is on screen.
  Future<bool> Function(
    List<double> selection,
    ScreenshotPicture? picture,
    Future<void> Function() closeOverlay,
  )?
  onMarkUp;

  /// Gets ready for [onMarkUp], while the selection is being made.
  Future<void> Function()? onPrepare;
  void Function(ScreenshotPicture)? onPicture;

  /// Ended without a selection: whatever was got ready can go.
  void Function()? onAbandon;

  String get shortcutLabel =>
      systemShortcutLabel ?? shortcut.label(macOS: macOS, windows: windows);

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
      _backend.onSnapshot = (picture) => onPicture?.call(picture);
      final prepare = onPrepare?.call();
      // A window coming up during the selection would end it, where losing the
      // keyboard does. On a Mac it takes no keyboard.
      if (!macOS) await prepare;
      final result = await _backend.captureRegion();
      final selection = result.selection;
      if (selection == null) onAbandon?.call();
      final copied = selection == null
          ? result.copied
          : await onMarkUp?.call(
                  selection,
                  result.picture,
                  _backend.closeOverlay,
                ) ??
                false;
      if (copied) onNotice?.call(ScreenshotNotice.copied);
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
