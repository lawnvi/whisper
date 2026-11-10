part of 'audio_media_isolate.dart';

// The messages between the main isolate and the audio isolate: plain data,
// sent through ports.

class _IsolateStart {
  const _IsolateStart(this.main, this.entry);

  final SendPort main;
  final AudioNativeEntryPoints entry;
}

class _ConnectSink {
  const _ConnectSink(
    this.id, {
    required this.sourcePeerId,
    required this.sessionId,
    required this.uri,
    required this.mediaUri,
    required this.transportToken,
    required this.mediaSendKey,
  });

  final int id;
  final String sourcePeerId;
  final String sessionId;
  final Uri uri;
  final Uri? mediaUri;
  final String transportToken;
  final Uint8List? mediaSendKey;
}

class _AttachSink {
  const _AttachSink(this.sinkPeerId, this.linkId);

  final String sinkPeerId;
  final int linkId;
}

class _CloseLink {
  const _CloseLink(this.id, this.linkId);

  final int id;
  final int linkId;
}

class _DisconnectSink {
  const _DisconnectSink(this.id, this.sinkPeerId);

  final int id;
  final String sinkPeerId;
}

class _DisconnectAll {
  const _DisconnectAll(this.id);

  final int id;
}

class _PrepareCapture {
  const _PrepareCapture(this.id, this.captureId, this.spec);

  final int id;
  final int captureId;
  final AudioGroupCaptureSpec spec;
}

class _StopCapture {
  const _StopCapture(this.id, this.captureId);

  final int id;
  final int captureId;
}

class _StartPlayback {
  const _StartPlayback(this.id, this.playbackId, this.spec, this.handle);

  final int id;
  final int playbackId;
  final AudioGroupPlaybackSpec spec;
  final int handle;
}

class _DeliverPacket {
  const _DeliverPacket(this.playbackId, this.bytes);

  final int playbackId;
  final Uint8List bytes;
}

class _PlaybackClock {
  const _PlaybackClock(this.playbackId, this.clockOffsetMicros);

  final int playbackId;
  final int clockOffsetMicros;
}

class _PlaybackRole {
  const _PlaybackRole(this.playbackId, this.channelRole);

  final int playbackId;
  final AudioChannelRole channelRole;
}

class _PlaybackGain {
  const _PlaybackGain(this.playbackId, this.gain);

  final int playbackId;
  final double gain;
}

class _StopPlayback {
  const _StopPlayback(this.id, this.playbackId);

  final int id;
  final int playbackId;
}

class _CloseChannels {
  const _CloseChannels(
    this.id, {
    this.sessionId,
    this.peerId,
    this.namespace,
    this.keepMediaMacKey,
    required this.expected,
  });

  final int id;
  final String? sessionId;
  final String? peerId;
  final String? namespace;
  final Uint8List? keepMediaMacKey;
  final bool expected;
}

class _ClaimData {
  const _ClaimData({
    required this.namespace,
    required this.sessionId,
    required this.peerId,
    required this.connectionGeneration,
    required this.mediaMacKey,
    required this.channelBinding,
  });

  final String namespace;
  final String sessionId;
  final String peerId;
  final int connectionGeneration;
  final Uint8List mediaMacKey;
  final Uint8List channelBinding;
}

class _ClaimAnswer {
  const _ClaimAnswer(this.requestId, this.claim);

  final int requestId;
  final _ClaimData? claim;
}

class _ConsumeAnswer {
  const _ConsumeAnswer(this.requestId, this.consumed);

  final int requestId;
  final bool consumed;
}

class _Reply {
  const _Reply(this.id, {this.value, this.failure});

  final int id;
  final Object? value;
  final AudioFailureReason? failure;
}

class _SinkFailed {
  const _SinkFailed(this.sinkPeerId, this.reason);

  final String sinkPeerId;
  final AudioFailureReason reason;
}

/// A capture is sending: at most every [_IsolateCapture.sentReportMicros].
class _CaptureSent {
  const _CaptureSent(this.captureId, this.sentAtMicros);

  final int captureId;
  final int sentAtMicros;
}

class _PlaybackReported {
  const _PlaybackReported(this.playbackId, this.report);

  final int playbackId;
  final AudioGroupPlaybackReport report;
}

class _PlaybackFailed {
  const _PlaybackFailed(this.playbackId, this.reason);

  final int playbackId;
  final AudioFailureReason reason;
}

class _ClaimLookup {
  const _ClaimLookup(
    this.requestId,
    this.sessionId,
    this.token,
    this.remoteAddress,
  );

  final int requestId;
  final String sessionId;
  final String token;
  final String remoteAddress;
}

class _ClaimConsume {
  const _ClaimConsume(this.requestId);

  final int requestId;
}

class _ClaimRelease {
  const _ClaimRelease(this.requestId);

  final int requestId;
}

class _Log {
  const _Log(this.line);

  final String line;
}
