import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_protocol.dart';

typedef AudioGroupSinkFailure = void Function(String sinkPeerId, Object error);

abstract class AudioGroupPacketTransport {
  void send(AudioGroupPacketFrame packet);

  Future<void> close();
}

class AudioGroupPacketByteTransport implements AudioGroupPacketTransport {
  AudioGroupPacketByteTransport({
    required void Function(Uint8List bytes) sendBytes,
    Future<void> Function()? closeSink,
  })  : _sendBytes = sendBytes,
        _closeSink = closeSink;

  final void Function(Uint8List bytes) _sendBytes;
  final Future<void> Function()? _closeSink;
  bool _closed = false;

  @override
  void send(AudioGroupPacketFrame packet) {
    if (_closed) {
      return;
    }
    _sendBytes(packet.encode());
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _closeSink?.call();
  }
}

class AudioGroupWebSocketPacketTransport extends AudioGroupPacketByteTransport {
  AudioGroupWebSocketPacketTransport._(WebSocketChannel channel)
      : _channel = channel,
        super(
          sendBytes: channel.sink.add,
          closeSink: () => channel.sink.close(),
        );

  final WebSocketChannel _channel;

  static Future<AudioGroupWebSocketPacketTransport> connect(Uri uri) async {
    final channel = IOWebSocketChannel.connect(uri);
    await channel.ready;
    return AudioGroupWebSocketPacketTransport._(channel);
  }

  Stream<dynamic> get stream => _channel.stream;
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
