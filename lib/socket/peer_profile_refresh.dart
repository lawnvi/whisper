import 'dart:async';
import 'dart:convert';

import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/socket/wire_input_policy.dart';
import 'package:whisper/state/peer_profile.dart';

/// Tracks pending remote-profile refresh waiters and decodes heartbeat
/// profile updates.
final class PeerProfileRefreshTracker {
  final Map<String, Set<Completer<PeerProfile?>>> _waiters =
      <String, Set<Completer<PeerProfile?>>>{};

  Future<PeerProfile?> waitForNextUpdate(String peerId) {
    final completer = Completer<PeerProfile?>();
    _waiters
        .putIfAbsent(peerId, () => <Completer<PeerProfile?>>{})
        .add(completer);
    return completer.future;
  }

  Future<PeerProfile?> request({
    required String peerId,
    required Duration timeout,
    required Future<void> Function() sendRequest,
    required PeerProfile? Function(String peerId) currentProfile,
  }) async {
    final completer = Completer<PeerProfile?>();
    _waiters
        .putIfAbsent(peerId, () => <Completer<PeerProfile?>>{})
        .add(completer);
    try {
      unawaited(
        sendRequest().catchError((Object _) {
          if (!completer.isCompleted) {
            completer.complete(currentProfile(peerId));
          }
        }),
      );
      return await completer.future.timeout(
        timeout,
        onTimeout: () => currentProfile(peerId),
      );
    } finally {
      final waiters = _waiters[peerId];
      waiters?.remove(completer);
      if (waiters?.isEmpty == true) {
        _waiters.remove(peerId);
      }
    }
  }

  void complete({
    String? peerId,
    required PeerProfile? Function(String peerId) currentProfile,
  }) {
    final peerIds = peerId == null
        ? _waiters.keys.toList(growable: false)
        : <String>[peerId];
    for (final id in peerIds) {
      final waiters = _waiters.remove(id);
      for (final waiter in waiters ?? const <Completer<PeerProfile?>>{}) {
        if (!waiter.isCompleted) {
          waiter.complete(currentProfile(id));
        }
      }
    }
  }

  static bool deviceChanged(DeviceData? previous, DeviceData next) {
    if (previous == null) return true;
    return previous.name != next.name ||
        previous.host != next.host ||
        previous.port != next.port ||
        previous.platform != next.platform;
  }

  static PeerProfile? decodeHeartbeatProfile(
    String? content, {
    required String resolvedPeerId,
    required PeerProfile? previousProfile,
  }) {
    if (content == null || content.isEmpty) return null;
    final wireJson = Map<String, Object?>.from(jsonDecode(content) as Map);
    final wireProfile = WirePeerProfile.fromJson(wireJson);
    final profile = PeerProfile.fromWire(
      wireProfile,
      host: previousProfile?.device.host ?? '',
      port: previousProfile?.device.port ?? 0,
    );
    WireInputPolicy.validateClaimedPeerId(
      claimedPeerId: profile.device.uid,
      authenticatedPeerId: resolvedPeerId,
    ).requireAccepted();
    return profile;
  }
}
