import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';

/// What a device says it is, so others can draw it as one
/// ([PeerProfile.formFactor]): a phone or a tablet, and from 0.0.61 a
/// laptop or a desktop. Older versions keep only the first two and draw a
/// computer by its name.
abstract final class DeviceFormFactor {
  static const phone = 'phone';
  static const tablet = 'tablet';
  static const laptop = 'laptop';
  static const desktop = 'desktop';

  /// Sent from this protocol version on: an older peer rejects a profile
  /// field it does not know (and 0.0.57 speaks 11).
  static const sinceProtocolVersion = 12;
}

/// The app version a device runs ("0.0.61"), shown on its card. Sent from
/// [sinceProtocolVersion] on: an older peer rejects a profile field it does
/// not know.
abstract final class AppVersionField {
  static const sinceProtocolVersion = 14;
  static const maxBytes = 32;
  static final RegExp _pattern = RegExp(r'^[0-9A-Za-z.+\-]+$');

  static bool valid(String value) =>
      value.isNotEmpty &&
      utf8.encode(value).length <= maxBytes &&
      _pattern.hasMatch(value);
}

/// A network card that can wake a computer from sleep: its hardware address
/// and whether it is wired (Wi-Fi seldom wakes one). A computer sends its own
/// so others can wake it after it has gone to sleep ([PeerProfile.wake]).
final class WakeTarget {
  const WakeTarget({required this.mac, required this.wired});

  /// Sent from this protocol version on.
  static const sinceProtocolVersion = 13;
  static const maxPerDevice = 4;
  static final RegExp _macPattern = RegExp(r'^[0-9a-f]{2}(:[0-9a-f]{2}){5}$');

  /// Lower case, colon separated.
  final String mac;
  final bool wired;

  /// Any common spelling ("AA-BB-CC-DD-EE-FF", "aa:bb:…") to [mac]'s, or null
  /// for what isn't one card's address.
  static String? normalize(String raw) {
    final hex = raw.replaceAll(RegExp(r'[-:.\s]'), '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{12}$').hasMatch(hex)) return null;
    final mac = [
      for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2),
    ].join(':');
    // All zeros is no address; an odd first byte is a group address.
    if (mac == '00:00:00:00:00:00' || int.parse(hex[1], radix: 16).isOdd) {
      return null;
    }
    return mac;
  }

  Map<String, Object> toJson() => <String, Object>{'mac': mac, 'wired': wired};

  static WakeTarget fromJson(Object? json) {
    if (json is! Map || json.length != 2) {
      throw const FormatException('Invalid wake target');
    }
    final mac = json['mac'];
    final wired = json['wired'];
    if (mac is! String ||
        wired is! bool ||
        !_macPattern.hasMatch(mac) ||
        normalize(mac) != mac) {
      throw const FormatException('Invalid wake target');
    }
    return WakeTarget(mac: mac, wired: wired);
  }

  @override
  bool operator ==(Object other) =>
      other is WakeTarget && other.mac == mac && other.wired == wired;

  @override
  int get hashCode => Object.hash(mac, wired);
}

class WirePeerProfile {
  const WirePeerProfile({
    required this.uid,
    required this.name,
    required this.platform,
    this.protocolVersion = 14,
    this.capabilities = const PeerCapabilities(),
    this.displayTopology,
    this.formFactor = '',
    this.wake = const <WakeTarget>[],
    this.appVersion = '',
  });

  static const Set<String> _allowedKeys = <String>{
    'uid',
    'name',
    'platform',
    'protocolVersion',
    'capabilities',
    'displayTopology',
    'formFactor',
    'wake',
    'appVersion',
  };

  final String uid;
  final String name;
  final String platform;
  final int protocolVersion;
  final PeerCapabilities capabilities;
  final RemoteInputTopology? displayTopology;

  /// [DeviceFormFactor.phone] or [DeviceFormFactor.tablet]; empty when not
  /// said (a computer, an older version).
  final String formFactor;

  /// This computer's network cards that can wake it; empty on phones.
  final List<WakeTarget> wake;

  /// See [AppVersionField]; empty when not said.
  final String appVersion;

  WirePeerProfile forProtocolVersion(int version) => WirePeerProfile(
    uid: uid,
    name: name,
    platform: platform,
    protocolVersion: version,
    capabilities: capabilities,
    displayTopology: displayTopology,
    formFactor: formFactor,
    wake: wake,
    appVersion: appVersion,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'uid': uid,
    'name': name,
    'platform': platform,
    'protocolVersion': protocolVersion,
    'capabilities': capabilities.toWireJson(protocolVersion),
    if (displayTopology != null) 'displayTopology': displayTopology!.toJson(),
    if (formFactor.isNotEmpty &&
        protocolVersion >= DeviceFormFactor.sinceProtocolVersion)
      'formFactor': formFactor,
    if (wake.isNotEmpty && protocolVersion >= WakeTarget.sinceProtocolVersion)
      'wake': <Object>[for (final target in wake) target.toJson()],
    if (appVersion.isNotEmpty &&
        protocolVersion >= AppVersionField.sinceProtocolVersion)
      'appVersion': appVersion,
  };

  String toJsonString() => jsonEncode(toJson());

  Uint8List canonicalDigest() => Uint8List.fromList(
    sha256.convert(utf8.encode(_canonicalJson(toJson()))).bytes,
  );

  DeviceData toDeviceData({String host = '', int port = 0}) => DeviceData(
    id: 0,
    uid: uid,
    name: name,
    host: host,
    port: port,
    password: '',
    platform: platform,
    isServer: false,
    online: true,
    clipboard: false,
    auth: false,
    lastTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    around: true,
  );

  factory WirePeerProfile.fromJson(Map<String, Object?> json) {
    if (json.keys.any((key) => !_allowedKeys.contains(key))) {
      throw const FormatException('Unexpected wire profile field');
    }
    final uid = _requiredProfileString(json, 'uid', maxBytes: 256);
    final name = _requiredProfileString(json, 'name', maxBytes: 256);
    final platform = _requiredProfileString(json, 'platform', maxBytes: 64);
    final protocolVersion = json['protocolVersion'];
    if (protocolVersion is! int || protocolVersion <= 0) {
      throw const FormatException('Invalid profile protocol version');
    }
    final capabilitiesValue = json['capabilities'];
    if (capabilitiesValue is! Map) {
      throw const FormatException('Invalid profile capabilities');
    }
    final capabilitiesJson = <String, dynamic>{};
    for (final entry in capabilitiesValue.entries) {
      if (entry.key is! String) {
        throw const FormatException('Invalid capability key');
      }
      capabilitiesJson[entry.key as String] = entry.value;
    }
    final topology = json.containsKey('displayTopology')
        ? _wireTopologyFromJson(json['displayTopology'])
        : null;
    final formFactor = json.containsKey('formFactor')
        ? _requiredProfileString(json, 'formFactor', maxBytes: 16)
        : '';
    final wakeValue = json['wake'];
    if (json.containsKey('wake') &&
        (protocolVersion < WakeTarget.sinceProtocolVersion ||
            wakeValue is! List ||
            wakeValue.length > WakeTarget.maxPerDevice)) {
      throw const FormatException('Invalid profile wake targets');
    }
    final appVersion = json['appVersion'];
    if (json.containsKey('appVersion') &&
        (protocolVersion < AppVersionField.sinceProtocolVersion ||
            appVersion is! String ||
            !AppVersionField.valid(appVersion))) {
      throw const FormatException('Invalid profile app version');
    }
    return WirePeerProfile(
      uid: uid,
      name: name,
      platform: platform,
      protocolVersion: protocolVersion,
      capabilities: PeerCapabilities.fromWireJson(
        capabilitiesJson,
        protocolVersion: protocolVersion,
      ),
      displayTopology: topology,
      formFactor: formFactor,
      wake: wakeValue is List
          ? List<WakeTarget>.unmodifiable(wakeValue.map(WakeTarget.fromJson))
          : const <WakeTarget>[],
      appVersion: appVersion is String ? appVersion : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WirePeerProfile &&
      other.uid == uid &&
      other.name == name &&
      other.platform == platform &&
      other.protocolVersion == protocolVersion &&
      _canonicalJson(other.capabilities.toJson()) ==
          _canonicalJson(capabilities.toJson()) &&
      _canonicalJson(other.displayTopology?.toJson()) ==
          _canonicalJson(displayTopology?.toJson()) &&
      other.formFactor == formFactor &&
      _sameWake(other.wake, wake) &&
      other.appVersion == appVersion;

  @override
  int get hashCode => Object.hash(
    uid,
    name,
    platform,
    protocolVersion,
    _canonicalJson(capabilities.toJson()),
    _canonicalJson(displayTopology?.toJson()),
    formFactor,
    Object.hashAll(wake),
    appVersion,
  );
}

class PeerProfile {
  const PeerProfile({
    required this.device,
    required this.trustedPeerIds,
    required this.autoApproveNewDevices,
    required this.autoConnectEnabled,
    this.protocolVersion = 14,
    this.capabilities = const PeerCapabilities(),
    this.displayTopology,
    this.formFactor = '',
    this.wake = const <WakeTarget>[],
    this.appVersion = '',
  });

  final DeviceData device;
  final List<String> trustedPeerIds;
  final bool autoApproveNewDevices;
  final bool autoConnectEnabled;
  final int protocolVersion;
  final PeerCapabilities capabilities;
  final RemoteInputTopology? displayTopology;

  /// See [WirePeerProfile.formFactor].
  final String formFactor;

  /// See [WirePeerProfile.wake].
  final List<WakeTarget> wake;

  /// See [WirePeerProfile.appVersion].
  final String appVersion;

  bool trustsPeer(String peerId) {
    return trustedPeerIds.contains(peerId);
  }

  /// The same profile for [device]: where it was reached, or as stored here.
  PeerProfile withDevice(DeviceData device) => PeerProfile(
    device: device,
    trustedPeerIds: trustedPeerIds,
    autoApproveNewDevices: autoApproveNewDevices,
    autoConnectEnabled: autoConnectEnabled,
    protocolVersion: protocolVersion,
    capabilities: capabilities,
    displayTopology: displayTopology,
    formFactor: formFactor,
    wake: wake,
    appVersion: appVersion,
  );

  Map<String, dynamic> toJson() {
    return toWireProfile().toJson();
  }

  String toJsonString() => jsonEncode(toJson());

  factory PeerProfile.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('uid')) {
      final wire = WirePeerProfile.fromJson(json);
      return PeerProfile.fromWire(wire);
    }
    if (json.containsKey('device')) {
      final deviceJson = Map<String, dynamic>.from(json['device'] as Map);
      return PeerProfile(
        device: DeviceData.fromJson(deviceJson),
        trustedPeerIds: (json['trustedPeerIds'] as List<dynamic>? ?? const [])
            .cast<String>(),
        autoApproveNewDevices: json['autoApproveNewDevices'] as bool? ?? false,
        autoConnectEnabled: json['autoConnectEnabled'] as bool? ?? true,
        protocolVersion: json['protocolVersion'] as int? ?? 1,
        capabilities: PeerCapabilities.fromJson(
          json['capabilities'] as Map<String, dynamic>? ?? const {},
        ),
        displayTopology: _topologyFromJson(json['displayTopology']),
      );
    }

    return PeerProfile(
      device: DeviceData.fromJson(json),
      trustedPeerIds: const [],
      autoApproveNewDevices: json['auth'] as bool? ?? false,
      autoConnectEnabled: true,
      protocolVersion: 1,
      capabilities: const PeerCapabilities(),
      displayTopology: null,
    );
  }

  factory PeerProfile.fromWire(
    WirePeerProfile wire, {
    String host = '',
    int port = 0,
  }) {
    return PeerProfile(
      device: wire.toDeviceData(host: host, port: port),
      trustedPeerIds: const <String>[],
      autoApproveNewDevices: false,
      autoConnectEnabled: true,
      protocolVersion: wire.protocolVersion,
      capabilities: wire.capabilities,
      displayTopology: wire.displayTopology,
      formFactor: wire.formFactor,
      wake: wire.wake,
      appVersion: wire.appVersion,
    );
  }

  WirePeerProfile toWireProfile() => WirePeerProfile(
    uid: device.uid,
    name: device.name,
    platform: device.platform,
    protocolVersion: protocolVersion,
    capabilities: capabilities,
    displayTopology: displayTopology,
    formFactor: formFactor,
    wake: wake,
    appVersion: appVersion,
  );
}

bool _sameWake(List<WakeTarget> a, List<WakeTarget> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

RemoteInputTopology? _topologyFromJson(Object? value) {
  if (value is Map<String, dynamic>) {
    return RemoteInputTopology.fromJson(value);
  }
  if (value is Map) {
    return RemoteInputTopology.fromJson(Map<String, dynamic>.from(value));
  }
  return null;
}

RemoteInputTopology _wireTopologyFromJson(Object? value) {
  const topologyKeys = <String>{'platform', 'displays', 'updatedAt'};
  const displayKeys = <String>{
    'displayId',
    'name',
    'x',
    'y',
    'width',
    'height',
    'scale',
    'isPrimary',
  };
  if (value is! Map || !_hasExactStringKeys(value, topologyKeys)) {
    throw const FormatException('Invalid wire display topology');
  }
  final platform = _boundedWireString(
    value['platform'],
    maxBytes: 64,
    allowEmpty: true,
  );
  final updatedAt = value['updatedAt'];
  if (updatedAt is! int || updatedAt < 0 || updatedAt > 9007199254740991) {
    throw const FormatException('Invalid wire topology timestamp');
  }
  final rawDisplays = value['displays'];
  if (rawDisplays is! List || rawDisplays.isEmpty || rawDisplays.length > 16) {
    throw const FormatException('Invalid wire display count');
  }

  final displayIds = <String>{};
  var primaryCount = 0;
  final displays = <RemoteInputDisplay>[];
  for (final rawDisplay in rawDisplays) {
    if (rawDisplay is! Map || !_hasExactStringKeys(rawDisplay, displayKeys)) {
      throw const FormatException('Invalid wire display');
    }
    final displayId = _boundedWireString(
      rawDisplay['displayId'],
      maxBytes: 128,
    );
    final name = _boundedWireString(
      rawDisplay['name'],
      maxBytes: 256,
      allowEmpty: true,
    );
    if (!displayIds.add(displayId)) {
      throw const FormatException('Duplicate wire display id');
    }
    final x = _boundedWireInt(rawDisplay['x'], min: -1000000, max: 1000000);
    final y = _boundedWireInt(rawDisplay['y'], min: -1000000, max: 1000000);
    final width = _boundedWireInt(rawDisplay['width'], min: 1, max: 100000);
    final height = _boundedWireInt(rawDisplay['height'], min: 1, max: 100000);
    final scaleValue = rawDisplay['scale'];
    if (scaleValue is! num ||
        !scaleValue.isFinite ||
        scaleValue < 0.25 ||
        scaleValue > 8) {
      throw const FormatException('Invalid wire display scale');
    }
    final isPrimary = rawDisplay['isPrimary'];
    if (isPrimary is! bool) {
      throw const FormatException('Invalid wire primary display flag');
    }
    if (isPrimary) {
      primaryCount += 1;
    }
    displays.add(
      RemoteInputDisplay(
        displayId: displayId,
        name: name,
        x: x,
        y: y,
        width: width,
        height: height,
        scale: scaleValue.toDouble(),
        isPrimary: isPrimary,
      ),
    );
  }
  if (primaryCount != 1) {
    throw const FormatException('Wire topology must have one primary display');
  }
  return RemoteInputTopology(
    platform: platform,
    displays: List<RemoteInputDisplay>.unmodifiable(displays),
    updatedAt: updatedAt,
  );
}

bool _hasExactStringKeys(Map<Object?, Object?> value, Set<String> keys) {
  if (value.length != keys.length) {
    return false;
  }
  for (final key in value.keys) {
    if (key is! String || !keys.contains(key)) {
      return false;
    }
  }
  return true;
}

String _boundedWireString(
  Object? value, {
  required int maxBytes,
  bool allowEmpty = false,
}) {
  if (value is! String ||
      (!allowEmpty && value.isEmpty) ||
      utf8.encode(value).length > maxBytes) {
    throw const FormatException('Invalid wire display string');
  }
  return value;
}

int _boundedWireInt(Object? value, {required int min, required int max}) {
  if (value is! int || value < min || value > max) {
    throw const FormatException('Invalid wire display integer');
  }
  return value;
}

class PeerCapabilities {
  const PeerCapabilities({
    this.fileTransferV3 = false,
    this.systemAudioSourceV1 = false,
    this.speakerSinkV1 = false,
    this.remoteInputManualSourceV1 = false,
    this.remoteInputManualSinkV1 = false,
    this.remoteInputSourceV1 = false,
    this.remoteInputSinkV1 = false,
    this.remoteInputTopologyV1 = false,
    this.remoteInputWorkspaceGraphV1 = false,
    this.audioGroupSourceV1 = false,
    this.audioGroupSinkV1 = false,
    this.audioGroupRejoinV1 = false,
    this.audioSyncClockV1 = false,
    this.audioChannelRoleV1 = false,
    this.windowStreamSourceV1 = false,
    this.windowStreamSinkV1 = false,
    this.windowStreamOfferV1 = false,
    this.remoteFilesV1 = false,
  });

  final bool fileTransferV3;
  final bool systemAudioSourceV1;
  final bool speakerSinkV1;
  final bool remoteInputManualSourceV1;
  final bool remoteInputManualSinkV1;
  final bool remoteInputSourceV1;
  final bool remoteInputSinkV1;
  final bool remoteInputTopologyV1;
  final bool remoteInputWorkspaceGraphV1;
  final bool audioGroupSourceV1;
  final bool audioGroupSinkV1;
  final bool audioGroupRejoinV1;
  final bool audioSyncClockV1;
  final bool audioChannelRoleV1;

  /// Offers its windows to other peers over `/window` (protocol 12).
  final bool windowStreamSourceV1;

  /// Can show another peer's windows (protocol 12).
  final bool windowStreamSinkV1;

  /// Accepts windows a host sends over ("送出去", protocol 12).
  final bool windowStreamOfferV1;

  /// Speaks the file-browse protocol: lets trusted peers browse its files
  /// (after asking) and browses theirs (protocol 12).
  final bool remoteFilesV1;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'fileTransferV3': fileTransferV3,
      'systemAudioSourceV1': systemAudioSourceV1,
      'speakerSinkV1': speakerSinkV1,
      'remoteInputManualSourceV1': remoteInputManualSourceV1,
      'remoteInputManualSinkV1': remoteInputManualSinkV1,
      'remoteInputSourceV1': remoteInputSourceV1,
      'remoteInputSinkV1': remoteInputSinkV1,
      'remoteInputTopologyV1': remoteInputTopologyV1,
      'remoteInputWorkspaceGraphV1': remoteInputWorkspaceGraphV1,
      'audioGroupSourceV1': audioGroupSourceV1,
      'audioGroupSinkV1': audioGroupSinkV1,
      'audioGroupRejoinV1': audioGroupRejoinV1,
      'audioSyncClockV1': audioSyncClockV1,
      'audioChannelRoleV1': audioChannelRoleV1,
      'windowStreamSourceV1': windowStreamSourceV1,
      'windowStreamSinkV1': windowStreamSinkV1,
      'windowStreamOfferV1': windowStreamOfferV1,
      'remoteFilesV1': remoteFilesV1,
    };
  }

  Map<String, dynamic> toWireJson(int protocolVersion) {
    final json = toJson();
    if (protocolVersion < 12) {
      json.remove('windowStreamSourceV1');
      json.remove('windowStreamSinkV1');
      json.remove('windowStreamOfferV1');
      json.remove('remoteFilesV1');
    }
    if (protocolVersion < 11) {
      json.remove('remoteInputManualSourceV1');
      json.remove('remoteInputManualSinkV1');
    }
    if (protocolVersion < 10) {
      json.remove('remoteInputWorkspaceGraphV1');
    }
    return json;
  }

  factory PeerCapabilities.fromJson(Map<String, dynamic> json) {
    return PeerCapabilities(
      fileTransferV3: json['fileTransferV3'] as bool? ?? false,
      systemAudioSourceV1: json['systemAudioSourceV1'] as bool? ?? false,
      speakerSinkV1: json['speakerSinkV1'] as bool? ?? false,
      remoteInputManualSourceV1:
          json['remoteInputManualSourceV1'] as bool? ?? false,
      remoteInputManualSinkV1:
          json['remoteInputManualSinkV1'] as bool? ?? false,
      remoteInputSourceV1: json['remoteInputSourceV1'] as bool? ?? false,
      remoteInputSinkV1: json['remoteInputSinkV1'] as bool? ?? false,
      remoteInputTopologyV1: json['remoteInputTopologyV1'] as bool? ?? false,
      remoteInputWorkspaceGraphV1:
          json['remoteInputWorkspaceGraphV1'] as bool? ?? false,
      audioGroupSourceV1: json['audioGroupSourceV1'] as bool? ?? false,
      audioGroupSinkV1: json['audioGroupSinkV1'] as bool? ?? false,
      audioGroupRejoinV1: json['audioGroupRejoinV1'] as bool? ?? false,
      audioSyncClockV1: json['audioSyncClockV1'] as bool? ?? false,
      audioChannelRoleV1: json['audioChannelRoleV1'] as bool? ?? false,
      windowStreamSourceV1: json['windowStreamSourceV1'] as bool? ?? false,
      windowStreamSinkV1: json['windowStreamSinkV1'] as bool? ?? false,
      windowStreamOfferV1: json['windowStreamOfferV1'] as bool? ?? false,
      remoteFilesV1: json['remoteFilesV1'] as bool? ?? false,
    );
  }

  factory PeerCapabilities.fromWireJson(
    Map<String, dynamic> json, {
    int protocolVersion = 12,
  }) {
    const legacyAllowed = <String>{
      'fileTransferV3',
      'systemAudioSourceV1',
      'speakerSinkV1',
      'remoteInputSourceV1',
      'remoteInputSinkV1',
      'remoteInputTopologyV1',
      'audioGroupSourceV1',
      'audioGroupSinkV1',
      'audioGroupRejoinV1',
      'audioSyncClockV1',
      'audioChannelRoleV1',
    };
    const workspaceGraphV1 = <String>{'remoteInputWorkspaceGraphV1'};
    final allowed = protocolVersion >= 10
        ? legacyAllowed.union(workspaceGraphV1)
        : legacyAllowed;
    if (protocolVersion >= 11) {
      allowed.addAll({'remoteInputManualSourceV1', 'remoteInputManualSinkV1'});
    }
    if (protocolVersion >= 12) {
      allowed.addAll({
        'windowStreamSourceV1',
        'windowStreamSinkV1',
        'windowStreamOfferV1',
        'remoteFilesV1',
      });
    }
    if (json.keys.any((key) => !allowed.contains(key)) ||
        json.values.any((value) => value is! bool)) {
      throw const FormatException('Invalid wire capabilities');
    }
    return PeerCapabilities.fromJson(json);
  }
}

String _requiredProfileString(
  Map<String, Object?> json,
  String key, {
  required int maxBytes,
}) {
  final value = json[key];
  if (value is! String ||
      value.isEmpty ||
      utf8.encode(value).length > maxBytes) {
    throw FormatException('Invalid profile $key');
  }
  return value;
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) {
      if (key is! String) {
        throw const FormatException('Canonical map keys must be strings');
      }
      return key;
    }).toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  if (value == null || value is String || value is num || value is bool) {
    return jsonEncode(value);
  }
  throw const FormatException('Unsupported canonical JSON value');
}
