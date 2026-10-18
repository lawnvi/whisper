import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../audio/audio_group_coordinator.dart';
import '../../../audio/audio_platform.dart';
import '../../../audio/audio_share_coordinator.dart';
import '../../../l10n/app_localizations.dart';
import '../../../socket/svrmanager.dart';
import '../island_activity.dart';
import '../island_views.dart';

enum IslandAudioState { starting, playing, paused, ended }

/// What the speaker can be asked to do.
class IslandAudioActions {
  const IslandAudioActions({
    required this.pause,
    required this.resume,
    required this.disconnect,
  });

  final Future<void> Function()? pause;
  final Future<void> Function()? resume;
  final Future<void> Function() disconnect;
}

/// This device playing another device's sound ("作为扬声器"). Reads the
/// same state the system media card shows and acts through the same path,
/// so the island, the media card and the conversation agree.
class AudioIslandSource extends ChangeNotifier implements IslandSource {
  AudioIslandSource({
    AudioGroupCoordinator? group,
    AudioShareCoordinator? single,
    AudioPlatform? platform,
    String Function(String peerId)? deviceName,
    bool Function(String peerId)? canRejoin,
    IslandClock clock = const IslandClock(),
  }) : _group = group ?? AudioGroupCoordinator.shared,
       _single = single ?? AudioShareCoordinator.shared,
       _platform = platform ?? AudioPlatform.shared,
       _deviceName = deviceName ?? _liveDeviceName,
       _canRejoin = canRejoin ?? _liveCanRejoin,
       _clock = clock {
    _group.addListener(_update);
    _single.addListener(_update);
    _update();
  }

  final AudioGroupCoordinator _group;
  final AudioShareCoordinator _single;
  final AudioPlatform _platform;
  final String Function(String peerId) _deviceName;
  final bool Function(String peerId) _canRejoin;
  final IslandClock _clock;

  static String _liveDeviceName(String peerId) {
    final name = WsSvrManager().remoteProfileFor(peerId)?.device.name.trim();
    return name == null || name.isEmpty ? '' : name;
  }

  static bool _liveCanRejoin(String peerId) =>
      peerId.isNotEmpty &&
      WsSvrManager()
              .remoteProfileFor(peerId)
              ?.capabilities
              .audioGroupRejoinV1 ==
          true;

  int _round = 0;
  IslandAudioState? _state;
  String _peerId = '';
  String _name = '';
  bool _legacy = false;
  DateTime _since = DateTime.fromMillisecondsSinceEpoch(0);
  bool _resuming = false;
  Timer? _resumeTimeout;

  String get _id => 'audio:$_round';

  @override
  List<IslandActivity> get activities {
    final state = _state;
    if (state == null) {
      return const [];
    }
    return [
      IslandActivity(
        id: _id,
        kind: IslandKind.audio,
        status: switch (state) {
          IslandAudioState.starting ||
          IslandAudioState.playing => IslandStatus.live,
          IslandAudioState.paused => IslandStatus.paused,
          IslandAudioState.ended => IslandStatus.ended,
        },
        since: _since,
        presenter: AudioPresenter(
          id: _id,
          device: _name,
          state: state,
          actions: IslandAudioActions(
            pause: !_legacy && state == IslandAudioState.playing
                ? _pause
                : null,
            resume:
                !_legacy &&
                    state == IslandAudioState.paused &&
                    _canRejoin(_peerId)
                ? _resume
                : null,
            disconnect: _disconnect,
          ),
        ),
      ),
    ];
  }

  void _update() {
    IslandAudioState? next;
    var peer = '';
    var legacy = false;
    if (_group.isPlaybackActive) {
      next = IslandAudioState.playing;
      peer = _group.session?.sourcePeerId ?? _group.rejoinSourcePeerId;
      _resuming = false;
      _resumeTimeout?.cancel();
    } else if (_group.canRejoinAsSink) {
      next = _resuming ? IslandAudioState.starting : IslandAudioState.paused;
      peer = _group.rejoinSourcePeerId;
    } else {
      _resuming = false;
      final single = _single.state;
      if (single.role == AudioShareRuntimeRole.sink &&
          single.status != AudioShareRuntimeStatus.idle &&
          single.status != AudioShareRuntimeStatus.failed) {
        next = single.isActive
            ? IslandAudioState.playing
            : IslandAudioState.starting;
        peer = single.peerId;
        legacy = true;
      }
    }
    final before = _state;
    if (next == null) {
      if (before == null || before == IslandAudioState.ended) {
        return;
      }
      // Over: says so a moment, until the island lets it go.
      _state = IslandAudioState.ended;
      notifyListeners();
      return;
    }
    if (before == null || before == IslandAudioState.ended) {
      _round++;
      _since = _clock.now();
    }
    var changed = next != before || legacy != _legacy;
    if (peer.isNotEmpty) {
      changed = changed || peer != _peerId;
      _peerId = peer;
      final name = _deviceName(peer);
      if (name.isNotEmpty && name != _name) {
        _name = name;
        changed = true;
      }
    }
    _legacy = legacy;
    _state = next;
    if (changed) {
      notifyListeners();
    }
  }

  Future<void> _pause() async {
    final control = _platform.onMediaControl;
    if (control != null) {
      // Through the media session bridge, which keeps the media card in
      // step.
      control('pause');
    } else {
      await _group.pausePlaybackAsSink();
    }
  }

  Future<void> _resume() async {
    _resuming = true;
    _resumeTimeout?.cancel();
    // Like the media card: if the other device does not play again soon,
    // it is paused again, and play is the retry.
    _resumeTimeout = Timer(const Duration(seconds: 10), () {
      _resuming = false;
      _update();
    });
    _update();
    final control = _platform.onMediaControl;
    if (control != null) {
      control('resume');
    } else {
      final sent = await _group.requestRejoinAsSink();
      if (!sent) {
        _resuming = false;
        _update();
      }
    }
  }

  Future<void> _disconnect() async {
    if (_legacy) {
      final peer = _single.state.peerId;
      await _single.stopSharing(
        sendControl: (control) =>
            unawaited(WsSvrManager().sendAudioControlTo(peer, control)),
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

  @override
  Stream<String> get spotlights => const Stream<String>.empty();

  @override
  void retired(String id) {
    if (id == _id && _state == IslandAudioState.ended) {
      _state = null;
    }
  }

  @override
  void dismissed(IslandActivity activity) {}

  @override
  void expired(IslandActivity activity) {}

  @override
  void dispose() {
    _resumeTimeout?.cancel();
    _group.removeListener(_update);
    _single.removeListener(_update);
    super.dispose();
  }
}

class AudioPresenter extends IslandPresenter {
  const AudioPresenter({
    required this.id,
    required this.device,
    required this.state,
    required this.actions,
  });

  final String id;
  final String device;
  final IslandAudioState state;
  final IslandAudioActions actions;

  bool get _playing => state == IslandAudioState.playing;

  Color get _tint => switch (state) {
    IslandAudioState.playing || IslandAudioState.starting => IslandColors.live,
    IslandAudioState.paused => IslandColors.paused,
    IslandAudioState.ended => IslandColors.gray,
  };

  String _title(BuildContext context) => device.isEmpty ? 'Whisper' : device;

  String _status(AppLocalizations l10n) => switch (state) {
    IslandAudioState.playing => l10n.audioPlaybackNotificationSubtitle,
    IslandAudioState.starting => l10n.islandAudioStarting,
    IslandAudioState.paused => l10n.islandAudioPaused,
    IslandAudioState.ended => l10n.islandAudioEnded,
  };

  Widget _picture(double size) => switch (state) {
    IslandAudioState.playing => IslandEqualizer(
      playing: true,
      width: size * 0.9,
      height: size * 0.7,
    ),
    IslandAudioState.starting => IslandRing(
      value: null,
      tint: _tint,
      icon: CupertinoIcons.speaker_2_fill,
      size: size,
    ),
    IslandAudioState.paused => Icon(
      CupertinoIcons.pause_fill,
      size: size * 0.7,
      color: _tint,
    ),
    IslandAudioState.ended => Icon(
      CupertinoIcons.speaker_slash_fill,
      size: size * 0.7,
      color: _tint,
    ),
  };

  @override
  Widget compact(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return IslandCompactLine(
      leading: SizedBox.square(
        dimension: 20,
        child: Icon(CupertinoIcons.speaker_2_fill, size: 17, color: _tint),
      ),
      title: _title(context),
      trailing: _playing
          ? const IslandEqualizer(playing: true)
          : Text(_status(l10n), style: IslandText.compactFigure(_tint)),
    );
  }

  @override
  Widget glyph(BuildContext context, double size) => _picture(size);

  List<Widget> _buttons(AppLocalizations l10n, {double size = 32}) {
    final pause = actions.pause;
    final resume = actions.resume;
    return [
      if (pause != null)
        IslandRoundButton(
          icon: CupertinoIcons.pause_fill,
          size: size,
          label: l10n.mediaActionPause,
          onPressed: () => unawaited(pause()),
        ),
      if (resume != null)
        IslandRoundButton(
          icon: CupertinoIcons.play_fill,
          size: size,
          label: l10n.mediaActionPlay,
          tint: IslandColors.live,
          onPressed: () => unawaited(resume()),
        ),
      if (state != IslandAudioState.ended)
        IslandRoundButton(
          icon: CupertinoIcons.xmark,
          size: size,
          label: l10n.mediaActionDisconnect,
          onPressed: () => unawaited(actions.disconnect()),
        ),
    ];
  }

  @override
  Widget featured(BuildContext context, IslandControls controls) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      child: IslandHead(
        leading: IslandTile(tint: _tint, child: _picture(24)),
        title: _title(context),
        subtitle: _status(l10n),
        subtitleColor: state == IslandAudioState.playing ? null : _tint,
        trailing: _buttons(l10n),
      ),
    );
  }

  @override
  Widget row(BuildContext context, IslandControls controls) {
    final l10n = AppLocalizations.of(context)!;
    final buttons = _buttons(l10n, size: 28);
    return IslandRowLine(
      leading: _picture(18),
      title: _title(context),
      status: _status(l10n),
      statusColor: _playing ? null : _tint,
      onTap: () => controls.feature(id),
      trailing: buttons.isEmpty ? null : buttons.first,
    );
  }

  @override
  String describe(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return '${_title(context)}, ${_status(l10n)}';
  }
}
