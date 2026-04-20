import 'dart:convert';

import 'package:whisper/model/LocalDatabase.dart';

class PeerProfile {
  const PeerProfile({
    required this.device,
    required this.trustedPeerIds,
    required this.autoApproveNewDevices,
    required this.autoConnectEnabled,
  });

  final DeviceData device;
  final List<String> trustedPeerIds;
  final bool autoApproveNewDevices;
  final bool autoConnectEnabled;

  bool trustsPeer(String peerId) {
    return trustedPeerIds.contains(peerId);
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'device': device.toJson(),
      'trustedPeerIds': trustedPeerIds,
      'autoApproveNewDevices': autoApproveNewDevices,
      'autoConnectEnabled': autoConnectEnabled,
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
      );
    }

    return PeerProfile(
      device: DeviceData.fromJson(json),
      trustedPeerIds: const [],
      autoApproveNewDevices: json['auth'] as bool? ?? false,
      autoConnectEnabled: true,
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
