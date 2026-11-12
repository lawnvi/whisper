import 'dart:async';

import 'package:package_info_plus/package_info_plus.dart';

import '../helper/device_form_factor.dart';
import '../helper/wake_on_lan.dart';
import 'peer_aliases.dart';
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

/// A removed device leaves nothing behind, the name given to it here too.
void forgetPeerTraits(String peerId) {
  unawaited(WakeTargets.shared.forget(peerId));
  unawaited(PeerAliases.shared.forget(peerId));
}

/// This device as its profile describes it: a phone, a tablet, a laptop or
/// a desktop.
Future<String> localFormFactor() async {
  await DeviceFormFactors.shared.load();
  return DeviceFormFactors.shared.local;
}

String? _appVersion;

/// This app's version for its profile, or empty when it cannot be read.
Future<String> localAppVersion() async {
  final known = _appVersion;
  if (known != null) return known;
  var version = '';
  try {
    version = (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    // Not said: the card shows no version.
  }
  return _appVersion = AppVersionField.valid(version) ? version : '';
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
