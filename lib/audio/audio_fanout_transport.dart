import 'dart:typed_data';

import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

typedef AudioGroupSinkFailure = void Function(String sinkPeerId, Object error);

abstract class AudioGroupPacketTransport {
  void send(AudioGroupPacketFrame packet);

  Future<void> close();
}

class AudioGroupPacketByteTransport implements AudioGroupPacketTransport {
  AudioGroupPacketByteTransport({
    required void Function(Uint8List bytes) sendBytes,
    Future<void> Function()? closeSink,
  }) : _inner = PacketByteTransport(
          sendBytes: (bytes) => sendBytes(bytes as Uint8List),
          closeSink: closeSink ?? () async {},
        );

  final PacketByteTransport _inner;

  @override
  void send(AudioGroupPacketFrame packet) {
    if (_inner.isClosed) {
      return;
    }
    _inner.send(packet.encode());
  }

  @override
  Future<void> close() => _inner.close();
}

class AudioGroupWebSocketPacketTransport extends AudioGroupPacketByteTransport {
  AudioGroupWebSocketPacketTransport._(PacketByteTransport channelTransport)
      : super(
          sendBytes: (bytes) => channelTransport.send(bytes),
          closeSink: channelTransport.close,
        );

  static Future<AudioGroupWebSocketPacketTransport> connect(Uri uri) async {
    final channelTransport = await connectPacketWebSocket(uri);
    return AudioGroupWebSocketPacketTransport._(channelTransport);
  }
}

class AudioFanoutTransport {
  AudioFanoutTransport({
    required AudioGroupSinkFailure onSinkFailure,
  }) : _onSinkFailure = onSinkFailure;

  final AudioGroupSinkFailure _onSinkFailure;
  final Map<String, AudioGroupPacketTransport> _transports =
      <String, AudioGroupPacketTransport>{};

  Set<String> get sinkPeerIds => Set<String>.unmodifiable(_transports.keys);

  void attach(String sinkPeerId, AudioGroupPacketTransport transport) {
    if (sinkPeerId.isEmpty) {
      return;
    }
    _transports[sinkPeerId] = transport;
  }

  void detach(String sinkPeerId) {
    _transports.remove(sinkPeerId);
  }

  Future<void> detachAndClose(String sinkPeerId) async {
    final transport = _transports.remove(sinkPeerId);
    await transport?.close();
  }

  void send(AudioGroupPacketFrame packet) {
    final entries = _transports.entries.toList(growable: false);
    for (final entry in entries) {
      try {
        entry.value.send(packet);
      } catch (error) {
        _transports.remove(entry.key);
        _onSinkFailure(entry.key, error);
      }
    }
  }

  Future<void> closeAll() async {
    final transports = _transports.values.toList(growable: false);
    _transports.clear();
    for (final transport in transports) {
      await transport.close();
    }
  }
}
