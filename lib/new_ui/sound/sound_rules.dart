import 'package:whisper/audio/audio_group_session.dart';
import 'package:whisper/audio/audio_protocol.dart';

/// What the words beside a member's name say. The thresholds are the ones the
/// old setup panel used (`_audioGroupSyncQualityLabel`).
enum AudioSyncQuality { calibrating, good, fair, unstable }

bool audioSinkHasSyncData(AudioGroupSink sink) =>
    sink.rttMicros > 0 ||
    sink.jitterMicros > 0 ||
    sink.bufferTargetMicros > 0 ||
    sink.latePacketCount > 0 ||
    sink.syncErrorMicros != 0;

AudioSyncQuality audioSyncQualityOf(AudioGroupSink sink) {
  if (!audioSinkHasSyncData(sink)) return AudioSyncQuality.calibrating;
  final errorMs = sink.syncErrorMicros.abs() / 1000;
  final jitterMs = sink.jitterMicros.abs() / 1000;
  final measured = sink.syncErrorMicros != 0;
  if (sink.latePacketCount > 0 || (measured && errorMs > 30) || jitterMs > 20) {
    return AudioSyncQuality.unstable;
  }
  if ((measured && errorMs > 12) || jitterMs > 8) {
    return AudioSyncQuality.fair;
  }
  return AudioSyncQuality.good;
}

/// `surfaces.md`「成员状态」, for a member of a group that is playing.
enum SoundMemberPhase {
  connecting,
  calibrating,
  good,
  fair,
  unstable,
  failed,
  disconnected,
}

SoundMemberPhase soundMemberPhaseOf(AudioGroupSink sink) =>
    switch (sink.state) {
      AudioGroupSinkState.offered ||
      AudioGroupSinkState.accepted ||
      AudioGroupSinkState.connecting => SoundMemberPhase.connecting,
      AudioGroupSinkState.lagging => SoundMemberPhase.unstable,
      AudioGroupSinkState.failed => SoundMemberPhase.failed,
      AudioGroupSinkState.stopped => SoundMemberPhase.disconnected,
      AudioGroupSinkState.active => switch (audioSyncQualityOf(sink)) {
        AudioSyncQuality.calibrating => SoundMemberPhase.calibrating,
        AudioSyncQuality.good => SoundMemberPhase.good,
        AudioSyncQuality.fair => SoundMemberPhase.fair,
        AudioSyncQuality.unstable => SoundMemberPhase.unstable,
      },
    };

/// Who is checked, on which channel. `surfaces.md`「声道默认值」: the first is
/// stereo; a second splits the two into left and right unless somebody has
/// touched a channel; back to stereo at one; from the third on, stereo.
class SoundMembers {
  final Map<String, AudioChannelRole> _roles = {};
  bool _touched = false;

  Map<String, AudioChannelRole> get roles => Map.unmodifiable(_roles);

  bool get touched => _touched;
  bool get isEmpty => _roles.isEmpty;
  int get length => _roles.length;

  bool contains(String peerId) => _roles.containsKey(peerId);

  AudioChannelRole? roleOf(String peerId) => _roles[peerId];

  void add(String peerId) {
    if (_roles.containsKey(peerId)) return;
    if (_roles.length == 1 &&
        !_touched &&
        _roles.values.single == AudioChannelRole.stereo) {
      _roles[_roles.keys.single] = AudioChannelRole.left;
      _roles[peerId] = AudioChannelRole.right;
      return;
    }
    _roles[peerId] = AudioChannelRole.stereo;
  }

  void remove(String peerId) {
    if (_roles.remove(peerId) == null) return;
    if (_roles.isEmpty) {
      _touched = false;
    } else if (_roles.length == 1) {
      // A lone device has no channel to pick: it plays everything.
      _roles[_roles.keys.single] = AudioChannelRole.stereo;
      _touched = false;
    }
  }

  void setRole(String peerId, AudioChannelRole role) {
    if (!_roles.containsKey(peerId) || _roles[peerId] == role) return;
    _roles[peerId] = role;
    _touched = true;
  }

  void clear() {
    _roles.clear();
    _touched = false;
  }

  /// What is really playing wins over what was picked here: the device card,
  /// the tray and the older pages can change a group too. [keep] says which
  /// members to hold on to although the group does not have them, the ones
  /// that have gone away for a moment.
  void adopt(
    Map<String, AudioChannelRole> playing, {
    required bool Function(String peerId) keep,
  }) {
    _roles.removeWhere((peer, _) => !playing.containsKey(peer) && !keep(peer));
    _roles.addAll(playing);
  }
}

/// Milliseconds, with one decimal only when it has one.
String formatAudioMillis(int micros) {
  final ms = micros / 1000;
  if (ms == ms.roundToDouble()) return ms.round().toString();
  return ms.toStringAsFixed(1);
}
