import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/remote_input/remote_input_activity.dart';
import 'package:whisper/remote_input/remote_input_datagrams.dart';
import 'package:whisper/remote_input/remote_input_lane.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/bounded_outbound_queue.dart';
import 'package:whisper/socket/media_channel_dial.dart';
import 'package:whisper/socket/media_dial_back.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

abstract class RemoteInputPacketTransport {
  void send(RemoteInputPacketFrame packet);

  Future<void> close();
}

abstract class RemoteInputObservablePacketTransport
    implements RemoteInputPacketTransport {
  /// Completes once, with why: [PacketTransportTermination.isUnexpected]
  /// unless this side closed it.
  Future<PacketTransportTermination> get done;
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
    PacketByteTransport transport, {
    bool preserveMouseMoves = false,
  }) : super.withTransport(transport, preserveMouseMoves: preserveMouseMoves);

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
    return RemoteInputWebSocketPacketTransport._(
      PacketByteTransport.remoteInput(
        addStream: addStream,
        closeSink: closeSink,
        incoming: incoming,
        maxItems: maxItems,
        maxBytes: maxBytes,
        packetEncoder: packetEncoder,
      ),
      preserveMouseMoves: preserveMouseMoves,
    );
  }

  /// Asks the controlled side of [accept]'s session to dial this device
  /// instead, set by the server (`media_dial_back.dart`); null: no asking.
  static Future<MediaDialedBack?> Function(RemoteInputControlMessage accept)?
  dialBack;

  /// Connects for the session [accept] answers, with the UDP lane beside
  /// it when the accept named a port (`remote_input_lane.dart`). When that
  /// side cannot be reached at all, it is asked to dial here instead
  /// ([dialBack]); that channel goes without the lane, which would not get
  /// through either.
  static Future<RemoteInputObservablePacketTransport> connect(
    Uri uri, {
    required Uint8List mediaMacKey,
    required RemoteInputControlMessage accept,
    bool preserveMouseMoves = false,
  }) async {
    final RemoteInputWebSocketPacketTransport transport;
    try {
      transport = await _connectSocket(
        uri,
        mediaMacKey: mediaMacKey,
        sessionId: accept.sessionId,
        peerId: accept.sourcePeerId,
        preserveMouseMoves: preserveMouseMoves,
      );
    } catch (error) {
      final ask = dialBack;
      if (ask == null || !mediaPeerUnreachable(error)) rethrow;
      final dialed = await ask(accept);
      if (dialed == null) rethrow;
      return RemoteInputWebSocketPacketTransport.forChannel(
        dialed.channel,
        packetEncoder: dialed.encoder,
        preserveMouseMoves: preserveMouseMoves,
      );
    }
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
  Future<PacketTransportTermination> get done => _inner.done;
}
