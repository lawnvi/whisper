import 'dart:typed_data';

import 'package:whisper/socket/framed_packet_codec.dart';

enum AudioCodecKind {
  opus,
  pcmS16le,
}

enum AudioTransport {
  websocket,
  udp,
}

enum AudioChannelRole {
  stereo,
  mono,
  left,
  right,
}

enum AudioChannelMask {
  stereo,
  mono,
  left,
  right,
}

enum AudioControlAction {
  offer,
  accept,
  reject,
  stop,
  error,
}

enum AudioGroupControlAction {
  groupOffer,
  groupAccept,
  groupReject,
  groupUpdate,
  groupStop,
  clockProbe,
  clockReport,
  latencyReport,
  sinkJoinRequest,
  error,
}

class AudioStreamFormat {
  const AudioStreamFormat({
    required this.codec,
    required this.sampleRate,
    required this.channels,
    required this.frameDurationMs,
    required this.bitRate,
  });

  final AudioCodecKind codec;
  final int sampleRate;
  final int channels;
  final int frameDurationMs;
  final int bitRate;

  int get frameSize => sampleRate * frameDurationMs ~/ 1000;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'codec': codec.name,
        'sampleRate': sampleRate,
        'channels': channels,
        'frameDurationMs': frameDurationMs,
        'bitRate': bitRate,
      };

  factory AudioStreamFormat.fromJson(Map<String, dynamic> json) {
    return AudioStreamFormat(
      codec: enumByName(
        AudioCodecKind.values,
        json['codec'] as String?,
        AudioCodecKind.opus,
      ),
      sampleRate: json['sampleRate'] as int? ?? 48000,
      channels: json['channels'] as int? ?? 2,
      frameDurationMs: json['frameDurationMs'] as int? ?? 20,
      bitRate: json['bitRate'] as int? ?? 128000,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AudioStreamFormat &&
        other.codec == codec &&
        other.sampleRate == sampleRate &&
        other.channels == channels &&
        other.frameDurationMs == frameDurationMs &&
        other.bitRate == bitRate;
  }

  @override
  int get hashCode => Object.hash(
        codec,
        sampleRate,
        channels,
        frameDurationMs,
        bitRate,
      );
}

class AudioControlMessage {
  const AudioControlMessage({
    required this.action,
    required this.sessionId,
    required this.sourcePeerId,
    required this.sinkPeerId,
    this.format,
    this.transport = AudioTransport.websocket,
    this.path = '',
    this.transportToken = '',
    this.errorMessage = '',
  });

  final AudioControlAction action;
  final String sessionId;
  final String sourcePeerId;
  final String sinkPeerId;
  final AudioStreamFormat? format;
  final AudioTransport transport;
  final String path;
  final String transportToken;
  final String errorMessage;

  AudioControlMessage withTransportToken(String token) {
    return AudioControlMessage(
      action: action,
      sessionId: sessionId,
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      format: format,
      transport: transport,
      path: path,
      transportToken: token,
      errorMessage: errorMessage,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'action': action.name,
        'sessionId': sessionId,
        'sourcePeerId': sourcePeerId,
        'sinkPeerId': sinkPeerId,
        if (format != null) 'format': format!.toJson(),
        'transport': transport.name,
        'path': path,
        if (action == AudioControlAction.accept && transportToken.isNotEmpty)
          'transportToken': transportToken,
        'errorMessage': errorMessage,
      };

  factory AudioControlMessage.fromJson(Map<String, dynamic> json) {
    final formatJson = json['format'];
    return AudioControlMessage(
      action: enumByName(
        AudioControlAction.values,
        json['action'] as String?,
        AudioControlAction.error,
      ),
      sessionId: json['sessionId'] as String? ?? '',
      sourcePeerId: json['sourcePeerId'] as String? ?? '',
      sinkPeerId: json['sinkPeerId'] as String? ?? '',
      format: formatJson is Map
          ? AudioStreamFormat.fromJson(Map<String, dynamic>.from(formatJson))
          : null,
      transport: enumByName(
        AudioTransport.values,
        json['transport'] as String?,
        AudioTransport.websocket,
      ),
      path: json['path'] as String? ?? '',
      transportToken: _transportTokenFromJson(
        json,
        allowed: json['action'] == AudioControlAction.accept.name,
      ),
      errorMessage: json['errorMessage'] as String? ?? '',
    );
  }
}

class AudioGroupControlMessage {
  const AudioGroupControlMessage({
    required this.action,
    required this.groupId,
    required this.streamId,
    required this.sessionId,
    required this.sourcePeerId,
    required this.sinkPeerId,
    this.sinkPeerIds = const <String>[],
    this.format,
    this.transport = AudioTransport.websocket,
    this.path = '',
    this.transportToken = '',
    this.channelRole = AudioChannelRole.stereo,
    this.targetLatencyMs = 160,
    this.sentAtMicros = 0,
    this.receivedAtMicros = 0,
    this.sinkClockMicros = 0,
    this.playbackCursorMicros = 0,
    this.clockOffsetMicros = 0,
    this.rttMicros = 0,
    this.jitterMicros = 0,
    this.bufferDepthMicros = 0,
    this.latePacketCount = 0,
    this.syncErrorMicros = 0,
    this.errorMessage = '',
  });

  final AudioGroupControlAction action;
  final String groupId;
  final String streamId;
  final String sessionId;
  final String sourcePeerId;
  final String sinkPeerId;
  final List<String> sinkPeerIds;
  final AudioStreamFormat? format;
  final AudioTransport transport;
  final String path;
  final String transportToken;
  final AudioChannelRole channelRole;
  final int targetLatencyMs;
  final int sentAtMicros;
  final int receivedAtMicros;
  final int sinkClockMicros;
  final int playbackCursorMicros;
  final int clockOffsetMicros;
  final int rttMicros;
  final int jitterMicros;
  final int bufferDepthMicros;
  final int latePacketCount;
  final int syncErrorMicros;
  final String errorMessage;

  AudioGroupControlMessage withTransportToken(String token) {
    return AudioGroupControlMessage(
      action: action,
      groupId: groupId,
      streamId: streamId,
      sessionId: sessionId,
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      sinkPeerIds: sinkPeerIds,
      format: format,
      transport: transport,
      path: path,
      transportToken: token,
      channelRole: channelRole,
      targetLatencyMs: targetLatencyMs,
      sentAtMicros: sentAtMicros,
      receivedAtMicros: receivedAtMicros,
      sinkClockMicros: sinkClockMicros,
      playbackCursorMicros: playbackCursorMicros,
      clockOffsetMicros: clockOffsetMicros,
      rttMicros: rttMicros,
      jitterMicros: jitterMicros,
      bufferDepthMicros: bufferDepthMicros,
      latePacketCount: latePacketCount,
      syncErrorMicros: syncErrorMicros,
      errorMessage: errorMessage,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'action': action.name,
        'groupId': groupId,
        'streamId': streamId,
        'sessionId': sessionId,
        'sourcePeerId': sourcePeerId,
        'sinkPeerId': sinkPeerId,
        'sinkPeerIds': sinkPeerIds,
        if (format != null) 'format': format!.toJson(),
        'transport': transport.name,
        'path': path,
        if (action == AudioGroupControlAction.groupAccept &&
            transportToken.isNotEmpty)
          'transportToken': transportToken,
        'channelRole': channelRole.name,
        'targetLatencyMs': targetLatencyMs,
        'sentAtMicros': sentAtMicros,
        'receivedAtMicros': receivedAtMicros,
        'sinkClockMicros': sinkClockMicros,
        'playbackCursorMicros': playbackCursorMicros,
        'clockOffsetMicros': clockOffsetMicros,
        'rttMicros': rttMicros,
        'jitterMicros': jitterMicros,
        'bufferDepthMicros': bufferDepthMicros,
        'latePacketCount': latePacketCount,
        'syncErrorMicros': syncErrorMicros,
        'errorMessage': errorMessage,
      };

  factory AudioGroupControlMessage.fromJson(Map<String, dynamic> json) {
    final formatJson = json['format'];
    return AudioGroupControlMessage(
      action: enumByName(
        AudioGroupControlAction.values,
        json['action'] as String?,
        AudioGroupControlAction.error,
      ),
      groupId: json['groupId'] as String? ?? '',
      streamId: json['streamId'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      sourcePeerId: json['sourcePeerId'] as String? ?? '',
      sinkPeerId: json['sinkPeerId'] as String? ?? '',
      sinkPeerIds: (json['sinkPeerIds'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      format: formatJson is Map
          ? AudioStreamFormat.fromJson(Map<String, dynamic>.from(formatJson))
          : null,
      transport: enumByName(
        AudioTransport.values,
        json['transport'] as String?,
        AudioTransport.websocket,
      ),
      path: json['path'] as String? ?? '',
      transportToken: _transportTokenFromJson(
        json,
        allowed: json['action'] == AudioGroupControlAction.groupAccept.name,
      ),
      channelRole: enumByName(
        AudioChannelRole.values,
        json['channelRole'] as String?,
        AudioChannelRole.stereo,
      ),
      targetLatencyMs: json['targetLatencyMs'] as int? ?? 160,
      sentAtMicros: json['sentAtMicros'] as int? ?? 0,
      receivedAtMicros: json['receivedAtMicros'] as int? ?? 0,
      sinkClockMicros: json['sinkClockMicros'] as int? ?? 0,
      playbackCursorMicros: json['playbackCursorMicros'] as int? ?? 0,
      clockOffsetMicros: json['clockOffsetMicros'] as int? ?? 0,
      rttMicros: json['rttMicros'] as int? ?? 0,
      jitterMicros: json['jitterMicros'] as int? ?? 0,
      bufferDepthMicros: json['bufferDepthMicros'] as int? ?? 0,
      latePacketCount: json['latePacketCount'] as int? ?? 0,
      syncErrorMicros: json['syncErrorMicros'] as int? ?? 0,
      errorMessage: json['errorMessage'] as String? ?? '',
    );
  }
}

String _transportTokenFromJson(
  Map<String, dynamic> json, {
  required bool allowed,
}) {
  final present = json.containsKey('transportToken');
  if (!allowed) {
    if (present) {
      throw const FormatException('unexpected transport token');
    }
    return '';
  }
  final token = json['transportToken'];
  if (token is! String || token.isEmpty) {
    throw const FormatException('missing transport token');
  }
  return token;
}

class AudioPacketFrame {
  AudioPacketFrame({
    required this.sessionId,
    required this.sequence,
    required this.captureTimeMicros,
    required this.payload,
  });

  static const String magic = 'WSA1';

  final String sessionId;
  final int sequence;
  final int captureTimeMicros;
  final Uint8List payload;

  Uint8List encode() {
    return encodeFramedPacket(
      magic: magic,
      header: <String, dynamic>{
        'sessionId': sessionId,
        'sequence': sequence,
        'captureTimeMicros': captureTimeMicros,
        'payloadLength': payload.length,
      },
      payload: payload,
    );
  }

  factory AudioPacketFrame.decode(Uint8List bytes) {
    final decoded = decodeFramedPacket(
      magic: magic,
      label: 'audio packet',
      bytes: bytes,
    );
    final header = decoded.header;
    return AudioPacketFrame(
      sessionId: header['sessionId'] as String? ?? '',
      sequence: header['sequence'] as int? ?? 0,
      captureTimeMicros: header['captureTimeMicros'] as int? ?? 0,
      payload: decoded.payload,
    );
  }
}

class AudioGroupPacketFrame {
  AudioGroupPacketFrame({
    required this.groupId,
    required this.streamId,
    required this.sessionId,
    required this.sourcePeerId,
    required this.sequence,
    required this.captureTimeMicros,
    required this.targetPlaybackTimeMicros,
    required this.durationMicros,
    required this.channelMask,
    required this.payload,
  });

  static const String magic = 'WSG1';

  final String groupId;
  final String streamId;
  final String sessionId;
  final String sourcePeerId;
  final int sequence;
  final int captureTimeMicros;
  final int targetPlaybackTimeMicros;
  final int durationMicros;
  final AudioChannelMask channelMask;
  final Uint8List payload;

  Uint8List encode() {
    return encodeFramedPacket(
      magic: magic,
      header: <String, dynamic>{
        'groupId': groupId,
        'streamId': streamId,
        'sessionId': sessionId,
        'sourcePeerId': sourcePeerId,
        'sequence': sequence,
        'captureTimeMicros': captureTimeMicros,
        'targetPlaybackTimeMicros': targetPlaybackTimeMicros,
        'durationMicros': durationMicros,
        'channelMask': channelMask.name,
        'payloadLength': payload.length,
      },
      payload: payload,
    );
  }

  factory AudioGroupPacketFrame.decode(Uint8List bytes) {
    final decoded = decodeFramedPacket(
      magic: magic,
      label: 'audio group packet',
      bytes: bytes,
    );
    final header = decoded.header;
    return AudioGroupPacketFrame(
      groupId: header['groupId'] as String? ?? '',
      streamId: header['streamId'] as String? ?? '',
      sessionId: header['sessionId'] as String? ?? '',
      sourcePeerId: header['sourcePeerId'] as String? ?? '',
      sequence: header['sequence'] as int? ?? 0,
      captureTimeMicros: header['captureTimeMicros'] as int? ?? 0,
      targetPlaybackTimeMicros: header['targetPlaybackTimeMicros'] as int? ?? 0,
      durationMicros: header['durationMicros'] as int? ?? 0,
      channelMask: enumByName(
        AudioChannelMask.values,
        header['channelMask'] as String?,
        AudioChannelMask.stereo,
      ),
      payload: decoded.payload,
    );
  }
}
