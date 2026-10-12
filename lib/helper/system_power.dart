import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:whisper/socket/svrmanager.dart';

/// Lets peers go before the system sleeps and takes them back once it is
/// awake. Only macOS reports these today, and it holds sleep until the
/// `willSleep` call has been answered.
class SystemPowerBridge {
  SystemPowerBridge({
    Future<void> Function()? prepareForSleep,
    void Function()? resumeFromSleep,
    MethodChannel channel = const MethodChannel(channelName),
    this.missedWakeTimeout = const Duration(seconds: 40),
  }) : _prepareForSleep =
           prepareForSleep ?? (() => WsSvrManager().prepareForSystemSleep()),
       _resumeFromSleep =
           resumeFromSleep ?? (() => WsSvrManager().resumeFromSystemSleep()),
       _channel = channel;

  static const String channelName = 'com.vireen.whisper/system_power';

  final Future<void> Function() _prepareForSleep;
  final void Function() _resumeFromSleep;
  final MethodChannel _channel;

  /// How long to wait for the wake notice before taking peers back anyway.
  final Duration missedWakeTimeout;

  Timer? _missedWake;

  void attach() {
    if (!Platform.isMacOS) {
      return;
    }
    _channel.setMethodCallHandler(handle);
  }

  Future<void> handle(MethodCall call) async {
    switch (call.method) {
      case 'willSleep':
        // The wake notice normally cancels this. It covers a notice that
        // never comes, such as when the system calls the sleep off, so that
        // peers are not refused for good.
        _missedWake?.cancel();
        _missedWake = Timer(missedWakeTimeout, _resume);
        await _prepareForSleep();
      case 'didWake':
        _resume();
      default:
        throw MissingPluginException();
    }
  }

  void _resume() {
    _missedWake?.cancel();
    _missedWake = null;
    _resumeFromSleep();
  }
}
