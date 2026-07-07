import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

abstract class RemoteInputPacketTransport {
  void send(RemoteInputPacketFrame packet);

  Future<void> close();
}

abstract class RemoteInputObservablePacketTransport
    implements RemoteInputPacketTransport {
  Stream<void> get done;
}

class RemoteInputPacketByteTransport implements RemoteInputPacketTransport {
  RemoteInputPacketByteTransport({
    required void Function(Uint8List bytes) sendBytes,
    Future<void> Function()? closeSink,
  }) : _inner = PacketByteTransport(
          sendBytes: (bytes) => sendBytes(bytes as Uint8List),
          closeSink: closeSink ?? () async {},
        );

  final PacketByteTransport _inner;

  @override
  void send(RemoteInputPacketFrame packet) {
    if (_inner.isClosed) {
      return;
    }
    _inner.send(packet.encode());
  }

  @override
  Future<void> close() => _inner.close();
}

class RemoteInputWebSocketPacketTransport extends RemoteInputPacketByteTransport
    implements RemoteInputObservablePacketTransport {
  RemoteInputWebSocketPacketTransport._(WebSocketChannel channel)
      : _stream = channel.stream.asBroadcastStream(),
        super(
          sendBytes: channel.sink.add,
          closeSink: () => channel.sink.close(),
        ) {
    _streamSubscription = _stream.listen(
      (_) {},
      onError: (_, __) {
        _notifyDone();
      },
      onDone: _notifyDone,
      cancelOnError: false,
    );
  }

  final Stream<dynamic> _stream;
  final StreamController<void> _doneController =
      StreamController<void>.broadcast();
  late final StreamSubscription<dynamic> _streamSubscription;
  bool _doneNotified = false;

  static Future<RemoteInputWebSocketPacketTransport> connect(Uri uri) async {
    final channel = IOWebSocketChannel.connect(uri);
    await channel.ready;
    return RemoteInputWebSocketPacketTransport._(channel);
  }

  @override
  Stream<void> get done => _doneController.stream;

  Stream<dynamic> get stream => _stream;

  void _notifyDone() {
    if (_doneNotified || _doneController.isClosed) {
      return;
    }
    _doneNotified = true;
    _doneController.add(null);
  }

  @override
  Future<void> close() async {
    await _streamSubscription.cancel();
    await super.close();
    if (!_doneController.isClosed) {
      await _doneController.close();
    }
  }
}
