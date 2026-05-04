import 'dart:convert';
import 'dart:typed_data';

enum AudioCodecKind {
  opus,
  pcmS16le,
}

enum AudioTransport {
  websocket,
  udp,
}

enum AudioControlAction {
  offer,
  accept,
  reject,
  stop,
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
      codec: _enumByName(
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
    this.errorMessage = '',
  });

  final AudioControlAction action;
  final String sessionId;
  final String sourcePeerId;
  final String sinkPeerId;
  final AudioStreamFormat? format;
  final AudioTransport transport;
  final String path;
  final String errorMessage;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'action': action.name,
        'sessionId': sessionId,
        'sourcePeerId': sourcePeerId,
        'sinkPeerId': sinkPeerId,
        if (format != null) 'format': format!.toJson(),
        'transport': transport.name,
        'path': path,
        'errorMessage': errorMessage,
      };

  factory AudioControlMessage.fromJson(Map<String, dynamic> json) {
    final formatJson = json['format'];
    return AudioControlMessage(
      action: _enumByName(
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
      transport: _enumByName(
        AudioTransport.values,
        json['transport'] as String?,
        AudioTransport.websocket,
      ),
      path: json['path'] as String? ?? '',
      errorMessage: json['errorMessage'] as String? ?? '',
    );
  }
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
    final header = utf8.encode(jsonEncode(<String, dynamic>{
      'sessionId': sessionId,
      'sequence': sequence,
      'captureTimeMicros': captureTimeMicros,
      'payloadLength': payload.length,
    }));
    final headerLength = ByteData(4)..setUint32(0, header.length);
    final bytes = BytesBuilder(copy: false)
      ..add(ascii.encode(magic))
      ..add(headerLength.buffer.asUint8List())
      ..add(header)
      ..add(payload);
    return bytes.takeBytes();
  }

  factory AudioPacketFrame.decode(Uint8List bytes) {
    if (bytes.length < 8) {
      throw const FormatException('audio packet frame too short');
    }
    final actualMagic = ascii.decode(bytes.sublist(0, 4), allowInvalid: false);
    if (actualMagic != magic) {
      throw const FormatException('invalid audio packet magic');
    }
    final headerLength = ByteData.sublistView(bytes, 4, 8).getUint32(0);
    final headerEnd = 8 + headerLength;
    if (bytes.length < headerEnd) {
      throw const FormatException('audio packet header truncated');
    }
    final header = jsonDecode(
      utf8.decode(bytes.sublist(8, headerEnd)),
    ) as Map<String, dynamic>;
    final payload = Uint8List.sublistView(bytes, headerEnd);
    final expectedLength = header['payloadLength'] as int? ?? -1;
    if (payload.length != expectedLength) {
      throw const FormatException('audio packet payload length mismatch');
    }
    return AudioPacketFrame(
      sessionId: header['sessionId'] as String? ?? '',
      sequence: header['sequence'] as int? ?? 0,
      captureTimeMicros: header['captureTimeMicros'] as int? ?? 0,
      payload: payload,
    );
  }
}

T _enumByName<T extends Enum>(
  List<T> values,
  String? name,
  T fallback,
) {
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  return fallback;
}
