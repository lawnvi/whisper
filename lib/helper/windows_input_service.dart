import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';

enum WindowsInputServiceState {
  unsupported,
  notInstalled,
  stopped,
  running,
  outdated,
}

enum WindowsInputServiceResult { applied, cancelled, failed }

/// The optional LocalSystem service that lets a Windows device take shared
/// keyboard and mouse input on its lock screen and, once allowed, on UAC
/// prompts.
///
/// Every change goes through a UAC prompt, after which an elevated helper
/// finishes the work on its own; the outcome is observed by polling.
class WindowsInputServiceController extends ChangeNotifier {
  WindowsInputServiceController({
    MethodChannel? channel,
    bool? supported,
    this.pollInterval = const Duration(milliseconds: 500),
    this.pollAttempts = 40,
  }) : _channel =
           channel ?? const MethodChannel(RemoteInputPlatform.channelName),
       supported = supported ?? Platform.isWindows;

  static final shared = WindowsInputServiceController();

  final MethodChannel _channel;
  final bool supported;
  final Duration pollInterval;
  final int pollAttempts;
  WindowsInputServiceState _state = WindowsInputServiceState.notInstalled;
  bool _elevatedAllowed = false;
  bool _busy = false;

  WindowsInputServiceState get state =>
      supported ? _state : WindowsInputServiceState.unsupported;

  /// Whether the service also reaches UAC prompts once the session is
  /// unlocked. Only a running service can, so this is false in any other state.
  bool get elevatedAllowed => _elevatedAllowed;
  bool get busy => _busy;

  Future<void> refresh() async {
    if (!supported || _busy) return;
    final (state, elevatedAllowed) = await _query();
    if (_busy || (state == _state && elevatedAllowed == _elevatedAllowed)) {
      return;
    }
    _state = state;
    _elevatedAllowed = elevatedAllowed;
    notifyListeners();
  }

  /// Installs the service, or reinstalls it over a stopped or outdated one.
  Future<WindowsInputServiceResult> install() => _runElevated(
    'installInputService',
    () => _state == WindowsInputServiceState.running,
  );

  /// Removes the service, which also withdraws [elevatedAllowed].
  Future<WindowsInputServiceResult> uninstall() => _runElevated(
    'uninstallInputService',
    () => _state == WindowsInputServiceState.notInstalled,
  );

  Future<WindowsInputServiceResult> setElevatedAllowed(bool allowed) =>
      _runElevated(
        allowed ? 'enableElevatedInput' : 'disableElevatedInput',
        () => _elevatedAllowed == allowed,
      );

  Future<WindowsInputServiceResult> _runElevated(
    String method,
    bool Function() applied,
  ) async {
    if (!supported || _busy) return WindowsInputServiceResult.failed;
    _busy = true;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>(method);
      for (var attempt = 0; attempt < pollAttempts; attempt++) {
        final (state, elevatedAllowed) = await _query();
        _state = state;
        _elevatedAllowed = elevatedAllowed;
        if (applied()) return WindowsInputServiceResult.applied;
        await Future<void>.delayed(pollInterval);
      }
      return WindowsInputServiceResult.failed;
    } on PlatformException catch (error) {
      return error.code == 'cancelled'
          ? WindowsInputServiceResult.cancelled
          : WindowsInputServiceResult.failed;
    } on MissingPluginException {
      return WindowsInputServiceResult.failed;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<(WindowsInputServiceState, bool)> _query() async {
    try {
      final name = await _channel.invokeMethod<String>('getInputServiceState');
      final state = switch (name) {
        'running' => WindowsInputServiceState.running,
        'stopped' => WindowsInputServiceState.stopped,
        'outdated' => WindowsInputServiceState.outdated,
        _ => WindowsInputServiceState.notInstalled,
      };
      final elevatedAllowed =
          state == WindowsInputServiceState.running &&
          (await _channel.invokeMethod<bool>('getElevatedInputAllowed') ??
              false);
      return (state, elevatedAllowed);
    } on MissingPluginException {
      return (WindowsInputServiceState.unsupported, false);
    }
  }
}
