import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../window_stream/android/agent/agent_control_client.dart';
import '../../../window_stream/android/agent/agent_link.dart';
import '../../../window_stream/android/agent/phone_agent_link.dart';
import '../../../window_stream/android/agent/phone_self_start.dart';

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
/// whisper-agent is running, starting it without a computer through
/// [PhoneSelfStart], stopping it, and the deep links that guide the one-time
/// setup. The agent itself is reached through [PhoneAgentLink].
class AndroidWindowServiceController extends ChangeNotifier {
  AndroidWindowServiceController({MethodChannel? agentChannel})
    : _agent = agentChannel ?? _defaultAgent;

  static const _defaultAgent = MethodChannel(
    'com.vireen.whisper/window_stream_agent',
  );

  final MethodChannel _agent;
  final PhoneSelfStart _selfStart = PhoneSelfStart.shared;

  AndroidWindowServiceState _state = AndroidWindowServiceState.working;
  AndroidWindowServiceState get state => _state;

  bool _autoStart = false;
  bool get autoStart => _autoStart;

  /// Whether this phone can start the agent by itself (Android 12 or later).
  bool _canSelfStart = false;
  bool get canSelfStart => _canSelfStart;

  bool _busy = false;
  bool get busy => _busy;

  PhoneSelfStartStatus _status = const PhoneSelfStartStatus();
  PhoneSelfStartStatus get status => _status;

  /// A start from the notification, for the page to report.
  Stream<PhoneSelfStartResult> get finished => _selfStart.finished.stream;

  StreamSubscription<AgentLinkInfo?>? _linkChanges;
  StreamSubscription<PhoneSelfStartResult>? _finished;

  Future<void> init() async {
    _linkChanges ??= PhoneAgentLink.changes.listen((_) => unawaited(refresh()));
    _finished ??= finished.listen((_) => unawaited(refresh()));
    _canSelfStart = await _selfStart.available();
    _autoStart = await _selfStart.autoStart();
    await refresh();
  }

  /// Looks at the remembered link and whether the agent answers on it. Paired
  /// before with no agent now is "stopped": starting it takes one tap.
  Future<void> refresh() async {
    if (!Platform.isAndroid) {
      _set(AndroidWindowServiceState.needsSetup);
      return;
    }
    _status = await _selfStart.status();
    final link = await PhoneAgentLink.current();
    if (link != null && await _selfStart.answers(link)) {
      _set(AndroidWindowServiceState.running);
      return;
    }
    _set(
      link != null || _status.paired
          ? AndroidWindowServiceState.stopped
          : AndroidWindowServiceState.needsSetup,
    );
    notifyListeners();
  }

  Future<void> openDeviceInfo() => _open('openDeviceInfo');

  /// Puts the code entry in a notification, then opens the system's page that
  /// shows the code.
  Future<void> openWirelessDebugging(Map<String, String> strings) async {
    await _selfStart.beginPairing(strings);
    if (!await _selfStart.openWirelessDebugging()) {
      await _open('openDeveloperOptions');
    }
  }

  Future<void> _open(String method) async {
    try {
      await _agent.invokeMethod<void>(method);
    } on PlatformException {
      // Nothing to open; the page still explains the steps.
    }
  }

  /// Pairs with this phone's own adb using the 6-digit [code] the system
  /// shows, then starts the agent.
  Future<PhoneSelfStartResult> pairAndStart(String code) =>
      _whileBusy(() => _selfStart.pairAndStart(code));

  /// Starts the agent again after it was set up once.
  Future<PhoneSelfStartResult> start() => _whileBusy(_selfStart.startTurningOn);

  Future<void> openDeveloperOptions() => _open('openDeveloperOptions');

  Future<PhoneSelfStartResult> _whileBusy(
    Future<PhoneSelfStartResult> Function() work,
  ) async {
    if (_busy) {
      return PhoneSelfStartResult.failed;
    }
    _busy = true;
    _set(AndroidWindowServiceState.working);
    try {
      return await work();
    } finally {
      _busy = false;
      await refresh();
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

  /// False when it couldn't be turned on: it needs a working connection to
  /// the phone's own adb.
  Future<bool> setAutoStart(bool value) async {
    _autoStart = await _selfStart.setAutoStart(value);
    notifyListeners();
    return _autoStart == value;
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
    unawaited(_finished?.cancel());
    super.dispose();
  }
}
