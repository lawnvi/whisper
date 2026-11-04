import 'package:whisper/l10n/app_localizations.dart';

/// What the list knows about a device, for the second line of its row.
class DeviceRowFacts {
  const DeviceRowFacts({
    this.connecting = false,
    this.connected = false,
    this.paired = false,
    this.nearby = false,
    this.offlineSince,
    this.lastMessage,
    this.transferName,
    this.transferPercent,
    this.soundHere = false,
    this.controllingThis = false,
    this.pointerThere = false,
    this.playingOurs = false,
    this.flowWindows = 0,
    this.preview = '',
  });

  final bool connecting, connected, paired, nearby;

  /// Written after 离线, already formatted.
  final String? offlineSince;

  /// When the last message was: at the end of the row's first line.
  final String? lastMessage;
  final String? transferName;
  final int? transferPercent;

  /// It plays its sound on this device.
  final bool soundHere;

  /// It controls this device's keyboard and mouse.
  final bool controllingThis;

  /// This device's pointer is on it.
  final bool pointerThere;

  /// It plays this device's sound.
  final bool playingOurs;
  final int flowWindows;

  /// The latest message or file name.
  final String preview;
}

enum DeviceRowLine {
  connecting,
  nearbyUnpaired,
  nearby,
  offline,
  transfer,
  soundHere,
  controllingThis,
  pointerThere,
  playingOurs,
  flowWindows,
  preview,
}

/// docs/design/surfaces.md「侧栏」: the first of these that holds. Being away
/// comes before activity, so a stale transfer never reads as a live one.
DeviceRowLine deviceRowLine(DeviceRowFacts f) {
  if (f.connecting) return DeviceRowLine.connecting;
  if (!f.connected) {
    if (f.nearby) {
      return f.paired ? DeviceRowLine.nearby : DeviceRowLine.nearbyUnpaired;
    }
    return DeviceRowLine.offline;
  }
  if (f.transferName != null) return DeviceRowLine.transfer;
  if (f.soundHere) return DeviceRowLine.soundHere;
  if (f.controllingThis) return DeviceRowLine.controllingThis;
  if (f.pointerThere) return DeviceRowLine.pointerThere;
  if (f.playingOurs) return DeviceRowLine.playingOurs;
  if (f.flowWindows > 0) return DeviceRowLine.flowWindows;
  return DeviceRowLine.preview;
}

/// Lines in the accent colour: something is happening right now.
bool deviceRowLineIsLive(DeviceRowLine line) => switch (line) {
  DeviceRowLine.transfer ||
  DeviceRowLine.soundHere ||
  DeviceRowLine.controllingThis ||
  DeviceRowLine.pointerThere ||
  DeviceRowLine.playingOurs ||
  DeviceRowLine.flowWindows => true,
  _ => false,
};

String deviceRowText(AppLocalizations l10n, DeviceRowFacts f) =>
    switch (deviceRowLine(f)) {
      DeviceRowLine.connecting => l10n.shellRowConnecting,
      DeviceRowLine.nearbyUnpaired => l10n.shellRowNearbyUnpaired,
      DeviceRowLine.nearby => l10n.shellRowNearby,
      DeviceRowLine.offline =>
        f.offlineSince == null
            ? l10n.shellRowOffline
            : l10n.shellRowOfflineSince(f.offlineSince!),
      DeviceRowLine.transfer =>
        f.transferPercent == null
            ? f.transferName!
            : '${f.transferName!} ${f.transferPercent}%',
      DeviceRowLine.soundHere => l10n.shellRowSoundHere,
      DeviceRowLine.controllingThis => l10n.shellRowControllingThis,
      DeviceRowLine.pointerThere => l10n.shellRowPointerThere,
      DeviceRowLine.playingOurs => l10n.shellRowPlayingOurs,
      DeviceRowLine.flowWindows => l10n.shellRowWindows(f.flowWindows),
      DeviceRowLine.preview => f.preview,
    };
