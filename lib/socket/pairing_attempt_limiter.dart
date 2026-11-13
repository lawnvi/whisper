import 'dart:async';
import 'dart:convert';

import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/state/pairing_request.dart';

/// The raw auth action a server sends instead of a challenge while
/// code-only pairing is paused. Clients before protocol 15 cannot parse it
/// and take it as upgrade_required.
const String pairingBusyAction = 'pairing_busy';

/// Bounds how often a client may get our challenge for a pairing that only
/// the six-digit code protects and then leave without a proof. Such a client
/// already knows the code we would show, so by trying again and again it
/// could wait for one that matches the code on another screen, one chance in
/// a million each time. Counted over all addresses together, since a device
/// on the LAN can use many. Only a pinned key equal to the one presented
/// exempts a hello: the key hash a hello may carry is the client's claim about
/// our own key, which anyone can read from our challenge, so a QR pairing
/// toward this device is counted and paused like any other.
final class PairingAttemptLimiter {
  PairingAttemptLimiter({
    DateTime Function()? clock,
    this.maxAbandoned = 5,
    this.window = const Duration(seconds: 60),
    this.pause = const Duration(seconds: 60),
    this.afterRejection = const Duration(seconds: 60),
  }) : _clock = clock ?? DateTime.now;

  final int maxAbandoned;
  final Duration window;
  final Duration pause;

  /// How long an address whose pairing the user rejected may not ask again.
  final Duration afterRejection;
  final DateTime Function() _clock;
  final List<DateTime> _abandoned = <DateTime>[];
  final Map<String, DateTime> _rejectedUntil = <String, DateTime>{};
  DateTime? _pausedUntil;

  /// Whether [hello] asks for pairing that no pinned key vouches for. Throws
  /// [pairingBusyAction] for such a hello while code-only pairing is paused,
  /// and for any pairing [from] an address whose last one the user rejected.
  bool admit(
    AuthEnvelope hello,
    ({PairingReason? reason, String expectedPublicKey}) pinPlan, {
    String from = '',
  }) {
    final now = _clock();
    _rejectedUntil.removeWhere((_, until) => !now.isBefore(until));
    if (pinPlan.reason != null && _rejectedUntil.containsKey(from)) {
      throw const AuthHandshakeException(pairingBusyAction);
    }
    final codeOnly = pairingRestsOnCodeAlone(
      reason: pinPlan.reason,
      pinnedPublicKey: pinPlan.expectedPublicKey,
      presentedPublicKey: hello.identityPublicKey ?? '',
      intendedPublicKeyHash: '',
    );
    final pausedUntil = _pausedUntil;
    if (codeOnly && pausedUntil != null && now.isBefore(pausedUntil)) {
      throw const AuthHandshakeException(pairingBusyAction);
    }
    return codeOnly;
  }

  /// Counts [session], which got our challenge for a code-only pairing, if it
  /// ends before a valid proof (the only thing that sets its pairing reason).
  void watch(PeerSocketSession session) {
    unawaited(
      session.closed.then((_) {
        if (session.remotePairingReason.isEmpty) {
          recordAbandoned();
        }
      }),
    );
  }

  /// Remembers the user's answer to a pairing prompt from the address
  /// [from]: after a rejection it may not raise another for [afterRejection].
  void noteDecision(bool allowed, String? from) {
    if (!allowed && from != null && from.isNotEmpty) {
      _rejectedUntil[from] = _clock().add(afterRejection);
    }
  }

  void recordAbandoned() {
    final now = _clock();
    _abandoned
      ..add(now)
      ..removeWhere((at) => now.difference(at) >= window);
    if (_abandoned.length > maxAbandoned) {
      _abandoned.clear();
      _pausedUntil = now.add(pause);
    }
  }
}

/// The failure code for a raw auth message that no envelope parses: a
/// server's [pairingBusyAction], or else upgrade_required.
String rawAuthFailureCode(String? content) {
  try {
    final decoded = jsonDecode(content ?? '');
    if (decoded is Map && decoded['action'] == pairingBusyAction) {
      return pairingBusyAction;
    }
  } on FormatException {
    // Not JSON at all: the peer speaks something else.
  }
  return 'upgrade_required';
}
