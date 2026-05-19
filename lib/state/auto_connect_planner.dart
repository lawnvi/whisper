import 'package:whisper/state/connection_models.dart';

class AutoConnectPlanner {
  const AutoConnectPlanner._();

  static bool isMutuallyTrusted(DevicePresence candidate) {
    return candidate.locallyTrusted && candidate.remotelyTrusted;
  }

  static DevicePresence? selectCandidate({
    required bool autoConnectEnabled,
    String? activePeerId,
    Set<String> connectedPeerIds = const <String>{},
    required String? lastManualPeerId,
    required Iterable<DevicePresence> candidates,
  }) {
    if (!autoConnectEnabled) {
      return null;
    }
    final connected = <String>{
      ...connectedPeerIds,
      if (activePeerId?.isNotEmpty ?? false) activePeerId!,
    };

    final trustedCandidates = candidates
        .where(
          (candidate) =>
              candidate.discovered &&
              isMutuallyTrusted(candidate) &&
              !connected.contains(candidate.peerId),
        )
        .toList()
      ..sort((left, right) => right.lastSeenAt.compareTo(left.lastSeenAt));

    if (trustedCandidates.isEmpty) {
      return null;
    }

    if (lastManualPeerId?.isNotEmpty ?? false) {
      for (final candidate in trustedCandidates) {
        if (candidate.peerId == lastManualPeerId) {
          return candidate;
        }
      }
    }

    return trustedCandidates.first;
  }
}
