import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/direct_peer_http_client.dart';
import 'package:whisper/socket/media_upgrade_proof.dart';
import 'package:whisper/socket/no_delay_socket.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

/// The media connections beside `/chat`, and what differs between them when
/// one side dials the other. Everything else (the token, the proof, the
/// packet envelope) is the same for all three.
enum MediaRoute {
  audio('/audio', 'audio-group'),

  /// Only the controlling side of keyboard and mouse pings: the controlled
  /// side can hang and still hold the socket open, and the controller would
  /// keep swallowing local input for good.
  input('/input', 'remote-input', pingInterval: Duration(seconds: 5)),

  /// Video sets TCP_NODELAY on the socket itself before the upgrade.
  window('/window', 'window-stream', noDelay: true);

  const MediaRoute(
    this.path,
    this.namespace, {
    this.pingInterval,
    this.noDelay = false,
  });

  final String path;
  final String namespace;
  final Duration? pingInterval;
  final bool noDelay;

  /// Where to dial for [sessionId] with the one-time [token] the other side
  /// issued.
  Uri uri({
    required String host,
    required int port,
    required String sessionId,
    required String token,
  }) => buildPeerPacketUri(
    host: host,
    port: port,
    path: path,
    queryParameters: <String, String>{'session': sessionId, 'token': token},
  );

  /// Seals what this side sends on a channel dialled at [uri], under its own
  /// send key; the binding is the token, as on the other side.
  AuthenticatedMediaPacketEncoder encoder(
    Uri uri, {
    required String sessionId,
    required Uint8List sendKey,
    required int maxPayloadBytes,
  }) => AuthenticatedMediaPacketEncoder(
    route: path,
    namespace: namespace,
    sessionId: sessionId,
    mediaMacKey: sendKey,
    channelBinding: mediaPacketChannelBindingFromUri(uri),
    maxPayloadBytes: maxPayloadBytes,
  );

  /// Opens what the other side sends on a channel dialled at [uri], under
  /// this side's receive key for it.
  AuthenticatedMediaPacketDecoder decoder(
    Uri uri, {
    required String sessionId,
    required Uint8List receiveKey,
    required int maxPayloadBytes,
  }) => AuthenticatedMediaPacketDecoder(
    route: path,
    namespace: namespace,
    sessionId: sessionId,
    mediaMacKey: receiveKey,
    channelBinding: mediaPacketChannelBindingFromUri(uri),
    maxPayloadBytes: maxPayloadBytes,
  );
}

/// Connects to [uri] and proves, as [proverPeerId] with [proofKey], that this
/// device holds the token in it. Returns the socket once the other side
/// says it is ready. A failure comes as [PacketWebSocketConnectException],
/// whose text never shows the token or the session.
/// How long reaching the other side and its upgrade may take.
const Duration mediaChannelConnectTimeout = Duration(seconds: 6);

Future<WebSocketChannel> dialMediaChannel(
  Uri uri,
  MediaRoute route, {
  required String sessionId,
  required String proverPeerId,
  required Uint8List proofKey,
  Duration connectTimeout = mediaChannelConnectTimeout,
}) async {
  WebSocketChannel? channel;
  try {
    if (route.noDelay) {
      channel = IOWebSocketChannel(
        await connectNoDelayWebSocket(
          uri,
          client: newDirectPeerHttpClient(),
        ).timeout(connectTimeout),
      );
    } else {
      channel = IOWebSocketChannel.connect(
        uri,
        customClient: newDirectPeerHttpClient(),
        pingInterval: route.pingInterval,
        connectTimeout: connectTimeout,
      );
      await channel.ready;
    }
    return await authenticateMediaWebSocketClient(
      channel,
      uri: uri,
      route: route.path,
      namespace: route.namespace,
      sessionId: sessionId,
      peerId: proverPeerId,
      mediaMacKey: proofKey,
    );
  } catch (error, stackTrace) {
    final opened = channel;
    if (opened != null) {
      unawaited(opened.sink.close().catchError((Object _) {}));
    }
    Error.throwWithStackTrace(
      error is PacketWebSocketConnectException
          ? error
          : PacketWebSocketConnectException(uri, error),
      stackTrace,
    );
  }
}
