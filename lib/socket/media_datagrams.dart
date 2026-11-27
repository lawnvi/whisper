import 'dart:io';
import 'dart:typed_data';

import 'package:whisper/socket/datagram_endpoint.dart';
import 'package:whisper/socket/datagram_seal.dart';
import 'package:whisper/socket/link_delay.dart';
import 'package:whisper/socket/media_channel_dial.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

/// The UDP lane beside a media WebSocket (`datagram_endpoint.dart`): its keys
/// come from the channel's key and token under the route's namespace, so a
/// lane is only ever as trusted as the WebSocket it sits beside. Each
/// subsystem keeps its own endpoint and what goes inside a datagram.
abstract final class MediaDatagrams {
  /// The dialling side's lane to [port] at [uri]'s host, the address its
  /// WebSocket went to; null without an open [endpoint], or when that
  /// address is not IPv4 (UDP would not reach it the same way).
  static DatagramLane? dial(
    DatagramEndpoint? endpoint,
    MediaRoute route, {
    required Uri uri,
    required Uint8List mediaKey,
    required String sessionId,
    required int port,
    void Function(Uint8List payload)? onData,
    LinkDelay? delay,
  }) {
    final address = InternetAddress.tryParse(uri.host);
    if (endpoint == null ||
        endpoint.isClosed ||
        port <= 0 ||
        address == null ||
        address.type != InternetAddressType.IPv4) {
      return null;
    }
    return DatagramLane(
      endpoint: endpoint,
      keys: DatagramKeys.derive(
        mediaKey: mediaKey,
        channelBinding: mediaPacketChannelBindingFromUri(uri),
        namespace: route.namespace,
        sessionId: sessionId,
      ),
      dialer: true,
      peer: address,
      peerPort: port,
      // The dialer only hears keepalives unless it is told otherwise.
      onData: onData ?? (_) {},
      delay: delay,
    );
  }

  /// The answering side's lane for one session, once its WebSocket is
  /// authenticated and so the key and binding are known.
  static DatagramLane? answer(
    DatagramEndpoint? endpoint,
    MediaRoute route, {
    required Uint8List mediaKey,
    required Uint8List channelBinding,
    required String sessionId,
    required void Function(Uint8List payload) onData,
    LinkDelay? delay,
  }) {
    if (endpoint == null || endpoint.isClosed) return null;
    return DatagramLane(
      endpoint: endpoint,
      keys: DatagramKeys.derive(
        mediaKey: mediaKey,
        channelBinding: channelBinding,
        namespace: route.namespace,
        sessionId: sessionId,
      ),
      dialer: false,
      onData: onData,
      delay: delay,
    );
  }
}
