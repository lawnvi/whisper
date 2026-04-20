import 'package:flutter/material.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/theme/app_theme.dart';

class DeviceWorkspaceSection {
  const DeviceWorkspaceSection({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.items,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final List<DeviceWorkspaceItemData> items;
}

class DeviceWorkspaceItemData {
  const DeviceWorkspaceItemData({
    required this.device,
    required this.isConnected,
    required this.isNearby,
    required this.localTrust,
    required this.remoteTrust,
    required this.isSelected,
  });

  final DeviceData device;
  final bool isConnected;
  final bool isNearby;
  final bool localTrust;
  final bool remoteTrust;
  final bool isSelected;
}

class WorkspaceOverviewCard extends StatelessWidget {
  const WorkspaceOverviewCard({
    super.key,
    required this.connectedCount,
    required this.trustedCount,
    required this.totalPeers,
  });

  final int connectedCount;
  final int trustedCount;
  final int totalPeers;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Whisper Workspace',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '连接、信任、传输和会话围绕同一个工作区组织。',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  avatar: Icon(
                    Icons.wifi_rounded,
                    color: palette.connected,
                    size: 18,
                  ),
                  label: Text('$connectedCount active'),
                ),
                Chip(
                  avatar: Icon(
                    Icons.verified_user_rounded,
                    color: palette.trusted,
                    size: 18,
                  ),
                  label: Text('$trustedCount mutual trust'),
                ),
                Chip(
                  avatar: Icon(
                    Icons.radar_rounded,
                    color: colorScheme.primary,
                    size: 18,
                  ),
                  label: Text('$totalPeers peers'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class DeviceSectionCard extends StatelessWidget {
  const DeviceSectionCard({
    super.key,
    required this.section,
    required this.compact,
    required this.onSelectDevice,
    required this.onOpenChat,
    required this.onToggleConnection,
    required this.onOpenSettings,
  });

  final DeviceWorkspaceSection section;
  final bool compact;
  final ValueChanged<DeviceData> onSelectDevice;
  final ValueChanged<DeviceData> onOpenChat;
  final ValueChanged<DeviceData> onToggleConnection;
  final ValueChanged<DeviceData> onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(section.icon, size: 20),
                const SizedBox(width: 8),
                Text(
                  section.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const Spacer(),
                Text(
                  '${section.items.length}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              section.subtitle,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            for (final item in section.items)
              DeviceWorkspaceTile(
                data: item,
                compact: compact,
                onSelect: () => onSelectDevice(item.device),
                onOpenChat: () => onOpenChat(item.device),
                onToggleConnection: () => onToggleConnection(item.device),
                onOpenSettings: () => onOpenSettings(item.device),
              ),
          ],
        ),
      ),
    );
  }
}

class DeviceWorkspaceTile extends StatelessWidget {
  const DeviceWorkspaceTile({
    super.key,
    required this.data,
    required this.compact,
    required this.onSelect,
    required this.onOpenChat,
    required this.onToggleConnection,
    required this.onOpenSettings,
  });

  final DeviceWorkspaceItemData data;
  final bool compact;
  final VoidCallback onSelect;
  final VoidCallback onOpenChat;
  final VoidCallback onToggleConnection;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: data.isSelected
            ? colorScheme.primary.withValues(alpha: 0.08)
            : colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onSelect,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor:
                          colorScheme.primary.withValues(alpha: 0.12),
                      child: Icon(
                        platformIcon(data.device.platform),
                        color: data.isConnected
                            ? palette.connected
                            : colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            data.device.name,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${data.device.host}:${data.device.port}',
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (compact)
                      IconButton(
                        icon: const Icon(Icons.chat_bubble_outline_rounded),
                        onPressed: onOpenChat,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    WorkspaceStatusChip(
                      label: data.isConnected
                          ? 'Connected'
                          : data.isNearby
                              ? 'Nearby'
                              : 'Offline',
                      color: data.isConnected
                          ? palette.connected
                          : data.isNearby
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                    ),
                    if (data.localTrust)
                      WorkspaceStatusChip(
                        label: data.remoteTrust ? 'Mutual trust' : 'Trusted',
                        color: data.remoteTrust
                            ? palette.trusted
                            : palette.warning,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: onToggleConnection,
                      icon: Icon(
                        data.isConnected
                            ? Icons.link_off_rounded
                            : Icons.wifi_find_rounded,
                      ),
                      label: Text(data.isConnected ? 'Disconnect' : 'Connect'),
                    ),
                    OutlinedButton.icon(
                      onPressed: onOpenChat,
                      icon: const Icon(Icons.chat_bubble_outline_rounded),
                      label: const Text('Chat'),
                    ),
                    if (!compact)
                      IconButton(
                        tooltip: '更多设置',
                        onPressed: onOpenSettings,
                        icon: const Icon(Icons.tune_rounded),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WorkspaceStatusChip extends StatelessWidget {
  const WorkspaceStatusChip({
    super.key,
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class DeviceWorkspaceDetail extends StatelessWidget {
  const DeviceWorkspaceDetail({
    super.key,
    required this.selectedDevice,
    required this.isConnected,
    required this.isNearby,
    required this.localTrust,
    required this.remoteTrust,
    required this.onOpenChat,
    required this.onToggleConnection,
    required this.onOpenSettings,
  });

  final DeviceData? selectedDevice;
  final bool isConnected;
  final bool isNearby;
  final bool localTrust;
  final bool remoteTrust;
  final VoidCallback onOpenChat;
  final VoidCallback onToggleConnection;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    if (selectedDevice == null) {
      return Center(
        child: Text(
          '选择一个设备开始会话',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      );
    }

    final palette = context.whisperPalette;
    final colorScheme = Theme.of(context).colorScheme;
    final device = selectedDevice!;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor:
                          colorScheme.primary.withValues(alpha: 0.12),
                      child: Icon(
                        platformIcon(device.platform),
                        size: 28,
                        color: colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            device.name,
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${device.host}:${device.port}',
                            style:
                                TextStyle(color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    WorkspaceStatusChip(
                      label: isConnected ? 'Connected' : 'Ready',
                      color:
                          isConnected ? palette.connected : colorScheme.primary,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (localTrust)
                      WorkspaceStatusChip(
                        label: remoteTrust ? 'Mutual trust' : 'Trusted locally',
                        color: remoteTrust ? palette.trusted : palette.warning,
                      ),
                    if (isNearby)
                      WorkspaceStatusChip(
                        label: 'Nearby now',
                        color: colorScheme.primary,
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  '设备即会话入口。连接、信任、传输和历史消息都围绕这一个工作区收束。',
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: onOpenChat,
                      icon: const Icon(Icons.chat_rounded),
                      label: const Text('Open chat'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: onToggleConnection,
                      icon: Icon(
                        isConnected
                            ? Icons.link_off_rounded
                            : Icons.wifi_find_rounded,
                      ),
                      label: Text(isConnected ? 'Disconnect' : 'Connect'),
                    ),
                    OutlinedButton.icon(
                      onPressed: onOpenSettings,
                      icon: const Icon(Icons.settings_outlined),
                      label: const Text('Device settings'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
