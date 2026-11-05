import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../window_stream_log.dart';
import 'agent_control_client.dart';
import 'agent_launch.dart';
import 'agent_link.dart';
import 'agent_wire.dart';
import 'phone_agent_link.dart';

/// How starting the agent from the phone itself went. The agent then serves
/// every viewer, adb or not, until the phone restarts.
enum PhoneSelfStartResult {
  started,

  /// The pairing code was wrong.
  wrongCode,

  /// The system isn't showing a pairing code right now.
  noPairingService,

  /// Wireless debugging is off, or there is no Wi-Fi for it.
  wirelessOff,

  /// adbd doesn't know this phone's key (authorizations revoked, or a reset).
  notPaired,

  failed,
}

/// What the system says about the one-time setup.
class PhoneSelfStartStatus {
  const PhoneSelfStartStatus({
    this.developerOptions = false,
    this.wirelessDebugging = false,
    this.wifi = false,
    this.paired = false,
    this.canToggle = false,
  });

  final bool developerOptions;
  final bool wirelessDebugging;
  final bool wifi;
  final bool paired;

  /// Whisper may turn Wireless debugging on by itself.
  final bool canToggle;
}

/// Starts whisper-agent over this phone's own Wireless debugging, through the
/// same [AgentLaunch] scripts a desktop's adb runs. Pairing can finish in a
/// notification with no page open, so this lives as long as the app.
class PhoneSelfStart {
  PhoneSelfStart._();

  static final PhoneSelfStart shared = PhoneSelfStart._();

  static const _channel = MethodChannel(
    'com.vireen.whisper/window_stream_self_start',
  );

  /// How long a started agent gets to report in through the provider.
  static const _linkWait = Duration(seconds: 8);

  /// How long an agent found running gets: it reports in as it starts, so this
  /// only covers one that a desktop started a moment ago.
  static const _runningLinkWait = Duration(seconds: 2);

  /// How often a viewer that finds no agent may set off an automatic start.
  static const _autoStartGap = Duration(seconds: 30);

  /// The page listens: a start from the notification has finished.
  final finished = StreamController<PhoneSelfStartResult>.broadcast();

  Future<PhoneSelfStartResult>? _running;
  DateTime? _lastAutoStart;
  bool _attached = false;

  /// Hooks up the notification's result and starts the agent if the user
  /// asked for that. Called once when the app comes up.
  void attach() {
    if (_attached || !Platform.isAndroid) {
      return;
    }
    _attached = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'paired') {
        final result = await start();
        await _ask<void>('finishStarting', null, {
          'ok': result == PhoneSelfStartResult.started,
        });
        finished.add(result);
      }
      return null;
    });
    unawaited(autoStartIfWanted());
  }

  Future<bool> available() => _ask<bool>('available', false);

  Future<bool> autoStart() => _ask<bool>('autoStart', false);

  /// Whether automatic start is on afterwards: turning it on needs a working
  /// connection to the phone's own adb, for a permission only the shell gives.
  Future<bool> setAutoStart(bool on) =>
      _ask<bool>('setAutoStart', false, {'on': on});

  Future<PhoneSelfStartStatus> status() async {
    final value = await _ask<Map<Object?, Object?>>('status', const {});
    return PhoneSelfStartStatus(
      developerOptions: value['developerOptions'] == true,
      wirelessDebugging: value['wirelessDebugging'] == true,
      wifi: value['wifi'] == true,
      paired: value['paired'] == true,
      canToggle: value['canToggle'] == true,
    );
  }

  /// Puts the code entry into a notification, so the system's page showing
  /// the code stays open. [strings] holds the notification's words.
  Future<bool> beginPairing(Map<String, String> strings) =>
      _ask<bool>('beginPairing', false, {'strings': strings});

  Future<void> cancelPairing() => _ask<void>('cancelPairing', null);

  Future<bool> openWirelessDebugging() =>
      _ask<bool>('openWirelessDebugging', false);

  /// Pairs using the 6-digit [code], then starts the agent.
  Future<PhoneSelfStartResult> pairAndStart(String code) async {
    try {
      await _channel.invokeMethod<bool>('pair', {'code': code.trim()});
    } on PlatformException catch (error) {
      return _resultOf(error);
    } on MissingPluginException {
      return PhoneSelfStartResult.failed;
    }
    return start();
  }

  /// Starts the agent, or finds it already running. Needs Wireless debugging
  /// on and this phone paired with it.
  Future<PhoneSelfStartResult> start() =>
      _running ??= _start().whenComplete(() => _running = null);

  /// Starts the agent with no one watching, turning Wireless debugging on just
  /// for that if the user allowed it. Does nothing when not asked for.
  Future<void> autoStartIfWanted() async {
    if (!Platform.isAndroid || _running != null) {
      return;
    }
    final now = DateTime.now();
    final last = _lastAutoStart;
    if (last != null && now.difference(last) < _autoStartGap) {
      return;
    }
    _lastAutoStart = now;
    if (!await autoStart()) {
      return;
    }
    final link = await PhoneAgentLink.current();
    if (link != null && await answers(link)) {
      return;
    }
    final result = await startTurningOn();
    WindowStreamLog.write('self-start auto: ${result.name}');
  }

  /// [start], turning Wireless debugging on just for that where Whisper may:
  /// the agent doesn't need it once running, so nothing is left open.
  Future<PhoneSelfStartResult> startTurningOn() async {
    var turnedOn = false;
    try {
      turnedOn =
          await _channel.invokeMethod<bool>('enableWirelessDebugging') ?? false;
    } on PlatformException catch (error) {
      return _resultOf(error);
    } on MissingPluginException {
      return PhoneSelfStartResult.failed;
    }
    final result = await start();
    if (turnedOn) {
      await _ask<void>('restoreWirelessDebugging', null, {'on': false});
    }
    return result;
  }

  Future<PhoneSelfStartResult> _start() async {
    try {
      final sidecar = AgentSidecar.fromJson(
        jsonDecode(
              await rootBundle.loadString(
                'assets/window_stream/whisper-agent.json',
              ),
            )
            as Map<String, dynamic>,
      );
      final probe = AgentLaunch.parseProbe(
        await _shell(AgentLaunch.probeScript(sidecar, withToken: false)),
        sidecar,
      );
      var running = probe.running;
      if (running != null && await _replaceIfOlder(running, sidecar)) {
        running = null;
      }
      if (running != null && !await _waitForLink(_runningLinkWait)) {
        // It runs, but this Whisper can't reach it (the link went with cleared
        // data, say), so nothing here could use or stop it.
        WindowStreamLog.write('self-start: replacing an unreachable agent');
        await _shell(AgentLaunch.killScript(running.pid));
        await PhoneAgentLink.clear();
        running = null;
      }
      if (running == null) {
        if (!probe.jarPresent) {
          await _pushJar(sidecar);
        }
        final started = AgentLaunch.parseStart(
          await _shell(AgentLaunch.startScript(sidecar, withToken: false)),
        );
        if (started == null) {
          return PhoneSelfStartResult.failed;
        }
      }
      if (await _waitForLink()) {
        return PhoneSelfStartResult.started;
      }
      WindowStreamLog.write('self-start failed: the agent never reported in');
      return PhoneSelfStartResult.failed;
    } on PlatformException catch (error) {
      // The code only: native messages may carry addresses or paths.
      WindowStreamLog.write('self-start failed: ${error.code}');
      return _resultOf(error);
    } catch (error) {
      // The page must hear something: a failure here is otherwise silent.
      WindowStreamLog.write('self-start failed: ${error.runtimeType}');
      return PhoneSelfStartResult.failed;
    } finally {
      await _ask<void>('disconnect', null);
    }
  }

  Future<String> _shell(String script) async =>
      await _channel.invokeMethod<String>('shell', {'script': script}) ?? '';

  Future<void> _pushJar(AgentSidecar sidecar) async {
    final data = await rootBundle.load(
      'assets/window_stream/whisper-agent.jar',
    );
    await _channel.invokeMethod<bool>('push', {
      'bytes': Uint8List.sublistView(data),
      'path': sidecar.devicePath,
    });
  }

  /// A running agent of another build gives way when this build's is newer
  /// and nothing streams, as with a desktop's start.
  Future<bool> _replaceIfOlder(
    AgentDaemonState running,
    AgentSidecar ours,
  ) async {
    if (running.jarSha == ours.jarSha256) {
      return false;
    }
    final link = await PhoneAgentLink.current();
    if (link == null) {
      return false;
    }
    try {
      final control = await AgentControlClient.connectLink(
        link,
        timeout: const Duration(seconds: 2),
      );
      try {
        final status = await control.call(
          'status',
          const {},
          const Duration(seconds: 3),
        );
        final streams = status is Map && status['streams'] is int
            ? status['streams'] as int
            : 1;
        if (!AgentLaunch.shouldReplace(running, ours, streams: streams)) {
          return false;
        }
        await control.call('shutdown', const {}, const Duration(seconds: 3));
      } finally {
        await control.close();
      }
    } catch (_) {
      return false;
    }
    await PhoneAgentLink.clear();
    // It releases its displays, then exits.
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final alive = await _shell(
        'tr \'\\0\' \' \' < /proc/${running.pid}/cmdline 2>/dev/null',
      );
      if (!alive.contains('--daemon')) {
        return true;
      }
    }
    return false;
  }

  /// The agent reports in through the provider only the shell can call, which
  /// is why the shell's output can't fake a running agent.
  Future<bool> _waitForLink([Duration wait = _linkWait]) async {
    final deadline = DateTime.now().add(wait);
    while (DateTime.now().isBefore(deadline)) {
      final link = await PhoneAgentLink.current();
      if (link != null && await answers(link)) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  /// Whether the agent behind [link] is there and talking.
  Future<bool> answers(AgentLinkInfo link) async {
    const wait = Duration(seconds: 2);
    try {
      final control = await AgentControlClient.connectLink(link, timeout: wait);
      try {
        return await control.call('hello', const {}, wait) is Map;
      } finally {
        await control.close();
      }
    } catch (_) {
      return false;
    }
  }

  static PhoneSelfStartResult _resultOf(PlatformException error) =>
      switch (error.code) {
        'wrongCode' => PhoneSelfStartResult.wrongCode,
        'noPairingService' => PhoneSelfStartResult.noPairingService,
        'wirelessOff' => PhoneSelfStartResult.wirelessOff,
        'notPaired' => PhoneSelfStartResult.notPaired,
        _ => PhoneSelfStartResult.failed,
      };

  Future<T> _ask<T>(String method, T fallback, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments) ?? fallback;
    } on PlatformException {
      return fallback;
    } on MissingPluginException {
      return fallback;
    }
  }
}
