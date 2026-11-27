import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/bounded_binary_websocket_session.dart';
import 'package:whisper/socket/media_channel_dial.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';

/// How an accepted media channel ended, as its subsystem hears it.
final class MediaChannelClosed {
  const MediaChannelClosed({
    required this.claim,
    required this.expected,
    this.error,
  });

  final SessionUpgradeClaim claim;

  /// This side closed it on purpose: its session stopped, or everything is
  /// closing. Anything else is the link failing.
  final bool expected;
  final Object? error;
}

/// The media channels this device accepted on one route: each decrypted
/// under its claim, at most one per session and peer, closed by session, by
/// peer, by superseded key, or all at once.
final class MediaChannelRegistry {
  MediaChannelRegistry(this.route, {required this.maxPayloadBytes});

  final MediaRoute route;
  final int maxPayloadBytes;

  int get maxMessageBytes =>
      maxPayloadBytes + AuthenticatedMediaPacketEnvelope.overheadBytes;

  final Map<BoundedBinaryWebSocketSession, SessionUpgradeClaim> _channels =
      <BoundedBinaryWebSocketSession, SessionUpgradeClaim>{};
  final Map<BoundedBinaryWebSocketSession, Future<void>> _closes =
      <BoundedBinaryWebSocketSession, Future<void>>{};
  final Set<BoundedBinaryWebSocketSession> _expected =
      <BoundedBinaryWebSocketSession>{};
  final Map<BoundedBinaryWebSocketSession, Object> _errors =
      <BoundedBinaryWebSocketSession, Object>{};
  Future<void>? _closingAll;
  Object? _closeError;
  StackTrace? _closeStackTrace;

  int get activeCount => _channels.length;
  bool get isClosing => _closingAll != null;

  /// Whether [claim] names this route.
  bool isForRoute(SessionUpgradeClaim claim) =>
      claim.route == route.path && claim.namespace == route.namespace;

  /// Whether a channel for the same session and peer is attached.
  bool hasChannelFor(SessionUpgradeClaim claim) => _channels.values.any(
    (active) =>
        active.route == claim.route &&
        active.namespace == claim.namespace &&
        active.sessionId == claim.sessionId &&
        active.peerId == claim.peerId,
  );

  /// Takes an authenticated socket for [claim]: every message is decrypted
  /// under the claim's key and binding and its payload handed to [onPacket],
  /// one at a time. [onClosing] runs as soon as the far side starts to close;
  /// [onClosed] once the socket is gone, before the claim is destroyed.
  /// False, with the socket closed, when [claim] is for another route or its
  /// session already has a channel (unless everything is closing, when the
  /// new one closes straight away too).
  bool attach(
    WebSocketChannel channel, {
    required SessionUpgradeClaim claim,
    required FutureOr<void> Function(Uint8List payload) onPacket,
    void Function()? onClosing,
    void Function(MediaChannelClosed closed)? onClosed,
    void Function(Object error)? onError,
  }) {
    if (!isForRoute(claim) || (hasChannelFor(claim) && !isClosing)) {
      unawaited(channel.sink.close().catchError((Object _) {}));
      return false;
    }
    final decoder = claim.withMediaPacketContext(
      (mediaMacKey, channelBinding) => AuthenticatedMediaPacketDecoder(
        route: claim.route,
        namespace: claim.namespace,
        sessionId: claim.sessionId,
        mediaMacKey: mediaMacKey,
        channelBinding: channelBinding,
        maxPayloadBytes: maxPayloadBytes,
      ),
    );
    try {
      late final BoundedBinaryWebSocketSession binding;
      binding = BoundedBinaryWebSocketSession(
        channel: channel,
        maxMessageBytes: maxMessageBytes,
        onMessage: (bytes) => onPacket(decoder.decode(bytes)),
        onError: (error) {
          _errors[binding] = error;
          onError?.call(error);
        },
        onClosing: onClosing,
        onClosed: () {
          decoder.destroy();
          final claim = _channels.remove(binding);
          final expected = _expected.remove(binding);
          final error = _errors.remove(binding);
          if (claim == null) return;
          try {
            onClosed?.call(
              MediaChannelClosed(
                claim: claim,
                expected: expected,
                error: error,
              ),
            );
          } finally {
            claim.destroy();
          }
        },
      );
      _channels[binding] = claim;
      if (isClosing) unawaited(_close(binding, expected: true));
      return true;
    } catch (_) {
      decoder.destroy();
      rethrow;
    }
  }

  /// Closes the channels of [sessionId] (from [peerId], under [namespace]
  /// when given) because this side ended that session.
  Future<void> closeSession(
    String sessionId, {
    String? peerId,
    String? namespace,
  }) => closeWhere(
    (claim) =>
        claim.sessionId == sessionId &&
        (peerId == null || claim.peerId == peerId) &&
        (namespace == null || claim.namespace == namespace),
    expected: true,
  );

  /// Closes everything from [peerId]: its connection went.
  Future<void> closePeer(String peerId) =>
      closeWhere((claim) => claim.peerId == peerId);

  /// Closes [peerId]'s channels authenticated under any key but
  /// [mediaMacKey]: their connection was replaced by one with new keys.
  Future<void> closeSuperseded(
    String peerId, {
    required Uint8List mediaMacKey,
  }) => closeWhere(
    (claim) => claim.peerId == peerId && !claim.matchesMediaMacKey(mediaMacKey),
  );

  Future<void> closeWhere(
    bool Function(SessionUpgradeClaim claim) matches, {
    bool expected = false,
  }) async {
    final channels = _channels.entries
        .where((entry) => matches(entry.value))
        .map((entry) => entry.key)
        .toList(growable: false);
    await Future.wait(channels.map((c) => _close(c, expected: expected)));
  }

  /// Closes every channel, including any attached meanwhile; the first close
  /// that failed is rethrown once all are done.
  Future<void> closeAll() {
    final existing = _closingAll;
    if (existing != null) return existing;
    _closeError = null;
    _closeStackTrace = null;
    final completer = Completer<void>();
    final closing = completer.future;
    // Set before anything runs: with nothing to close the loop below ends
    // without yielding.
    _closingAll = closing;
    () async {
      try {
        while (_channels.isNotEmpty || _closes.isNotEmpty) {
          for (final channel in _channels.keys.toList(growable: false)) {
            unawaited(_close(channel, expected: true));
          }
          final closes = _closes.values.toList(growable: false);
          if (closes.isNotEmpty) await Future.wait(closes);
        }
        if (_closeError case final error?) {
          Error.throwWithStackTrace(error, _closeStackTrace!);
        }
      } finally {
        if (identical(_closingAll, closing)) _closingAll = null;
      }
    }().then<void>(
      (_) => completer.complete(),
      onError: (Object error, StackTrace stackTrace) =>
          completer.completeError(error, stackTrace),
    );
    return closing;
  }

  Future<void> _close(
    BoundedBinaryWebSocketSession channel, {
    required bool expected,
  }) {
    if (expected) _expected.add(channel);
    final existing = _closes[channel];
    if (existing != null) return existing;
    late final Future<void> tracked;
    tracked = channel
        .close()
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            _closeError ??= error;
            _closeStackTrace ??= stackTrace;
          },
        )
        .whenComplete(() {
          if (identical(_closes[channel], tracked)) _closes.remove(channel);
        });
    _closes[channel] = tracked;
    return tracked;
  }
}
