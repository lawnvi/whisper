import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../window_stream/android/agent/agent_control_client.dart';
import '../../../window_stream/android/agent/agent_link.dart';
import '../../../window_stream/android/agent/phone_agent_link.dart';
import '../../../window_stream/window_stream_log.dart';

/// Where the on-phone window-flow service is.
enum AndroidWindowServiceState {
  /// Reaching the agent, or starting it.
  working,

  /// The agent is running and this phone can be streamed.
  running,

  /// Set up before (a link is remembered) but the agent is not running now.
  stopped,

  /// Never set up on this phone.
  needsSetup,
}

/// Drives the phone's "window flow service" page: whether the persistent
/// whisper-agent is running, starting it without a computer (the phone's
/// own Wireless debugging), stopping it, and the deep links that guide the
/// one-time setup. The agent itself is reached through [PhoneAgentLink].
class AndroidWindowServiceController extends ChangeNotifier {
  AndroidWindowServiceController({
    MethodChannel? agentChannel,
    MethodChannel? selfStart,
  }) : _agent = agentChannel ?? _defaultAgent,
       _selfStart = selfStart ?? _defaultSelfStart;

  static const _defaultAgent = MethodChannel(
    'com.vireen.whisper/window_stream_agent',
  );
  static const _defaultSelfStart = MethodChannel(
    'com.vireen.whisper/window_stream_self_start',
  );

  final MethodChannel _agent;
  final MethodChannel _selfStart;

  AndroidWindowServiceState _state = AndroidWindowServiceState.working;
  AndroidWindowServiceState get state => _state;

  bool _autoStart = false;
  bool get autoStart => _autoStart;

  /// Whether this build can start the agent from the phone alone.
  bool _canSelfStart = false;
  bool get canSelfStart => _canSelfStart;

  bool _busy = false;
  bool get busy => _busy;

  StreamSubscription<AgentLinkInfo?>? _linkChanges;

  Future<void> init() async {
    _linkChanges ??= PhoneAgentLink.changes.listen((_) => unawaited(refresh()));
    try {
      _canSelfStart = await _selfStart.invokeMethod<bool>('available') ?? false;
      _autoStart = await _selfStart.invokeMethod<bool>('autoStart') ?? false;
    } on PlatformException {
      _canSelfStart = false;
    } on MissingPluginException {
      _canSelfStart = false;
    }
    await refresh();
  }

  /// Looks at the remembered link and whether the agent answers on it.
  Future<void> refresh() async {
    if (!Platform.isAndroid) {
      _set(AndroidWindowServiceState.needsSetup);
      return;
    }
    final link = await PhoneAgentLink.current();
    if (link == null) {
      _set(AndroidWindowServiceState.needsSetup);
      return;
    }
    _set(
      await _reachable(link)
          ? AndroidWindowServiceState.running
          : AndroidWindowServiceState.stopped,
    );
  }

  Future<bool> _reachable(AgentLinkInfo link) async {
    try {
      final control = await AgentControlClient.connectLink(
        link,
        timeout: const Duration(seconds: 2),
      );
      final hello = await control.call('hello', const {});
      await control.close();
      return hello is Map;
    } catch (_) {
      return false;
    }
  }

  Future<void> openDeviceInfo() => _open('openDeviceInfo');
  Future<void> openDeveloperOptions() => _open('openDeveloperOptions');

  Future<void> _open(String method) async {
    try {
      await _agent.invokeMethod<void>(method);
    } on PlatformException {
      // Nothing to open; the page still explains the steps.
    }
  }

  /// Pairs with this phone's own adb using the 6-digit [code] the system
  /// shows, then starts the agent. Returns true on success.
  Future<bool> pairAndStart(String code) async {
    if (_busy) {
      return false;
    }
    _busy = true;
    _set(AndroidWindowServiceState.working);
    try {
      final ok = await _selfStart.invokeMethod<bool>('pairAndStart', {
        'code': code.trim(),
      });
      await refresh();
      return ok == true && _state == AndroidWindowServiceState.running;
    } on PlatformException catch (error) {
      // The code only: native messages may carry addresses or paths.
      WindowStreamLog.write('self-start pair failed: ${error.code}');
      await refresh();
      return false;
    } on MissingPluginException {
      await refresh();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Starts the agent again after it was set up once (Wireless debugging on,
  /// no pairing needed). Returns true on success.
  Future<bool> start() async {
    if (_busy) {
      return false;
    }
    _busy = true;
    _set(AndroidWindowServiceState.working);
    try {
      final ok = await _selfStart.invokeMethod<bool>('start');
      await refresh();
      return ok == true && _state == AndroidWindowServiceState.running;
    } on PlatformException {
      await refresh();
      return false;
    } on MissingPluginException {
      await refresh();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Tells the agent to exit and forgets the link.
  Future<void> stop() async {
    if (_busy) {
      return;
    }
    _busy = true;
    notifyListeners();
    try {
      final link = await PhoneAgentLink.current();
      if (link != null) {
        try {
          final control = await AgentControlClient.connectLink(
            link,
            timeout: const Duration(seconds: 2),
          );
          await control.call('shutdown', const {}, const Duration(seconds: 2));
          await control.close();
        } catch (_) {
          // Already gone.
        }
      }
      await PhoneAgentLink.clear();
    } finally {
      _busy = false;
      await refresh();
    }
  }

  Future<void> setAutoStart(bool value) async {
    try {
      final applied =
          await _selfStart.invokeMethod<bool>('setAutoStart', {'on': value}) ??
          false;
      _autoStart = applied;
    } on PlatformException {
      _autoStart = false;
    } on MissingPluginException {
      _autoStart = false;
    }
    notifyListeners();
  }

  void _set(AndroidWindowServiceState state) {
    if (_state != state) {
      _state = state;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(_linkChanges?.cancel());
    super.dispose();
  }
}
