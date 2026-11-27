import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/media_channel_dial.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';

/// Dialling back: the side that was to dial a media channel could not reach
/// the other side at all (its firewall, a VPN, AP isolation), so it issues a
/// token itself and asks, over `/chat`, to be dialled instead. The other side
/// reached it once already, for `/chat` or the other way round, and tries
/// once. Who dials changes; who sends what, and under which key, does not.
/// See docs/internals/media-channels.md.

/// A channel the other side dialled to this device after this device could
/// not reach it: authenticated, with the encoder for what this side sends
/// on it, under this side's send key and the token as binding.
final class MediaDialedBack {
  const MediaDialedBack(this.channel, this.encoder);

  final WebSocketChannel channel;
  final AuthenticatedMediaPacketEncoder encoder;
}

/// Whether a failed [dialMediaChannel] never reached the other side, so a
/// dial the other way round might.
bool mediaPeerUnreachable(Object error) =>
    error is PacketWebSocketConnectException && error.unreachable;

/// The dial-backs this device waits for, at most one per route, peer and
/// session.
final class MediaDialBackWaits {
  MediaDialBackWaits({this.timeout = const Duration(seconds: 8)});

  final Duration timeout;
  final Map<String, Completer<MediaDialedBack?>> _waits =
      <String, Completer<MediaDialedBack?>>{};

  static String _key(String route, String peerId, String sessionId) =>
      '$route\u0000$peerId\u0000$sessionId';

  bool isWaiting(MediaRoute route, String peerId, String sessionId) =>
      _waits.containsKey(_key(route.path, peerId, sessionId));

  /// Waits for [peerId] to dial [route] for [sessionId], once [ask] has sent
  /// it a token. Null when [ask] could not, when nothing came in time, or
  /// when a newer wait for the same session replaced this one; [onGiveUp]
  /// then takes back the token.
  Future<MediaDialedBack?> wait(
    MediaRoute route, {
    required String peerId,
    required String sessionId,
    required FutureOr<bool> Function() ask,
    void Function()? onGiveUp,
  }) async {
    final key = _key(route.path, peerId, sessionId);
    _waits.remove(key)?.complete(null);
    final waiting = Completer<MediaDialedBack?>();
    _waits[key] = waiting;
    var answered = false;
    try {
      if (!await ask()) return null;
      final dialed = await waiting.future.timeout(
        timeout,
        onTimeout: () {
          // At once, so a dial that is late finds nothing to hand over to.
          if (identical(_waits[key], waiting)) _waits.remove(key);
          return null;
        },
      );
      answered = dialed != null;
      return dialed;
    } finally {
      final current = _waits[key];
      if (identical(current, waiting)) _waits.remove(key);
      // A newer wait for the session has its own token: leave it.
      if (!answered && (current == null || identical(current, waiting))) {
        onGiveUp?.call();
      }
    }
  }

  /// Whether [claim] is the token of a dial-back this device waits for.
  bool canAttach(SessionUpgradeClaim claim) =>
      claim.reverse &&
      _waits.containsKey(_key(claim.route, claim.peerId, claim.sessionId));

  /// Hands [channel], proved for [claim], to its wait. [encoder] builds what
  /// this side sends under its own send key, and is null when that key is no
  /// longer of [claim]'s connection. False, with the channel closed, when
  /// nothing waits for it any more.
  bool attach(
    WebSocketChannel channel,
    SessionUpgradeClaim claim, {
    required AuthenticatedMediaPacketEncoder? Function() encoder,
  }) {
    final key = _key(claim.route, claim.peerId, claim.sessionId);
    final waiting = claim.reverse ? _waits[key] : null;
    final built = waiting == null ? null : encoder();
    if (waiting == null || built == null) {
      unawaited(channel.sink.close().catchError((Object _) {}));
      return false;
    }
    _waits.remove(key);
    waiting.complete(MediaDialedBack(channel, built));
    // The channel's claim is not needed beyond the encoder built from it.
    claim.destroy();
    return true;
  }

  /// Every wait for [peerId] ends: its connection went.
  void cancelPeer(String peerId) {
    for (final key in _waits.keys.toList(growable: false)) {
      if (key.split('\u0000')[1] == peerId) _waits.remove(key)?.complete(null);
    }
  }
}

/// The answering side: dials [port] at [host], where the asking device's
/// `/chat` is, with the [token] it sent, proving it with [sendKey] as a
/// forward dial would. The channel comes with the claim this side reads it
/// under, [receiveKey] and the token, as if this side had accepted it.
Future<({WebSocketChannel channel, SessionUpgradeClaim claim})>
dialBackMediaChannel(
  MediaRoute route, {
  required String host,
  required int port,
  required String sessionId,
  required String token,
  required String localPeerId,
  required String peerId,
  required int connectionGeneration,
  required Uint8List sendKey,
  required Uint8List receiveKey,
}) async {
  final uri = route.uri(
    host: host,
    port: port,
    sessionId: sessionId,
    token: token,
  );
  final channel = await dialMediaChannel(
    uri,
    route,
    sessionId: sessionId,
    proverPeerId: localPeerId,
    proofKey: sendKey,
  );
  return (
    channel: channel,
    claim: SessionUpgradeClaim(
      route: route.path,
      namespace: route.namespace,
      sessionId: sessionId,
      peerId: peerId,
      mediaMacKey: receiveKey,
      channelBinding: mediaPacketChannelBindingFromUri(uri),
      connectionGeneration: connectionGeneration,
    ),
  );
}

/// [host] as a dial-back target: an IPv4 address the server socket saw as
/// IPv4-mapped IPv6 (`::ffff:a.b.c.d`) becomes plain IPv4.
String plainPeerHost(String host) {
  const mapped = '::ffff:';
  if (!host.toLowerCase().startsWith(mapped)) return host;
  final tail = host.substring(mapped.length);
  final address = InternetAddress.tryParse(tail);
  return address?.type == InternetAddressType.IPv4 ? tail : host;
}
