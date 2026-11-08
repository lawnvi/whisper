import 'dart:async';

import '../helper/device_form_factor.dart';
import '../helper/wake_on_lan.dart';
import 'peer_profile.dart';

/// What a peer said about itself that is kept after it leaves: whether it is
/// a tablet, and the network cards that can wake it.
void rememberPeerTraits(String peerId, PeerProfile profile) {
  if (profile.formFactor.isNotEmpty) {
    unawaited(DeviceFormFactors.shared.record(peerId, profile.formFactor));
  }
  // An older version can't say; what it said before stays.
  if (profile.protocolVersion >= WakeTarget.sinceProtocolVersion) {
    unawaited(WakeTargets.shared.record(peerId, profile.wake));
  }
}

/// A removed device leaves nothing behind.
void forgetPeerTraits(String peerId) =>
    unawaited(WakeTargets.shared.forget(peerId));

/// This device as its profile describes it: a phone, a tablet or a computer.
Future<String> localFormFactor() async {
  await DeviceFormFactors.shared.load();
  return DeviceFormFactors.shared.local;
}

List<WakeTarget>? _localWake;
DateTime _localWakeRead = DateTime.fromMillisecondsSinceEpoch(0);

/// This computer's cards for its profile. Read again after a while, since a
/// laptop moves between Wi-Fi and a cable, but not on every connection.
Future<List<WakeTarget>> localWakeTargetsForProfile() async {
  final cached = _localWake;
  if (cached != null &&
      DateTime.now().difference(_localWakeRead) < const Duration(minutes: 5)) {
    return cached;
  }
  _localWakeRead = DateTime.now();
  return _localWake = await localWakeTargets();
}
