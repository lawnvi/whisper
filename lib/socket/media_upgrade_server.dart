import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_web_socket/shelf_web_socket.dart' as shelf_ws;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/media_upgrade_proof.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';

/// The `session` and `token` of a media upgrade request: exactly one each,
/// neither empty. Null otherwise.
({String sessionId, String token})? mediaUpgradeCredentials(Uri uri) {
  final sessions = uri.queryParametersAll['session'];
  final tokens = uri.queryParametersAll['token'];
  if (sessions == null ||
      sessions.length != 1 ||
      sessions.single.isEmpty ||
      tokens == null ||
      tokens.length != 1 ||
      tokens.single.isEmpty) {
    return null;
  }
  return (sessionId: sessions.single, token: tokens.single);
}

/// What the dialling side must prove it holds: the token of [sessionId] on
/// [route], issued to [peerId] on connection [connectionGeneration].
final class MediaUpgradeOffer {
  const MediaUpgradeOffer({
    required this.route,
    required this.namespace,
    required this.sessionId,
    required this.peerId,
    required this.connectionGeneration,
    required this.token,
  });

  MediaUpgradeOffer.forClaim(SessionUpgradeClaim claim, this.token)
    : route = claim.route,
      namespace = claim.namespace,
      sessionId = claim.sessionId,
      peerId = claim.peerId,
      connectionGeneration = claim.connectionGeneration;

  final String route;
  final String namespace;
  final String sessionId;
  final String peerId;
  final int connectionGeneration;
  final String token;
}

/// The media upgrades of one server that have not proved themselves yet:
/// how many may wait at once (each holds a socket before anything is known
/// about who sent it), the proof, and the hand-over once the token is used
/// up. The main port and the audio isolate's own port each have one, with
/// the same rules.
final class MediaUpgradeServer {
  MediaUpgradeServer({
    required this.maxProvisional,
    required this.proofTimeout,
    this.pingInterval = const Duration(seconds: 45),
    SecureRandomBytes? randomBytes,
  }) : _randomBytes = randomBytes ?? _secureRandomBytes {
    if (maxProvisional <= 0) {
      throw ArgumentError.value(maxProvisional, 'maxProvisional');
    }
    if (proofTimeout <= Duration.zero) {
      throw ArgumentError.value(proofTimeout, 'proofTimeout');
    }
  }

  final int maxProvisional;
  final Duration proofTimeout;
  final Duration pingInterval;
  final SecureRandomBytes _randomBytes;
  final Set<Future<void>> _pending = <Future<void>>{};
  int _provisional = 0;

  int get provisionalCount => _provisional;
  bool get hasPending => _pending.isNotEmpty;

  /// Waits until no upgrade is still proving, including ones that start
  /// meanwhile.
  Future<void> drain() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList(growable: false));
    }
  }

  /// A place for one upgrade, or null when [maxProvisional] are proving.
  /// Its challenge nonce is drawn now, so a failing random source refuses
  /// the request before it is upgraded ([MediaUpgradeSlot.ready]).
  MediaUpgradeSlot? reserve() {
    if (_provisional >= maxProvisional) return null;
    _provisional += 1;
    final done = Completer<void>();
    _pending.add(done.future);
    Uint8List nonce;
    try {
      nonce = _randomBytes(32);
    } catch (_) {
      nonce = Uint8List(0);
    }
    return MediaUpgradeSlot._(this, done, nonce);
  }

  /// Upgrades [request] on a shelf server for [offer]. [mediaMacKey] lends
  /// the key that checks the proof for as long as it is needed;
  /// [onReleased] runs once the upgrade no longer holds its place, proved
  /// or not. 429 when too many upgrades are proving.
  Future<shelf.Response> upgradeShelf(
    shelf.Request request,
    MediaUpgradeOffer offer, {
    required void Function(void Function(Uint8List key) use) mediaMacKey,
    required FutureOr<bool> Function(WebSocketChannel authenticated) onProven,
    void Function()? onReserved,
    void Function()? onReleased,
  }) async {
    final slot = reserve();
    if (slot == null) {
      onReleased?.call();
      return shelf.Response(429, body: 'Too Many Requests');
    }
    slot.onReleased = onReleased;
    onReserved?.call();
    if (!slot.ready) {
      slot.release();
      return shelf.Response.internalServerError();
    }
    final shelf.Handler upgrade = shelf_ws.webSocketHandler((
      WebSocketChannel channel,
      _,
    ) {
      try {
        mediaMacKey(
          (key) =>
              slot.prove(channel, offer, mediaMacKey: key, onProven: onProven),
        );
      } catch (_) {
        slot.release();
        unawaited(
          channel.sink
              .close(4001, 'media_auth_failed')
              .catchError((Object _) {}),
        );
      }
    }, pingInterval: pingInterval);
    final shelf.Response response;
    try {
      response = await upgrade(request);
    } on shelf.HijackException {
      rethrow;
    } catch (_) {
      slot.release();
      rethrow;
    }
    if (response.statusCode != HttpStatus.switchingProtocols) slot.release();
    return response;
  }

  static Uint8List _secureRandomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}

/// One upgrade's place in [MediaUpgradeServer], held until its proof ends.
final class MediaUpgradeSlot {
  MediaUpgradeSlot._(this._server, this._done, this._nonce);

  final MediaUpgradeServer _server;
  final Completer<void> _done;
  final Uint8List _nonce;

  /// Runs once, when the place is given back.
  void Function()? onReleased;
  bool _released = false;

  /// False when no nonce could be drawn: refuse the request.
  bool get ready => _nonce.length == 32;

  /// Challenges [channel] for [offer] and checks the answer with
  /// [mediaMacKey]. Once it holds, [onProven] uses up the token and hands
  /// the channel on; false refuses it. From the main isolate's token table
  /// that answer is immediate. Across isolates it is a future: the other
  /// side is told ready at once and the channel closes if the token turns
  /// out spent, while what it sends meanwhile waits in the channel.
  void prove(
    WebSocketChannel channel,
    MediaUpgradeOffer offer, {
    required Uint8List mediaMacKey,
    required FutureOr<bool> Function(WebSocketChannel authenticated) onProven,
  }) {
    if (!ready) throw StateError('media proof nonce');
    MediaUpgradeServerSession(
      channel: channel,
      challenge: MediaUpgradeChallenge(
        route: offer.route,
        namespace: offer.namespace,
        sessionId: offer.sessionId,
        tokenHash: mediaUpgradeTokenHash(offer.token),
        nonce: base64Url.encode(_nonce).replaceAll('=', ''),
        peerId: offer.peerId,
        connectionGeneration: offer.connectionGeneration,
      ),
      mediaMacKey: mediaMacKey,
      timeout: _server.proofTimeout,
      onAuthenticated: (authenticated) {
        final FutureOr<bool> answer;
        try {
          answer = onProven(authenticated);
        } catch (_) {
          return false;
        }
        if (answer is bool) return answer;
        unawaited(
          answer.then<bool>((ok) => ok, onError: (Object _) => false).then((
            ok,
          ) {
            if (!ok) {
              unawaited(
                authenticated.sink
                    .close(4001, 'media_auth_failed')
                    .catchError((Object _) {}),
              );
            }
          }),
        );
        return true;
      },
      onProvisionalFinished: release,
    );
  }

  /// Gives the place back; the upgrade ended, proved or not.
  void release() {
    if (_released) return;
    _released = true;
    _server._provisional -= 1;
    _server._pending.remove(_done.future);
    if (!_done.isCompleted) _done.complete();
    onReleased?.call();
  }
}
