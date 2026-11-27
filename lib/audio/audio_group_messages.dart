import 'package:whisper/audio/audio_group_session.dart';
import 'package:whisper/audio/audio_protocol.dart';

/// The control messages a source sends about its group, built in one place.
extension AudioGroupSessionMessages on AudioGroupSession {
  /// An offer of this group's sound to [sinkPeerId] under [sessionId], or with
  /// [action] `groupUpdate` a change to one already playing.
  AudioGroupControlMessage offerTo(
    String sinkPeerId, {
    required String sessionId,
    required AudioChannelRole channelRole,
    required List<String> sinkPeerIds,
    AudioGroupControlAction action = AudioGroupControlAction.groupOffer,
  }) => AudioGroupControlMessage(
    action: action,
    groupId: groupId,
    streamId: streamId,
    sessionId: sessionId,
    sourcePeerId: sourcePeerId,
    sinkPeerId: sinkPeerId,
    sinkPeerIds: sinkPeerIds,
    format: format,
    transport: AudioTransport.websocket,
    path: '/audio',
    channelRole: channelRole,
    targetLatencyMs: targetLatencyMs,
  );

  /// Asks [sink] to dial this device's [port] for its session instead: the
  /// source could not reach the sink (`media_dial_back.dart`).
  AudioGroupControlMessage dialBackFor(
    AudioGroupSink sink, {
    required int port,
  }) => AudioGroupControlMessage(
    action: AudioGroupControlAction.groupDialBack,
    groupId: groupId,
    streamId: streamId,
    sessionId: sink.sessionId,
    sourcePeerId: sourcePeerId,
    sinkPeerId: sink.sinkPeerId,
    channelRole: sink.channelRole,
    targetLatencyMs: targetLatencyMs,
    mediaPort: port,
  );

  /// The end of [sink]'s session in this group.
  AudioGroupControlMessage stopFor(AudioGroupSink sink) =>
      AudioGroupControlMessage(
        action: AudioGroupControlAction.groupStop,
        groupId: groupId,
        streamId: streamId,
        sessionId: sink.sessionId,
        sourcePeerId: sourcePeerId,
        sinkPeerId: sink.sinkPeerId,
        channelRole: sink.channelRole,
        targetLatencyMs: targetLatencyMs,
      );
}

/// Answers about the same group, stream, session and pair of devices.
extension AudioGroupControlReplies on AudioGroupControlMessage {
  /// A stop, for a group the answering side no longer has or has paused.
  AudioGroupControlMessage stopReply() =>
      reply(AudioGroupControlAction.groupStop);

  AudioGroupControlMessage reply(
    AudioGroupControlAction action, {
    String errorMessage = '',
  }) => AudioGroupControlMessage(
    action: action,
    groupId: groupId,
    streamId: streamId,
    sessionId: sessionId,
    sourcePeerId: sourcePeerId,
    sinkPeerId: sinkPeerId,
    channelRole: channelRole,
    targetLatencyMs: targetLatencyMs,
    errorMessage: errorMessage,
  );
}
