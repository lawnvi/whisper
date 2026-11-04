import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:whisper/audio/audio_failure_reason.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_group_session.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/macos_permissions.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/sound/sound_rules.dart';
import 'package:whisper/socket/svrmanager.dart';

/// What the sound page needs from outside, so that it can be tested without a
/// network. [SoundBackend.live] is the real thing.
class SoundBackend {
  const SoundBackend({
    required this.isConnected,
    required this.supportsGroupSink,
    required this.canRejoinFrom,
    required this.sendGroupControl,
    required this.sendSingleControl,
    required this.deviceFor,
    required this.selfPeerId,
    required this.captureDenied,
    required this.requestCapture,
    required this.loadGain,
    required this.saveGain,
    this.permissions,
  });

  factory SoundBackend.live() {
    final socket = WsSvrManager();
    return SoundBackend(
      isConnected: socket.isConnectedTo,
      supportsGroupSink: socket.supportsAudioGroupSinkFor,
      canRejoinFrom: (peerId) =>
          peerId.isNotEmpty &&
          socket.remoteProfileFor(peerId)?.capabilities.audioGroupRejoinV1 ==
              true,
      sendGroupControl: (peerId, control) =>
          unawaited(socket.sendAudioGroupControlTo(peerId, control)),
      sendSingleControl: (peerId, control) =>
          unawaited(socket.sendAudioControlTo(peerId, control)),
      deviceFor: (peerId) => socket.remoteProfileFor(peerId)?.device,
      selfPeerId: () async => (await LocalSetting().instance()).uid,
      captureDenied: () =>
          MacPermissions.supported &&
          MacPermissions.shared.stateOf(MacPermission.screenRecording) ==
              MacPermissionState.denied,
      requestCapture: () =>
          MacPermissions.shared.request(MacPermission.screenRecording),
      loadGain: LocalSetting().audioSharePlaybackGain,
      saveGain: LocalSetting().setAudioSharePlaybackGain,
      permissions: MacPermissions.supported ? MacPermissions.shared : null,
    );
  }

  final bool Function(String peerId) isConnected;
  final bool Function(String peerId) supportsGroupSink;
  final bool Function(String peerId) canRejoinFrom;
  final AudioGroupControlSender sendGroupControl;
  final void Function(String peerId, AudioControlMessage control)
  sendSingleControl;
  final DeviceData? Function(String peerId) deviceFor;
  final Future<String> Function() selfPeerId;

  /// macOS: Screen & System Audio Recording has been refused.
  final bool Function() captureDenied;
  final Future<void> Function() requestCapture;
  final Future<double> Function() loadGain;
  final Future<void> Function(double gain) saveGain;

  /// Told when [captureDenied] may have changed.
  final Listenable? permissions;
}

/// One line of the list, as `surfaces.md`「声音」 describes it.
enum SoundRowPhase {
  /// Connected, not checked: only its name.
  idle,

  /// Connected, not checked, cannot join a group: "只能单独放".
  soloOnly,

  /// Nearby but not connected, dimmed.
  notConnected,

  /// Checked, while the master switch is off.
  stopped,
  connecting,
  calibrating,
  good,
  fair,
  unstable,
  failed,
  disconnected,

  /// Checked and playing one to one, which measures no sync.
  soloPlaying,
}

@immutable
class SoundRow {
  const SoundRow({
    required this.device,
    required this.phase,
    required this.checked,
    required this.channel,
    this.sink,
    this.failure,
  });

  final DeviceData device;
  final SoundRowPhase phase;
  final bool checked;

  /// Null when it has no channel control: not checked, or one to one.
  final AudioChannelRole? channel;

  /// The numbers, while it is in a group.
  final AudioGroupSink? sink;
  final AudioFailureReason? failure;

  bool get connected => phase != SoundRowPhase.notConnected;

  /// Whether it should be counted as playing, for the title.
  bool get live => switch (phase) {
    SoundRowPhase.connecting ||
    SoundRowPhase.calibrating ||
    SoundRowPhase.good ||
    SoundRowPhase.fair ||
    SoundRowPhase.unstable ||
    SoundRowPhase.soloPlaying => true,
    _ => false,
  };

  /// The second line holds numbers rather than a word.
  bool get showsNumbers => switch (phase) {
    SoundRowPhase.connecting ||
    SoundRowPhase.calibrating ||
    SoundRowPhase.good ||
    SoundRowPhase.fair ||
    SoundRowPhase.unstable => true,
    _ => false,
  };

  bool get hasNumbers => switch (phase) {
    SoundRowPhase.good || SoundRowPhase.fair || SoundRowPhase.unstable => true,
    _ => false,
  };
}

/// This device is playing another device's sound.
enum SoundSinkPhase { playing, paused, resuming }

@immutable
class SoundSinkView {
  const SoundSinkView({
    required this.sourcePeerId,
    required this.phase,
    required this.canPause,
    required this.canResume,
  });

  final String sourcePeerId;
  final SoundSinkPhase phase;

  /// `surfaces.md`「接收端的细节」: what is offered depends on the source. A
  /// button that cannot work is not drawn.
  final bool canPause, canResume;
}

/// One state for the sound page, the device card and the tray. Which devices
/// are checked outlives a stopped group, so the master switch can turn sharing
/// off and on again without losing them. That choice is UI state, it is not in
/// any coordinator.
class ShellSoundController extends ChangeNotifier {
  ShellSoundController({
    required AudioGroupCoordinator group,
    required AudioShareCoordinator single,
    required SoundBackend backend,
    AudioPlatform? platform,
  }) : _group = group,
       _single = single,
       _backend = backend,
       _platform = platform ?? AudioPlatform.shared {
    _group.addListener(_sync);
    _single.addListener(_sync);
    _sync();
  }

  static final ShellSoundController shared = ShellSoundController(
    group: AudioGroupCoordinator.shared,
    single: AudioShareCoordinator.shared,
    backend: SoundBackend.live(),
  );

  final AudioGroupCoordinator _group;
  final AudioShareCoordinator _single;
  final SoundBackend _backend;
  final AudioPlatform _platform;

  final SoundMembers _members = SoundMembers();
  bool _on = false;
  String _soloPeer = '';
  bool _wasLive = false;
  int _applying = 0;
  Future<void> _queue = Future<void>.value();
  AudioFailureReason? _failure;

  bool _resuming = false;
  Timer? _resumeTimeout;
  double _gain = 1;
  bool _gainLoaded = false;
  int _attached = 0;

  /// The devices checked and their channels.
  Map<String, AudioChannelRole> get selection => _members.roles;

  bool isSelected(String peerId) => _members.contains(peerId);

  /// Sound is going there, or on its way: checked is not enough, the other
  /// device may have stopped playing it.
  bool isSending(String peerId) {
    if (!on || !_members.contains(peerId)) return false;
    if (peerId == _soloPeer) return _singleLive;
    final sink = _group.session?.sinks[peerId];
    return sink == null ? _backend.isConnected(peerId) : !sink.isTerminal;
  }

  /// A device stopped playing this one's sound from its own side.
  ValueChanged<String>? onMemberStopped;
  Map<String, AudioGroupSinkState> _sinkStates = const {};

  AudioChannelRole? channelOf(String peerId) => _members.roleOf(peerId);

  /// The master switch.
  bool get on => _on && !permissionNeeded;

  /// Is it shown at all: only once there are members.
  bool get hasMembers => !_members.isEmpty;

  bool get permissionNeeded =>
      _backend.captureDenied() ||
      _group.captureFailure == AudioFailureReason.permission;

  /// A failure of this device's own, not of a member's.
  AudioFailureReason? get failure {
    final capture = _group.captureFailure;
    if (capture != null && capture != AudioFailureReason.permission) {
      return capture;
    }
    return _failure;
  }

  double get gain => _gain;

  DeviceData? deviceFor(String peerId) => _backend.deviceFor(peerId);

  /// The page is on screen: read what it shows, keep macOS's answer fresh.
  void attach() {
    if (_attached++ == 0) _backend.permissions?.addListener(_permissionChanged);
    if (!_gainLoaded) {
      _gainLoaded = true;
      unawaited(
        _backend.loadGain().then((gain) {
          _gain = gain;
          notifyListeners();
        }),
      );
    }
  }

  void detach() {
    if (--_attached == 0) {
      _backend.permissions?.removeListener(_permissionChanged);
    }
  }

  // ---- This device as the source ----

  /// Check or uncheck a device. Checking starts playing: there is no separate
  /// start. An old device plays one to one, so checking one replaces the others
  /// and checking another device replaces it.
  Future<void> toggle(String peerId) => _run(() async {
    if (sinkView != null) return;
    if (_members.contains(peerId)) {
      await _remove(peerId);
    } else {
      await _add(peerId);
    }
  });

  /// For one device's own button, which shows [isSending]: a device that stopped
  /// playing gets the sound again, rather than being unchecked first.
  Future<void> toggleSending(String peerId) => _run(() async {
    if (sinkView != null) return;
    if (isSending(peerId)) {
      await _remove(peerId);
      return;
    }
    if (_members.contains(peerId)) await _remove(peerId);
    await _add(peerId);
  });

  Future<void> setChannel(String peerId, AudioChannelRole role) => _run(
    () async {
      if (!_members.contains(peerId) || _members.roleOf(peerId) == role) return;
      _members.setRole(peerId, role);
      notifyListeners();
      if (_on) await _apply();
    },
  );

  /// Off stops the sound and keeps who was checked. On plays to them again.
  Future<void> setOn(bool on) => _run(() async {
    if (on == _on) return;
    _on = on;
    _failure = null;
    notifyListeners();
    if (on) {
      await _apply();
    } else {
      await _stopAll();
    }
  });

  Future<void> openPermission() => _backend.requestCapture();

  Future<void> _add(String peerId) async {
    _failure = null;
    if (!_backend.supportsGroupSink(peerId)) {
      await _stopAll();
      _members
        ..clear()
        ..add(peerId);
      _soloPeer = peerId;
    } else {
      if (_soloPeer.isNotEmpty) {
        await _stopSolo();
        _members.clear();
        _soloPeer = '';
      }
      _members.add(peerId);
    }
    _on = true;
    notifyListeners();
    await _apply();
  }

  Future<void> _remove(String peerId) async {
    _failure = null;
    final solo = peerId == _soloPeer;
    _members.remove(peerId);
    if (solo) _soloPeer = '';
    final none = _members.isEmpty;
    if (none) _on = false;
    notifyListeners();
    if (solo) {
      await _stopSolo();
    } else if (none) {
      await _stopGroup();
    } else if (_on) {
      await _apply();
    }
  }

  Future<void> _apply() async {
    if (permissionNeeded) return;
    if (_soloPeer.isNotEmpty) {
      await _startSolo(_soloPeer);
      return;
    }
    final sinks = <String, AudioChannelRole>{
      for (final entry in _members.roles.entries)
        if (_backend.isConnected(entry.key)) entry.key: entry.value,
    };
    if (sinks.isEmpty) {
      await _stopGroup();
      return;
    }
    final session = _group.session;
    if (session != null &&
        session.isLive &&
        session.sinks.isNotEmpty &&
        !_sinkMode) {
      await _group.updateGroup(
        sinks: sinks,
        sendControl: _backend.sendGroupControl,
        // Whoever paused on their own device stays paused.
        reofferTerminal: false,
      );
      return;
    }
    _group.startGroup(
      sourcePeerId: await _backend.selfPeerId(),
      sinks: sinks,
      format: AudioShareCoordinator.defaultFormat,
      sendControl: _backend.sendGroupControl,
    );
  }

  Future<void> _startSolo(String peerId) async {
    final state = _single.state;
    if (state.isForPeer(peerId) &&
        state.status != AudioShareRuntimeStatus.failed) {
      return;
    }
    final device = _backend.deviceFor(peerId);
    if (device == null) return;
    await _single.startSharingToConnectedPeer(
      sourcePeerId: await _backend.selfPeerId(),
      sinkPeerId: peerId,
      sinkHost: device.host,
      sinkPort: device.port,
      sendControl: (control) => _backend.sendSingleControl(peerId, control),
    );
  }

  Future<void> _stopAll() async {
    await _stopSolo();
    await _stopGroup();
  }

  Future<void> _stopGroup() async {
    if (_group.session == null || _sinkMode) return;
    await _group.stopGroup(sendControl: _backend.sendGroupControl);
  }

  Future<void> _stopSolo() async {
    final state = _single.state;
    if (state.status == AudioShareRuntimeStatus.idle ||
        state.role == AudioShareRuntimeRole.sink) {
      return;
    }
    final peerId = state.peerId;
    await _single.stopSharing(
      sendControl: (control) => _backend.sendSingleControl(peerId, control),
    );
  }

  /// Changes go one at a time: updating a group awaits, and a second check while
  /// that is under way must not work from a stale group.
  Future<void> _run(Future<void> Function() change) {
    final next = _queue.then((_) async {
      _applying++;
      try {
        await change();
      } catch (error) {
        _failure = audioFailureReasonFor(
          error,
          context: AudioFailureContext.protocol,
        );
      } finally {
        _applying--;
        _sync();
      }
    });
    _queue = next;
    return next;
  }

  bool get _sinkMode => _group.isPlaybackActive || _group.canRejoinAsSink;

  bool get _singleLive =>
      _single.state.role == AudioShareRuntimeRole.source &&
      _single.state.status != AudioShareRuntimeStatus.idle &&
      _single.state.status != AudioShareRuntimeStatus.failed;

  /// Who went from playing to stopped. Only the other device does that: here,
  /// stopping takes the sink or the whole group away.
  void _noticeStoppedMembers(AudioGroupSession? session) {
    final now = <String, AudioGroupSinkState>{
      for (final sink in session?.sinks.values ?? const <AudioGroupSink>[])
        sink.sinkPeerId: sink.state,
    };
    for (final entry in now.entries) {
      final before = _sinkStates[entry.key];
      if (entry.value == AudioGroupSinkState.stopped &&
          before != null &&
          before != AudioGroupSinkState.stopped &&
          before != AudioGroupSinkState.failed) {
        onMemberStopped?.call(entry.key);
      }
    }
    _sinkStates = now;
  }

  void _sync() {
    _noticeStoppedMembers(_sinkMode ? null : _group.session);
    if (_applying == 0) {
      final session = _group.session;
      final groupLive = !_sinkMode && session != null && session.isLive;
      if (groupLive) {
        _members.adopt({
          for (final sink in session.sinks.values)
            sink.sinkPeerId: sink.channelRole,
        }, keep: (peer) => !_backend.isConnected(peer));
        _soloPeer = '';
        _on = true;
      } else if (_singleLive) {
        final peer = _single.state.peerId;
        if (!_members.contains(peer)) {
          _members
            ..clear()
            ..add(peer);
        }
        _soloPeer = peer;
        _on = true;
      } else if (_wasLive &&
          (session == null || session.state == AudioGroupState.stopped)) {
        // Stopped from somewhere else, or every device playing it stopped. Who
        // was checked stays checked. The stopped group stays too: a device that
        // only paused can still ask for the sound again.
        _on = false;
      }
      _wasLive = groupLive || _singleLive;
    }
    if (_group.isPlaybackActive || !_group.canRejoinAsSink) {
      _resuming = false;
      _resumeTimeout?.cancel();
    }
    notifyListeners();
  }

  void _permissionChanged() {
    notifyListeners();
    // Allowed now: what was checked meanwhile starts.
    if (_on && !permissionNeeded && _group.session == null && !_singleLive) {
      unawaited(_run(_apply));
    }
  }

  /// The row for one device. [connected] comes from the device list.
  SoundRow rowFor(DeviceData device, {required bool connected}) {
    final peer = device.uid;
    final group = _backend.supportsGroupSink(peer);
    final checked = _members.contains(peer);
    // A channel only means something between two or more devices.
    final channel =
        checked && group && peer != _soloPeer && _members.length >= 2
        ? _members.roleOf(peer)
        : null;
    SoundRow row(
      SoundRowPhase phase, {
      AudioGroupSink? sink,
      AudioFailureReason? failure,
    }) => SoundRow(
      device: device,
      phase: phase,
      checked: checked,
      channel: channel,
      sink: sink,
      failure: failure,
    );

    if (!connected) return row(SoundRowPhase.notConnected);
    if (!checked) {
      return row(group ? SoundRowPhase.idle : SoundRowPhase.soloOnly);
    }
    if (!_on || permissionNeeded) {
      // Off because that device stopped it, not because of the switch here.
      final left =
          !permissionNeeded &&
          !_sinkMode &&
          _group.session?.sinks[peer]?.state == AudioGroupSinkState.stopped;
      return row(left ? SoundRowPhase.disconnected : SoundRowPhase.stopped);
    }
    if (peer == _soloPeer) {
      final state = _single.state;
      if (state.peerId != peer) return row(SoundRowPhase.connecting);
      if (state.status == AudioShareRuntimeStatus.failed) {
        return row(
          SoundRowPhase.failed,
          failure: audioFailureReasonFromWire(state.errorMessage),
        );
      }
      return row(
        state.isActive ? SoundRowPhase.soloPlaying : SoundRowPhase.connecting,
      );
    }
    final sink = _group.session?.sinks[peer];
    if (sink == null) return row(SoundRowPhase.connecting);
    final phase = switch (soundMemberPhaseOf(sink)) {
      SoundMemberPhase.connecting => SoundRowPhase.connecting,
      SoundMemberPhase.calibrating => SoundRowPhase.calibrating,
      SoundMemberPhase.good => SoundRowPhase.good,
      SoundMemberPhase.fair => SoundRowPhase.fair,
      SoundMemberPhase.unstable => SoundRowPhase.unstable,
      SoundMemberPhase.failed => SoundRowPhase.failed,
      SoundMemberPhase.disconnected => SoundRowPhase.disconnected,
    };
    return row(
      phase,
      sink: sink,
      failure: phase == SoundRowPhase.failed
          ? audioFailureReasonFromWire(sink.lastError)
          : null,
    );
  }

  /// What the header says, from the rows on screen.
  AudioSyncQuality? headerQuality(Iterable<SoundRow> rows) =>
      soundHeaderQuality(
        rows
            .where((row) => row.live && row.sink != null)
            .map(
              (row) => switch (row.phase) {
                SoundRowPhase.good => SoundMemberPhase.good,
                SoundRowPhase.fair => SoundMemberPhase.fair,
                SoundRowPhase.unstable => SoundMemberPhase.unstable,
                SoundRowPhase.calibrating => SoundMemberPhase.calibrating,
                _ => SoundMemberPhase.connecting,
              },
            ),
      );

  // ---- This device playing another's sound ----

  /// Null unless another device's sound is playing here, or was until it was
  /// paused. The rules are the island's (`AudioIslandSource`).
  SoundSinkView? get sinkView {
    if (_group.isPlaybackActive) {
      final source =
          _group.session?.sourcePeerId ?? _group.playbackSourcePeerId;
      return SoundSinkView(
        sourcePeerId: source,
        phase: SoundSinkPhase.playing,
        canPause: true,
        canResume: false,
      );
    }
    if (_group.canRejoinAsSink) {
      final source = _group.rejoinSourcePeerId;
      if (_resuming) {
        return SoundSinkView(
          sourcePeerId: source,
          phase: SoundSinkPhase.resuming,
          canPause: false,
          canResume: _backend.canRejoinFrom(source),
        );
      }
      return SoundSinkView(
        sourcePeerId: source,
        phase: SoundSinkPhase.paused,
        canPause: false,
        canResume: _backend.canRejoinFrom(source),
      );
    }
    final single = _single.state;
    if (single.role == AudioShareRuntimeRole.sink &&
        single.status != AudioShareRuntimeStatus.idle &&
        single.status != AudioShareRuntimeStatus.failed) {
      return SoundSinkView(
        sourcePeerId: single.peerId,
        phase: SoundSinkPhase.playing,
        canPause: false,
        canResume: false,
      );
    }
    return null;
  }

  Future<void> pause() async {
    final control = _platform.onMediaControl;
    if (control != null) {
      // Through the media session bridge, which keeps the media card in step.
      control('pause');
    } else {
      await _group.pausePlaybackAsSink();
    }
  }

  Future<void> resume() async {
    _resuming = true;
    _resumeTimeout?.cancel();
    // Like the media card: if the other device does not play again soon, it is
    // paused again, and resuming is the retry.
    _resumeTimeout = Timer(const Duration(seconds: 10), () {
      _resuming = false;
      notifyListeners();
    });
    notifyListeners();
    final control = _platform.onMediaControl;
    if (control != null) {
      control('resume');
    } else if (!await _group.requestRejoinAsSink()) {
      _resuming = false;
      _resumeTimeout?.cancel();
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    final view = sinkView;
    if (view != null &&
        !_group.isPlaybackActive &&
        !_group.canRejoinAsSink &&
        _single.state.role == AudioShareRuntimeRole.sink) {
      final peer = view.sourcePeerId;
      await _single.stopSharing(
        sendControl: (control) => _backend.sendSingleControl(peer, control),
      );
      return;
    }
    final control = _platform.onMediaControl;
    if (control != null) {
      control('disconnect');
    } else {
      await _group.disconnectPlaybackAsSink();
    }
  }

  /// While the slider moves: heard at once, on either kind of playback.
  void setGain(double gain) {
    _gain = gain;
    _group.updatePlaybackGain(gain);
    _single.updatePlaybackGain(gain);
    notifyListeners();
  }

  /// When the slider is let go.
  Future<void> commitGain(double gain) async {
    setGain(gain);
    await _backend.saveGain(gain);
  }

  @override
  void dispose() {
    _resumeTimeout?.cancel();
    _group.removeListener(_sync);
    _single.removeListener(_sync);
    if (_attached > 0) {
      _backend.permissions?.removeListener(_permissionChanged);
    }
    super.dispose();
  }
}
