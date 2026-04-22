import 'dart:convert';

import 'package:whisper/model/LocalDatabase.dart';

class PeerProfile {
  const PeerProfile({
    required this.device,
    required this.trustedPeerIds,
    required this.autoApproveNewDevices,
    required this.autoConnectEnabled,
    this.protocolVersion = 1,
    this.capabilities = const PeerCapabilities(),
  });

  final DeviceData device;
  final List<String> trustedPeerIds;
  final bool autoApproveNewDevices;
  final bool autoConnectEnabled;
  final int protocolVersion;
  final PeerCapabilities capabilities;

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
      );
    }

    return PeerProfile(
      device: DeviceData.fromJson(json),
      trustedPeerIds: const [],
      autoApproveNewDevices: json['auth'] as bool? ?? false,
      autoConnectEnabled: true,
      protocolVersion: 1,
      capabilities: const PeerCapabilities(),
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

class PeerCapabilities {
  const PeerCapabilities({
    this.fileResumeV1 = false,
  });

  final bool fileResumeV1;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'fileResumeV1': fileResumeV1,
    };
  }

  factory PeerCapabilities.fromJson(Map<String, dynamic> json) {
    return PeerCapabilities(
      fileResumeV1: json['fileResumeV1'] as bool? ?? false,
    );
  }
}
