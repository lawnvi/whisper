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
/// keyboard and mouse input on its lock screen.
///
/// Installing and removing it both go through a UAC prompt, after which an
/// elevated helper finishes the work on its own; the outcome is observed by
/// polling the service state.
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
  bool _busy = false;

  WindowsInputServiceState get state =>
      supported ? _state : WindowsInputServiceState.unsupported;
  bool get busy => _busy;

  Future<void> refresh() async {
    if (!supported || _busy) return;
    final state = await _queryState();
    if (_busy || state == _state) return;
    _state = state;
    notifyListeners();
  }

  /// Installs the service, or reinstalls it over a stopped or outdated one.
  Future<WindowsInputServiceResult> install() =>
      _runElevated('installInputService', WindowsInputServiceState.running);

  Future<WindowsInputServiceResult> uninstall() => _runElevated(
    'uninstallInputService',
    WindowsInputServiceState.notInstalled,
  );

  Future<WindowsInputServiceResult> _runElevated(
    String method,
    WindowsInputServiceState wanted,
  ) async {
    if (!supported || _busy) return WindowsInputServiceResult.failed;
    _busy = true;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>(method);
      for (var attempt = 0; attempt < pollAttempts; attempt++) {
        _state = await _queryState();
        if (_state == wanted) return WindowsInputServiceResult.applied;
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

  Future<WindowsInputServiceState> _queryState() async {
    try {
      final name = await _channel.invokeMethod<String>('getInputServiceState');
      return switch (name) {
        'running' => WindowsInputServiceState.running,
        'stopped' => WindowsInputServiceState.stopped,
        'outdated' => WindowsInputServiceState.outdated,
        _ => WindowsInputServiceState.notInstalled,
      };
    } on MissingPluginException {
      return WindowsInputServiceState.unsupported;
    }
  }
}
