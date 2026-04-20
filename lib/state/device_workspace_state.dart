import 'package:flutter/material.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/auto_connect_planner.dart';
import 'package:whisper/state/connection_models.dart';
import 'package:whisper/widget/device_workspace.dart';

class DeviceWorkspaceState {
  const DeviceWorkspaceState({
    required this.sections,
    required this.selectedDevice,
    required this.connectedCount,
    required this.trustedCount,
  });

  final List<DeviceWorkspaceSection> sections;
  final DeviceData? selectedDevice;
  final int connectedCount;
  final int trustedCount;
}

class DeviceWorkspaceStateBuilder {
  const DeviceWorkspaceStateBuilder._();

  static DeviceWorkspaceState build({
    required List<DeviceData> devices,
    required Map<String, DevicePresence> presences,
    required String? selectedPeerId,
    required String? activePeerId,
    required String connectedTitle,
    required String trustedTitle,
  }) {
    final connected = <DeviceWorkspaceItemData>[];
    final trusted = <DeviceWorkspaceItemData>[];
    final pending = <DeviceWorkspaceItemData>[];
    final nearby = <DeviceWorkspaceItemData>[];
    final history = <DeviceWorkspaceItemData>[];

    for (final item in devices) {
      final presence = presences[item.uid];
      final isConnected = activePeerId == item.uid;
      final isTrusted = presence?.locallyTrusted ?? item.auth;
      final isNearby = presence?.discovered ?? (item.around == true);
      final remoteTrusted = presence?.remotelyTrusted ?? false;
      final data = DeviceWorkspaceItemData(
        device: item,
        isConnected: isConnected,
        isNearby: isNearby,
        localTrust: isTrusted,
        remoteTrust: remoteTrusted,
        isSelected: selectedPeerId == item.uid,
      );

      if (isConnected) {
        connected.add(data);
      } else if (isTrusted) {
        trusted.add(data);
      } else if (isNearby && remoteTrusted) {
        pending.add(data);
      } else if (isNearby) {
        nearby.add(data);
      } else {
        history.add(data);
      }
    }

    final sections = <DeviceWorkspaceSection>[
      DeviceWorkspaceSection(
        title: connectedTitle,
        subtitle: '当前在线会话',
        icon: Icons.wifi_rounded,
        items: connected,
      ),
      DeviceWorkspaceSection(
        title: trustedTitle,
        subtitle: '双向信任设备优先自动直连',
        icon: Icons.verified_user_rounded,
        items: trusted,
      ),
      DeviceWorkspaceSection(
        title: 'Pending',
        subtitle: '对方信任你，但你还未标记为信任',
        icon: Icons.hourglass_bottom_rounded,
        items: pending,
      ),
      DeviceWorkspaceSection(
        title: 'Nearby',
        subtitle: '当前局域网内发现的设备',
        icon: Icons.radar_rounded,
        items: nearby,
      ),
      DeviceWorkspaceSection(
        title: 'History',
        subtitle: '离线但保留历史消息的设备',
        icon: Icons.history_rounded,
        items: history,
      ),
    ].where((section) => section.items.isNotEmpty).toList();

    return DeviceWorkspaceState(
      sections: sections,
      selectedDevice: _selectedDevice(
        devices: devices,
        selectedPeerId: selectedPeerId,
        activePeerId: activePeerId,
      ),
      connectedCount: connected.length,
      trustedCount:
          presences.values.where(AutoConnectPlanner.isMutuallyTrusted).length,
    );
  }

  static DeviceData? _selectedDevice({
    required List<DeviceData> devices,
    required String? selectedPeerId,
    required String? activePeerId,
  }) {
    if (devices.isEmpty) {
      return null;
    }

    if (selectedPeerId != null) {
      for (final item in devices) {
        if (item.uid == selectedPeerId) {
          return item;
        }
      }
    }

    if (activePeerId != null && activePeerId.isNotEmpty) {
      for (final item in devices) {
        if (item.uid == activePeerId) {
          return item;
        }
      }
    }

    return devices.first;
  }
}
