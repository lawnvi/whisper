import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A macOS privacy permission one of Whisper's features needs.
enum MacPermission {
  /// Keyboard and mouse sharing; acting in streamed windows.
  accessibility,

  /// Screen & System Audio Recording: streaming windows to other devices,
  /// playing this Mac's sound elsewhere, screenshots.
  screenRecording,

  /// System Audio Recording Only: a streamed window's own sound.
  audioCapture,
}

enum MacPermissionState {
  granted,
  denied,

  /// Never asked: asking shows the system's prompt.
  notAsked,

  /// The system does not say (no way to read it on this macOS).
  unknown,
}

/// What macOS has allowed Whisper, for Settings. Read again every few
/// seconds while something listens (the switches live in System Settings,
/// which says nothing when they change) and when the app comes back to the
/// front.
class MacPermissions extends ChangeNotifier {
  MacPermissions({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.vireen.whisper/macos_permissions';

  static final MacPermissions shared = MacPermissions();

  static bool get supported => !kIsWeb && Platform.isMacOS;

  final MethodChannel _channel;
  final _states = <MacPermission, MacPermissionState>{};
  Timer? _poll;
  AppLifecycleListener? _lifecycle;

  MacPermissionState stateOf(MacPermission permission) =>
      _states[permission] ?? MacPermissionState.unknown;

  @override
  void addListener(VoidCallback listener) {
    final first = !hasListeners;
    super.addListener(listener);
    if (first) {
      unawaited(refresh());
      _poll = Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(refresh()),
      );
      _lifecycle = AppLifecycleListener(onResume: () => unawaited(refresh()));
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _poll?.cancel();
      _poll = null;
      _lifecycle?.dispose();
      _lifecycle = null;
    }
  }

  Future<void> refresh() async {
    try {
      _apply(await _channel.invokeMapMethod<String, Object?>('status'));
    } on MissingPluginException {
      // Not on macOS, or an older runner.
    } on PlatformException {
      // Left as it was.
    }
  }

  /// Asks for [permission]: the system's prompt where it still shows one,
  /// else System Settings at the pane where its switch is.
  Future<void> request(MacPermission permission) async {
    try {
      _apply(
        await _channel.invokeMapMethod<String, Object?>('request', {
          'kind': permission.name,
        }),
      );
    } on MissingPluginException {
      // Nothing to ask.
    } on PlatformException {
      // Nothing changed.
    }
  }

  void _apply(Map<String, Object?>? status) {
    if (status == null) {
      return;
    }
    MacPermissionState flag(Object? value) => switch (value) {
      true => MacPermissionState.granted,
      false => MacPermissionState.denied,
      _ => MacPermissionState.unknown,
    };
    final next = {
      MacPermission.accessibility: flag(status['accessibility']),
      MacPermission.screenRecording: flag(status['screenRecording']),
      MacPermission.audioCapture: switch (status['audioCapture']) {
        'granted' => MacPermissionState.granted,
        'denied' => MacPermissionState.denied,
        'notAsked' => MacPermissionState.notAsked,
        _ => MacPermissionState.unknown,
      },
    };
    if (mapEquals(next, _states)) {
      return;
    }
    _states
      ..clear()
      ..addAll(next);
    notifyListeners();
  }
}
