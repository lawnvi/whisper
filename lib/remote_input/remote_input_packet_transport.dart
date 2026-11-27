import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/remote_input/remote_input_activity.dart';
import 'package:whisper/remote_input/remote_input_datagrams.dart';
import 'package:whisper/remote_input/remote_input_lane.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/bounded_outbound_queue.dart';
import 'package:whisper/socket/media_channel_dial.dart';
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
    this.preserveMouseMoves = false,
  }) : _inner = PacketByteTransport(
         sendBytes: (bytes) => sendBytes(bytes as Uint8List),
         closeSink: closeSink ?? () async {},
       );

  RemoteInputPacketByteTransport.withTransport(
    PacketByteTransport transport, {
    this.preserveMouseMoves = false,
  }) : _inner = transport;

  final PacketByteTransport _inner;
  // Manual relative movement is already accumulated before transport; replacing
  // it here would lose displacement and cross click/drag boundaries.
  final bool preserveMouseMoves;

  @override
  void send(RemoteInputPacketFrame packet) {
    if (_inner.isClosed) {
      return;
    }
    if (packet.eventType != RemoteInputEventType.heartbeat) {
      RemoteInputActivity.note();
    }
    final kind = switch (packet.eventType) {
      RemoteInputEventType.mouseMove =>
        preserveMouseMoves
            ? OutboundPacketKind.key
            : OutboundPacketKind.mouseMove,
      RemoteInputEventType.mouseWheel => OutboundPacketKind.scroll,
      RemoteInputEventType.mouseButton => OutboundPacketKind.button,
      RemoteInputEventType.key ||
      RemoteInputEventType.textCommit ||
      RemoteInputEventType.heartbeat ||
      RemoteInputEventType.modifiers => OutboundPacketKind.key,
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
    PacketByteTransport transport, {
    bool preserveMouseMoves = false,
  }) : _stream = incoming.asBroadcastStream(),
       super.withTransport(transport, preserveMouseMoves: preserveMouseMoves) {
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
    bool preserveMouseMoves = false,
  }) => RemoteInputWebSocketPacketTransport.forStreams(
    incoming: channel.stream,
    addStream: channel.sink.addStream,
    closeSink: () => channel.sink.close(),
    maxItems: maxItems,
    maxBytes: maxBytes,
    packetEncoder: packetEncoder,
    preserveMouseMoves: preserveMouseMoves,
  );

  factory RemoteInputWebSocketPacketTransport.forStreams({
    required Stream<dynamic> incoming,
    required Future<void> Function(Stream<Object>) addStream,
    required Future<void> Function() closeSink,
    int maxItems = 128,
    int maxBytes = 256 * 1024,
    AuthenticatedMediaPacketEncoder? packetEncoder,
    bool preserveMouseMoves = false,
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
      preserveMouseMoves: preserveMouseMoves,
    );
    return transport;
  }

  /// Connects for the session [accept] answers, with the UDP lane beside
  /// it when the accept named a port (`remote_input_lane.dart`).
  static Future<RemoteInputObservablePacketTransport> connect(
    Uri uri, {
    required Uint8List mediaMacKey,
    required RemoteInputControlMessage accept,
    bool preserveMouseMoves = false,
  }) async {
    final transport = await _connectSocket(
      uri,
      mediaMacKey: mediaMacKey,
      sessionId: accept.sessionId,
      peerId: accept.sourcePeerId,
      preserveMouseMoves: preserveMouseMoves,
    );
    final lane = preserveMouseMoves
        ? null
        : RemoteInputDatagrams.dial(
            uri: uri,
            mediaKey: mediaMacKey,
            accept: accept,
          );
    return lane == null
        ? transport
        : RemoteInputLaneTransport(transport, lane, report: true);
  }

  static Future<RemoteInputWebSocketPacketTransport> _connectSocket(
    Uri uri, {
    required Uint8List mediaMacKey,
    required String sessionId,
    required String peerId,
    bool preserveMouseMoves = false,
  }) async {
    final channel = await dialMediaChannel(
      uri,
      MediaRoute.input,
      sessionId: sessionId,
      proverPeerId: peerId,
      proofKey: mediaMacKey,
    );
    return RemoteInputWebSocketPacketTransport.forChannel(
      channel,
      packetEncoder: MediaRoute.input.encoder(
        uri,
        sessionId: sessionId,
        sendKey: mediaMacKey,
        maxPayloadBytes: 64 * 1024,
      ),
      preserveMouseMoves: preserveMouseMoves,
    );
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
