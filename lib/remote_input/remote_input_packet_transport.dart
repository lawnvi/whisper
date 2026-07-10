import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/bounded_outbound_queue.dart';
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

  RemoteInputPacketByteTransport.withTransport(PacketByteTransport transport)
      : _inner = transport;

  final PacketByteTransport _inner;

  @override
  void send(RemoteInputPacketFrame packet) {
    if (_inner.isClosed) {
      return;
    }
    final kind = switch (packet.eventType) {
      RemoteInputEventType.mouseMove => OutboundPacketKind.mouseMove,
      RemoteInputEventType.mouseWheel => OutboundPacketKind.scroll,
      RemoteInputEventType.mouseButton => OutboundPacketKind.button,
      RemoteInputEventType.key ||
      RemoteInputEventType.modifiers =>
        OutboundPacketKind.key,
      RemoteInputEventType.release => OutboundPacketKind.release,
    };
    _inner.send(packet.encode(), kind: kind);
  }

  @override
  Future<void> close() => _inner.close();
}

class RemoteInputWebSocketPacketTransport extends RemoteInputPacketByteTransport
    implements RemoteInputObservablePacketTransport {
  RemoteInputWebSocketPacketTransport._(
    Stream<dynamic> incoming,
    PacketByteTransport transport,
  )   : _stream = incoming.asBroadcastStream(),
        super.withTransport(transport) {
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

  factory RemoteInputWebSocketPacketTransport.forChannel(
    WebSocketChannel channel, {
    int maxItems = 128,
    int maxBytes = 256 * 1024,
    AuthenticatedMediaPacketEncoder? packetEncoder,
  }) =>
      RemoteInputWebSocketPacketTransport.forStreams(
        incoming: channel.stream,
        addStream: channel.sink.addStream,
        closeSink: () => channel.sink.close(),
        maxItems: maxItems,
        maxBytes: maxBytes,
        packetEncoder: packetEncoder,
      );

  factory RemoteInputWebSocketPacketTransport.forStreams({
    required Stream<dynamic> incoming,
    required Future<void> Function(Stream<Object>) addStream,
    required Future<void> Function() closeSink,
    int maxItems = 128,
    int maxBytes = 256 * 1024,
    AuthenticatedMediaPacketEncoder? packetEncoder,
  }) {
    late final RemoteInputWebSocketPacketTransport transport;
    transport = RemoteInputWebSocketPacketTransport._(
      incoming,
      PacketByteTransport.remoteInput(
        addStream: addStream,
        closeSink: closeSink,
        maxItems: maxItems,
        maxBytes: maxBytes,
        packetEncoder: packetEncoder,
        onOverflow: () {
          transport._notifyDone();
        },
      ),
    );
    return transport;
  }

  static Future<RemoteInputWebSocketPacketTransport> connect(
    Uri uri, {
    required Uint8List mediaMacKey,
    required String sessionId,
  }) async {
    try {
      final channel = IOWebSocketChannel.connect(uri);
      await channel.ready;
      return RemoteInputWebSocketPacketTransport.forChannel(
        channel,
        packetEncoder: AuthenticatedMediaPacketEncoder(
          route: '/input',
          sessionId: sessionId,
          mediaMacKey: mediaMacKey,
          maxPayloadBytes: 64 * 1024,
        ),
      );
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        error is PacketWebSocketConnectException
            ? error
            : PacketWebSocketConnectException(uri, error),
        stackTrace,
      );
    }
  }

  @override
  Stream<void> get done => _doneController.stream;

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
