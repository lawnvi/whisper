import 'package:whisper/audio/audio_protocol.dart';

enum AudioGroupState {
  offering,
  connecting,
  active,
  partial,
  stopping,
  stopped,
  failed,
}

enum AudioGroupSinkState {
  offered,
  accepted,
  connecting,
  active,
  lagging,
  failed,
  stopped,
}

class AudioGroupSink {
  const AudioGroupSink({
    required this.sinkPeerId,
    required this.sessionId,
    required this.channelRole,
    required this.state,
    this.host = '',
    this.port = 0,
    this.clockOffsetMicros = 0,
    this.rttMicros = 0,
    this.jitterMicros = 0,
    this.bufferTargetMicros = 0,
    this.lastPacketSequence = -1,
    this.lastError = '',
  });

  final String sinkPeerId;
  final String sessionId;
  final AudioChannelRole channelRole;
  final AudioGroupSinkState state;
  final String host;
  final int port;
  final int clockOffsetMicros;
  final int rttMicros;
  final int jitterMicros;
  final int bufferTargetMicros;
  final int lastPacketSequence;
  final String lastError;

  bool get isActive => state == AudioGroupSinkState.active;

  bool get isTerminal =>
      state == AudioGroupSinkState.failed ||
      state == AudioGroupSinkState.stopped;

  AudioGroupSink copyWith({
    String? sessionId,
    AudioChannelRole? channelRole,
    AudioGroupSinkState? state,
    String? host,
    int? port,
    int? clockOffsetMicros,
    int? rttMicros,
    int? jitterMicros,
    int? bufferTargetMicros,
    int? lastPacketSequence,
    String? lastError,
  }) {
    return AudioGroupSink(
      sinkPeerId: sinkPeerId,
      sessionId: sessionId ?? this.sessionId,
      channelRole: channelRole ?? this.channelRole,
      state: state ?? this.state,
      host: host ?? this.host,
      port: port ?? this.port,
      clockOffsetMicros: clockOffsetMicros ?? this.clockOffsetMicros,
      rttMicros: rttMicros ?? this.rttMicros,
      jitterMicros: jitterMicros ?? this.jitterMicros,
      bufferTargetMicros: bufferTargetMicros ?? this.bufferTargetMicros,
      lastPacketSequence: lastPacketSequence ?? this.lastPacketSequence,
      lastError: lastError ?? this.lastError,
    );
  }
}

class AudioGroupSession {
  const AudioGroupSession({
    required this.groupId,
    required this.streamId,
    required this.sourcePeerId,
    required this.format,
    required this.state,
    required this.sinks,
    this.startedAtMicros = 0,
    this.targetLatencyMs = 160,
    this.lastError = '',
  });

  factory AudioGroupSession.offering({
    required String groupId,
    required String streamId,
    required String sourcePeerId,
    required AudioStreamFormat format,
    required Map<String, AudioChannelRole> sinks,
    int targetLatencyMs = 160,
  }) {
    final sinkStates = <String, AudioGroupSink>{
      for (final entry in sinks.entries)
        entry.key: AudioGroupSink(
          sinkPeerId: entry.key,
          sessionId: '',
          channelRole: entry.value,
          state: AudioGroupSinkState.offered,
        ),
    };
    return AudioGroupSession(
      groupId: groupId,
      streamId: streamId,
      sourcePeerId: sourcePeerId,
      format: format,
      state: AudioGroupState.offering,
      sinks: Map<String, AudioGroupSink>.unmodifiable(sinkStates),
      targetLatencyMs: targetLatencyMs,
    );
  }

  final String groupId;
  final String streamId;
  final String sourcePeerId;
  final AudioStreamFormat format;
  final AudioGroupState state;
  final Map<String, AudioGroupSink> sinks;
  final int startedAtMicros;
  final int targetLatencyMs;
  final String lastError;

  bool get isLive =>
      state != AudioGroupState.stopped && state != AudioGroupState.failed;

  List<AudioGroupSink> get activeSinks => sinks.values
      .where((sink) => sink.state == AudioGroupSinkState.active)
      .toList(growable: false);

  AudioGroupSession withSink(AudioGroupSink sink) {
    final updated = Map<String, AudioGroupSink>.from(sinks)
      ..[sink.sinkPeerId] = sink;
    return copyWith(
      sinks: updated,
      state: _stateAfterSinkChange(updated),
      lastError: sink.lastError.isEmpty ? lastError : sink.lastError,
    );
  }

  AudioGroupSession markSink(
    String sinkPeerId, {
    AudioGroupSinkState? state,
    String? sessionId,
    AudioChannelRole? channelRole,
    String? host,
    int? port,
    int? clockOffsetMicros,
    int? rttMicros,
    int? jitterMicros,
    int? bufferTargetMicros,
    int? lastPacketSequence,
    String? lastError,
  }) {
    final current = sinks[sinkPeerId];
    if (current == null) {
      return this;
    }
    return withSink(
      current.copyWith(
        state: state,
        sessionId: sessionId,
        channelRole: channelRole,
        host: host,
        port: port,
        clockOffsetMicros: clockOffsetMicros,
        rttMicros: rttMicros,
        jitterMicros: jitterMicros,
        bufferTargetMicros: bufferTargetMicros,
        lastPacketSequence: lastPacketSequence,
        lastError: lastError,
      ),
    );
  }

  AudioGroupSession copyWith({
    AudioGroupState? state,
    Map<String, AudioGroupSink>? sinks,
    int? startedAtMicros,
    int? targetLatencyMs,
    String? lastError,
  }) {
    return AudioGroupSession(
      groupId: groupId,
      streamId: streamId,
      sourcePeerId: sourcePeerId,
      format: format,
      state: state ?? this.state,
      sinks: Map<String, AudioGroupSink>.unmodifiable(sinks ?? this.sinks),
      startedAtMicros: startedAtMicros ?? this.startedAtMicros,
      targetLatencyMs: targetLatencyMs ?? this.targetLatencyMs,
      lastError: lastError ?? this.lastError,
    );
  }

  AudioGroupState _stateAfterSinkChange(Map<String, AudioGroupSink> nextSinks) {
    if (nextSinks.isEmpty) {
      return AudioGroupState.stopped;
    }
    final values = nextSinks.values.toList(growable: false);
    final activeCount =
        values.where((sink) => sink.state == AudioGroupSinkState.active).length;
    final terminalCount = values.where((sink) => sink.isTerminal).length;
    final failedCount =
        values.where((sink) => sink.state == AudioGroupSinkState.failed).length;
    if (activeCount == values.length) {
      return AudioGroupState.active;
    }
    if (activeCount > 0) {
      return AudioGroupState.partial;
    }
    if (terminalCount == values.length) {
      return failedCount > 0 ? AudioGroupState.failed : AudioGroupState.stopped;
    }
    final offeredCount = values
        .where((sink) => sink.state == AudioGroupSinkState.offered)
        .length;
    if (offeredCount == values.length) {
      return AudioGroupState.offering;
    }
    return AudioGroupState.connecting;
  }
}
