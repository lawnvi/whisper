import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

abstract class RemoteInputPacketTransport {
  void send(RemoteInputPacketFrame packet);

  Future<void> close();
}

class RemoteInputPacketByteTransport implements RemoteInputPacketTransport {
  RemoteInputPacketByteTransport({
    required void Function(Uint8List bytes) sendBytes,
    Future<void> Function()? closeSink,
  })  : _sendBytes = sendBytes,
        _closeSink = closeSink;

  final void Function(Uint8List bytes) _sendBytes;
  final Future<void> Function()? _closeSink;
  bool _closed = false;

  @override
  void send(RemoteInputPacketFrame packet) {
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

class RemoteInputWebSocketPacketTransport
    extends RemoteInputPacketByteTransport {
  RemoteInputWebSocketPacketTransport._(WebSocketChannel channel)
      : _channel = channel,
        super(
          sendBytes: channel.sink.add,
          closeSink: () => channel.sink.close(),
        );

  final WebSocketChannel _channel;

  static Future<RemoteInputWebSocketPacketTransport> connect(Uri uri) async {
    final channel = IOWebSocketChannel.connect(uri);
    await channel.ready;
    return RemoteInputWebSocketPacketTransport._(channel);
  }

  Stream<dynamic> get stream => _channel.stream;
}
