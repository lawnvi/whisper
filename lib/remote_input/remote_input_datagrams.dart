import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/datagram_endpoint.dart';
import 'package:whisper/socket/datagram_seal.dart';
import 'package:whisper/socket/link_delay.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

/// The UDP side of keyboard and mouse sharing (`remote_input_lane.dart`):
/// one socket for the whole app, opened when sharing can start, and the
/// lane of each session on it. Without the socket everything goes by the
/// WebSocket as before.
abstract final class RemoteInputDatagrams {
  static const String namespace = 'remote-input';

  static DatagramEndpoint? _endpoint;
  static Future<void>? _opening;

  static DatagramEndpoint? get endpoint => _endpoint;

  /// Opens the socket once; failing leaves the WebSocket only.
  static Future<void> open() => _opening ??= () async {
    try {
      _endpoint = await DatagramEndpoint.bind();
    } on Object {
      _endpoint = null;
    }
  }();

  @visibleForTesting
  static Future<void> close() async {
    final endpoint = _endpoint;
    _endpoint = null;
    _opening = null;
    await endpoint?.close();
  }

  /// Whether an offer may say this side can send by UDP.
  static bool get canOffer => _endpoint?.isClosed == false;

  /// The port an accept of [offer] names, or 0 for the WebSocket only.
  static int portForAccept(RemoteInputControlMessage offer) {
    final endpoint = _endpoint;
    if (!offer.datagrams ||
        offer.mode != RemoteInputMode.edgeTraversal ||
        endpoint == null ||
        endpoint.isClosed) {
      return 0;
    }
    return endpoint.port;
  }

  /// The dialing side's lane to what [accept] named, or null when it named
  /// nothing or the address is not one UDP can reach the same way.
  static DatagramLane? dial({
    required Uri uri,
    required Uint8List mediaKey,
    required RemoteInputControlMessage accept,
  }) {
    final endpoint = _endpoint;
    final address = InternetAddress.tryParse(uri.host);
    if (endpoint == null ||
        endpoint.isClosed ||
        accept.datagramPort == 0 ||
        address == null ||
        address.type != InternetAddressType.IPv4) {
      return null;
    }
    return DatagramLane(
      endpoint: endpoint,
      keys: DatagramKeys.derive(
        mediaKey: mediaKey,
        channelBinding: mediaPacketChannelBindingFromUri(uri),
        namespace: namespace,
        sessionId: accept.sessionId,
      ),
      dialer: true,
      peer: address,
      peerPort: accept.datagramPort,
      // The dialer only hears keepalives.
      onData: (_) {},
      delay: LinkDelay.shared,
    );
  }

  /// The answering side's lane for one session, once its WebSocket is
  /// authenticated and so the shared secrets are known.
  static DatagramLane? answer({
    required Uint8List mediaKey,
    required Uint8List channelBinding,
    required String sessionId,
    required void Function(Uint8List payload) onData,
  }) {
    final endpoint = _endpoint;
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
      onData: onData,
      delay: LinkDelay.shared,
    );
  }
}
