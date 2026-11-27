import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:whisper/socket/svrmanager.dart';

/// What the system is doing, for subsystems that keep their own devices,
/// clocks or timers across sleep.
enum SystemPowerEvent { willSleep, didWake }

/// Lets peers go before the system sleeps and takes them back once it is
/// awake, and tells [events] listeners about both.
///
/// The native side differs per platform: macOS holds sleep until `willSleep`
/// has been answered (at most 2 seconds), Linux holds it with a logind delay
/// lock for as long, and Windows does not wait for anyone, so there peers may
/// only be let go once the system is awake again.
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

  static final StreamController<SystemPowerEvent> _events =
      StreamController<SystemPowerEvent>.broadcast(sync: true);

  /// Sleep and wake as the system reports them. `willSleep` comes before
  /// peers are let go and `didWake` after they are let back in.
  static Stream<SystemPowerEvent> get events => _events.stream;

  final Future<void> Function() _prepareForSleep;
  final void Function() _resumeFromSleep;
  final MethodChannel _channel;

  /// How long to wait for the wake notice before taking peers back anyway.
  final Duration missedWakeTimeout;

  Timer? _missedWake;

  void attach() {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
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
        _events.add(SystemPowerEvent.willSleep);
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
    _events.add(SystemPowerEvent.didWake);
  }
}
