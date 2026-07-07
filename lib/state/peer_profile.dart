import 'dart:convert';

import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';

class PeerProfile {
  const PeerProfile({
    required this.device,
    required this.trustedPeerIds,
    required this.autoApproveNewDevices,
    required this.autoConnectEnabled,
    this.protocolVersion = 1,
    this.capabilities = const PeerCapabilities(),
    this.displayTopology,
  });

  final DeviceData device;
  final List<String> trustedPeerIds;
  final bool autoApproveNewDevices;
  final bool autoConnectEnabled;
  final int protocolVersion;
  final PeerCapabilities capabilities;
  final RemoteInputTopology? displayTopology;

  bool trustsPeer(String peerId) {
    return trustedPeerIds.contains(peerId);
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'device': device.toJson(),
      'trustedPeerIds': trustedPeerIds,
      'autoApproveNewDevices': autoApproveNewDevices,
      'autoConnectEnabled': autoConnectEnabled,
      'protocolVersion': protocolVersion,
      'capabilities': capabilities.toJson(),
      if (displayTopology != null) 'displayTopology': displayTopology!.toJson(),
    };
  }

  String toJsonString() => jsonEncode(toJson());

  factory PeerProfile.fromJson(Map<String, dynamic> json) {
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

  static List<String> trustedPeersFromDiscovery(
      Map<String, String> attributes) {
    final raw = attributes['trustedPeers'];
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    return raw
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static bool autoConnectFromDiscovery(Map<String, String> attributes) {
    return attributes['autoConnect'] != '0';
  }
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

class PeerCapabilities {
  const PeerCapabilities({
    this.fileResumeV1 = false,
    this.fileTransferV3 = false,
    this.systemAudioSourceV1 = false,
    this.speakerSinkV1 = false,
    this.remoteInputSourceV1 = false,
    this.remoteInputSinkV1 = false,
    this.remoteInputTopologyV1 = false,
    this.audioGroupSourceV1 = false,
    this.audioGroupSinkV1 = false,
    this.audioGroupRejoinV1 = false,
    this.audioSyncClockV1 = false,
    this.audioChannelRoleV1 = false,
  });

  final bool fileResumeV1;
  final bool fileTransferV3;
  final bool systemAudioSourceV1;
  final bool speakerSinkV1;
  final bool remoteInputSourceV1;
  final bool remoteInputSinkV1;
  final bool remoteInputTopologyV1;
  final bool audioGroupSourceV1;
  final bool audioGroupSinkV1;
  final bool audioGroupRejoinV1;
  final bool audioSyncClockV1;
  final bool audioChannelRoleV1;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'fileResumeV1': fileResumeV1,
      'fileTransferV3': fileTransferV3,
      'systemAudioSourceV1': systemAudioSourceV1,
      'speakerSinkV1': speakerSinkV1,
      'remoteInputSourceV1': remoteInputSourceV1,
      'remoteInputSinkV1': remoteInputSinkV1,
      'remoteInputTopologyV1': remoteInputTopologyV1,
      'audioGroupSourceV1': audioGroupSourceV1,
      'audioGroupSinkV1': audioGroupSinkV1,
      'audioGroupRejoinV1': audioGroupRejoinV1,
      'audioSyncClockV1': audioSyncClockV1,
      'audioChannelRoleV1': audioChannelRoleV1,
    };
  }

  factory PeerCapabilities.fromJson(Map<String, dynamic> json) {
    return PeerCapabilities(
      fileResumeV1: json['fileResumeV1'] as bool? ?? false,
      fileTransferV3: json['fileTransferV3'] as bool? ?? false,
      systemAudioSourceV1: json['systemAudioSourceV1'] as bool? ?? false,
      speakerSinkV1: json['speakerSinkV1'] as bool? ?? false,
      remoteInputSourceV1: json['remoteInputSourceV1'] as bool? ?? false,
      remoteInputSinkV1: json['remoteInputSinkV1'] as bool? ?? false,
      remoteInputTopologyV1: json['remoteInputTopologyV1'] as bool? ?? false,
      audioGroupSourceV1: json['audioGroupSourceV1'] as bool? ?? false,
      audioGroupSinkV1: json['audioGroupSinkV1'] as bool? ?? false,
      audioGroupRejoinV1: json['audioGroupRejoinV1'] as bool? ?? false,
      audioSyncClockV1: json['audioSyncClockV1'] as bool? ?? false,
      audioChannelRoleV1: json['audioChannelRoleV1'] as bool? ?? false,
    );
  }
}
