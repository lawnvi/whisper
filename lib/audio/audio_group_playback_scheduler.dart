import 'dart:typed_data';

import 'package:whisper/audio/audio_protocol.dart';

typedef AudioGroupClock = int Function();
typedef AudioGroupPcmWriter = Future<void> Function(
  Int16List pcm,
  int targetPlaybackTimeMicros,
);

class AudioGroupPlaybackReport {
  const AudioGroupPlaybackReport({
    required this.queuedPacketCount,
    required this.latePacketCount,
    required this.nextPacketDelayMicros,
    required this.nextPumpDelayMicros,
    required this.bufferDepthMicros,
  });

  final int queuedPacketCount;
  final int latePacketCount;
  final int nextPacketDelayMicros;
  final int nextPumpDelayMicros;
  final int bufferDepthMicros;
}

class AudioGroupPlaybackScheduler {
  AudioGroupPlaybackScheduler({
    required AudioChannelRole channelRole,
    required int channels,
    required AudioGroupClock clockMicros,
    required AudioGroupPcmWriter writePcm,
    this.lateToleranceMicros = 40000,
    this.startupBufferMicros = 0,
    this.outputLeadMicros = 0,
    this.clockRebaseThresholdMicros = 500000,
    this.requireClockOffsetBeforePlayback = false,
  })  : _channelRole = channelRole,
        _channels = channels <= 0 ? 1 : channels,
        _clockMicros = clockMicros,
        _writePcm = writePcm;

  AudioChannelRole _channelRole;
  final int _channels;
  final AudioGroupClock _clockMicros;
  final AudioGroupPcmWriter _writePcm;
  final int lateToleranceMicros;
  final int startupBufferMicros;
  final int outputLeadMicros;
  final int clockRebaseThresholdMicros;
  final bool requireClockOffsetBeforePlayback;
  final List<_QueuedAudioGroupPacket> _queue = <_QueuedAudioGroupPacket>[];
  static const int _recentLatePacketWindowMicros = 10000000;
  int? _targetClockOffsetMicros;
  final List<int> _latePacketTimestamps = <int>[];

  AudioGroupPlaybackReport get report {
    final now = _clockMicros();
    _pruneLatePacketTimestamps(now);
    final isWaitingForClock =
        requireClockOffsetBeforePlayback && _targetClockOffsetMicros == null;
    final nextPacketDelayMicros = _queue.isEmpty || isWaitingForClock
        ? 0
        : (_queue.first.targetPlaybackTimeMicros - now).clamp(0, 1 << 31);
    final nextPumpDelayMicros = _queue.isEmpty || isWaitingForClock
        ? 0
        : (_queue.first.targetPlaybackTimeMicros - now - outputLeadMicros)
            .clamp(0, 1 << 31);
    final bufferDepthMicros = _queue.isEmpty || isWaitingForClock
        ? 0
        : (_queue.last.targetPlaybackTimeMicros - now).clamp(0, 1 << 31);
    return AudioGroupPlaybackReport(
      queuedPacketCount: _queue.length,
      latePacketCount: _latePacketTimestamps.length,
      nextPacketDelayMicros: nextPacketDelayMicros,
      nextPumpDelayMicros: nextPumpDelayMicros,
      bufferDepthMicros: bufferDepthMicros,
    );
  }

  void updateChannelRole(AudioChannelRole channelRole) {
    _channelRole = channelRole;
  }

  void updateClockOffsetMicros(int clockOffsetMicros) {
    _targetClockOffsetMicros = clockOffsetMicros;
    for (final item in _queue) {
      item.targetPlaybackTimeMicros =
          item.remoteTargetPlaybackTimeMicros + clockOffsetMicros;
    }
    _sortQueue();
  }

  void enqueue(AudioGroupPacketFrame packet, Int16List pcm) {
    final now = _clockMicros();
    final targetPlaybackTimeMicros =
        _localTargetPlaybackTimeMicros(packet, now);
    if (targetPlaybackTimeMicros != null &&
        targetPlaybackTimeMicros + lateToleranceMicros < now) {
      _recordLatePacket(now);
      return;
    }
    _queue.add(
      _QueuedAudioGroupPacket(
        packet: packet,
        remoteTargetPlaybackTimeMicros: packet.targetPlaybackTimeMicros,
        targetPlaybackTimeMicros:
            targetPlaybackTimeMicros ?? packet.targetPlaybackTimeMicros,
        pcm: _applyChannelRole(pcm),
      ),
    );
    _sortQueue();
  }

  Future<void> pump() async {
    final now = _clockMicros();
    if (requireClockOffsetBeforePlayback && _targetClockOffsetMicros == null) {
      return;
    }
    while (_queue.isNotEmpty &&
        _queue.first.targetPlaybackTimeMicros + lateToleranceMicros < now) {
      _queue.removeAt(0);
      _recordLatePacket(now);
    }
    while (_queue.isNotEmpty &&
        _queue.first.targetPlaybackTimeMicros <= now + outputLeadMicros) {
      final item = _queue.removeAt(0);
      await _writePcm(item.pcm, item.targetPlaybackTimeMicros);
    }
  }

  int? _localTargetPlaybackTimeMicros(
    AudioGroupPacketFrame packet,
    int now,
  ) {
    final offset = _targetClockOffsetMicros;
    if (offset != null) {
      return packet.targetPlaybackTimeMicros + offset;
    }
    if (requireClockOffsetBeforePlayback) {
      return null;
    }
    if (startupBufferMicros <= 0) {
      return packet.targetPlaybackTimeMicros;
    }
    final remoteTarget = packet.targetPlaybackTimeMicros;
    final isLate = remoteTarget + lateToleranceMicros < now;
    final isTooFarAhead = remoteTarget - now > clockRebaseThresholdMicros;
    if (!isLate && !isTooFarAhead) {
      return remoteTarget;
    }
    final localTarget = now + startupBufferMicros;
    _targetClockOffsetMicros = localTarget - remoteTarget;
    return localTarget;
  }

  void _sortQueue() {
    _queue.sort((a, b) {
      final targetCompare =
          a.targetPlaybackTimeMicros.compareTo(b.targetPlaybackTimeMicros);
      if (targetCompare != 0) {
        return targetCompare;
      }
      return a.packet.sequence.compareTo(b.packet.sequence);
    });
  }

  void _recordLatePacket(int now) {
    _latePacketTimestamps.add(now);
    _pruneLatePacketTimestamps(now);
  }

  void _pruneLatePacketTimestamps(int now) {
    final threshold = now - _recentLatePacketWindowMicros;
    while (_latePacketTimestamps.isNotEmpty &&
        _latePacketTimestamps.first <= threshold) {
      _latePacketTimestamps.removeAt(0);
    }
  }

  Int16List _applyChannelRole(Int16List pcm) {
    if (_channels != 2 || _channelRole == AudioChannelRole.stereo) {
      return Int16List.fromList(pcm);
    }
    final output = Int16List(pcm.length);
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      final left = pcm[i];
      final right = pcm[i + 1];
      switch (_channelRole) {
        case AudioChannelRole.stereo:
          output[i] = left;
          output[i + 1] = right;
          break;
        case AudioChannelRole.left:
          output[i] = left;
          output[i + 1] = left;
          break;
        case AudioChannelRole.right:
          output[i] = right;
          output[i + 1] = right;
          break;
        case AudioChannelRole.mono:
          final mono = ((left + right) / 2).round().clamp(-32768, 32767);
          output[i] = mono;
          output[i + 1] = mono;
          break;
      }
    }
    return output;
  }
}

class _QueuedAudioGroupPacket {
  _QueuedAudioGroupPacket({
    required this.packet,
    required this.remoteTargetPlaybackTimeMicros,
    required this.targetPlaybackTimeMicros,
    required this.pcm,
  });

  final AudioGroupPacketFrame packet;
  final int remoteTargetPlaybackTimeMicros;
  int targetPlaybackTimeMicros;
  final Int16List pcm;
}
