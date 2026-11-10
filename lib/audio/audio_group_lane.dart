import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:whisper/audio/audio_fanout_transport.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/socket/datagram_endpoint.dart';
import 'package:whisper/socket/datagram_seal.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

/// Sound over UDP beside its WebSocket, in the audio isolate. On a weak
/// link TCP holds every packet behind a lost one until it is sent again,
/// and the sound stops for that long; sound would rather lose a packet.
///
/// A sink listens on the number of its media port, which the source already
/// has from the accept, so nothing new goes on the wire to set this up. A
/// sink of an older version never answers, and the sound stays on the
/// WebSocket. Each datagram carries a packet and the one before it, so one
/// lost on the way still plays from the next; the sink plays each once and
/// fills in what never came (`AudioGroupPlaybackPipeline`).
abstract final class AudioGroupDatagrams {
  static const String namespace = 'audio-group';

  // Static fields belong to their isolate: these are the audio isolate's.
  static DatagramEndpoint? _answering;
  static Future<DatagramEndpoint?>? _dialing;

  /// The sink's socket on [port], its media port; none when that is taken.
  static Future<void> listenAt(int port) async {
    if (_answering?.isClosed == false) return;
    try {
      _answering = await DatagramEndpoint.bind(port: port, exact: true);
    } on Object {
      _answering = null;
    }
  }

  static Future<DatagramEndpoint?> _dialer() => _dialing ??= () async {
    try {
      return await DatagramEndpoint.bind();
    } on Object {
      return null;
    }
  }();

  /// Connects to a sink at [uri] by WebSocket and, when [uri] is the sink's
  /// media port, by UDP to the same port beside it.
  static Future<AudioGroupPacketTransport> connect(
    Uri uri, {
    required Uint8List mediaMacKey,
    required String sessionId,
    required String peerId,
    required bool mediaPort,
  }) async {
    final socket = await AudioGroupWebSocketPacketTransport.connect(
      uri,
      mediaMacKey: mediaMacKey,
      sessionId: sessionId,
      peerId: peerId,
    );
    final address = InternetAddress.tryParse(uri.host);
    final endpoint = mediaPort ? await _dialer() : null;
    if (endpoint == null ||
        address == null ||
        address.type != InternetAddressType.IPv4) {
      return socket;
    }
    final lane = DatagramLane(
      endpoint: endpoint,
      keys: DatagramKeys.derive(
        mediaKey: mediaMacKey,
        channelBinding: mediaPacketChannelBindingFromUri(uri),
        namespace: namespace,
        sessionId: sessionId,
      ),
      dialer: true,
      peer: address,
      peerPort: uri.port,
      onData: (_) {},
    );
    return AudioGroupLaneTransport(socket, lane);
  }

  /// The sink's lane for one session, once its WebSocket is authenticated.
  static DatagramLane? answer({
    required Uint8List mediaKey,
    required Uint8List channelBinding,
    required String sessionId,
    required void Function(AudioGroupPacketFrame packet) onPacket,
  }) {
    final endpoint = _answering;
    if (endpoint == null || endpoint.isClosed) return null;
    return DatagramLane(
      endpoint: endpoint,
      keys: DatagramKeys.derive(
        mediaKey: mediaKey,
        channelBinding: channelBinding,
        namespace: namespace,
        sessionId: sessionId,
      ),
      dialer: false,
      onData: (payload) {
        for (final bytes in unpackAudioDatagram(payload)) {
          final AudioGroupPacketFrame packet;
          try {
            packet = AudioGroupPacketFrame.decode(bytes);
          } on FormatException {
            continue;
          }
          onPacket(packet);
        }
      },
    );
  }
}

/// What a lane datagram can hold: the lane puts one byte before it.
const int _laneRoom = DatagramFormat.maxPayloadBytes - 1;

/// [current] and, when both fit, [previous]: each after its 16-bit length,
/// the older first.
Uint8List? packAudioDatagram(Uint8List current, Uint8List? previous) {
  final both =
      previous != null && 4 + previous.length + current.length <= _laneRoom;
  if (!both && 2 + current.length > _laneRoom) return null;
  final parts = [if (both) previous, current];
  final out = BytesBuilder(copy: false);
  for (final part in parts) {
    out
      ..addByte(part.length >> 8)
      ..addByte(part.length & 0xff)
      ..add(part);
  }
  return out.takeBytes();
}

/// The packets in a datagram, the older first; nothing when it is malformed.
List<Uint8List> unpackAudioDatagram(Uint8List payload) {
  final parts = <Uint8List>[];
  var offset = 0;
  while (offset + 2 <= payload.length && parts.length < 2) {
    final length = payload[offset] << 8 | payload[offset + 1];
    offset += 2;
    if (offset + length > payload.length) return const [];
    parts.add(Uint8List.sublistView(payload, offset, offset + length));
    offset += length;
  }
  return offset == payload.length ? parts : const [];
}

/// The source's side: sound by UDP while the sink answers, else by the
/// WebSocket.
class AudioGroupLaneTransport implements AudioGroupObservablePacketTransport {
  AudioGroupLaneTransport(this._socket, this._lane);

  final AudioGroupObservablePacketTransport _socket;
  final DatagramPath _lane;
  Uint8List? _previous;

  /// Packets sent each way, for diagnostics.
  int byLane = 0, bySocket = 0;

  bool get laneHealthy => _lane.healthy;

  @override
  Future<PacketTransportTermination> get done => _socket.done;

  @override
  Future<PacketSendResult> send(AudioGroupPacketFrame packet) {
    final bytes = packet.encode();
    if (_lane.healthy) {
      final datagram = packAudioDatagram(bytes, _previous);
      if (datagram != null && _lane.send(datagram)) {
        _previous = bytes;
        byLane += 1;
        return Future<PacketSendResult>.value(PacketSendResult.sent);
      }
    }
    _previous = null;
    bySocket += 1;
    return _socket.send(packet);
  }

  @override
  Future<void> close() async {
    _lane.close();
    await _socket.close();
  }
}
