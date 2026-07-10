import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../state/chat_session_list.dart';
import '../state/connection_coordinator.dart';
import '../theme/app_theme.dart';
import 'app_empty_state.dart';
import 'app_interactive_tile.dart';
import 'context_menu_region.dart';

enum DeviceWorkbenchActionKind {
  manualConnect,
  audioShare,
  remoteInput,
  settings,
}

class DeviceWorkbenchAction {
  const DeviceWorkbenchAction({
    required this.kind,
    this.onPressed,
    this.disabledReason,
    this.active = false,
  }) : assert(
          onPressed != null || (disabledReason != null && disabledReason != ''),
          'Disabled actions need an explanation',
        );

  final DeviceWorkbenchActionKind kind;
  final VoidCallback? onPressed;
  final String? disabledReason;
  final bool active;

  bool get enabled => onPressed != null;
}

class DeviceWorkbenchPane extends StatefulWidget {
  const DeviceWorkbenchPane({
    super.key,
    required this.localDeviceName,
    required this.localPlatform,
    required this.localAddress,
    required this.discovery,
    required this.sessions,
    required this.candidates,
    required this.selectedPeerId,
    required this.actions,
    required this.onSelectSession,
    required this.onSelectCandidate,
    required this.onRetryDiscovery,
    this.sessionContextActions,
  });

  static const searchFieldKey = ValueKey<String>('device-workbench-search');

  final String localDeviceName;
  final String localPlatform;
  final String localAddress;
  final LocalDiscoveryPresentation discovery;
  final List<ChatSessionItem> sessions;
  final List<NearbyCandidatePresentation> candidates;
  final String? selectedPeerId;
  final List<DeviceWorkbenchAction> actions;
  final ValueChanged<ChatSessionItem> onSelectSession;
  final ValueChanged<NearbyCandidatePresentation> onSelectCandidate;
  final VoidCallback? onRetryDiscovery;
  final List<ContextMenuActionItem> Function(ChatSessionItem)?
      sessionContextActions;

  @override
  State<DeviceWorkbenchPane> createState() => _DeviceWorkbenchPaneState();
}

class _DeviceWorkbenchPaneState extends State<DeviceWorkbenchPane> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _focusSearch() {
    _searchFocusNode.requestFocus();
  }

  void _clearSearch() {
    if (_searchController.text.isEmpty) {
      _searchFocusNode.unfocus();
      return;
    }
    _searchController.clear();
    setState(() => _query = '');
    _searchFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
        ): _focusSearch,
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          meta: true,
        ): _focusSearch,
        const SingleActivator(LogicalKeyboardKey.escape): _clearSearch,
      },
      child: Focus(
        autofocus: true,
        child: FocusTraversalGroup(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showActionLabels = constraints.maxWidth >= 520;
              final filteredSessions = ChatSessionListBuilder.filter(
                widget.sessions,
                _query,
              );
              final filteredCandidates = widget.candidates
                  .where((candidate) => _candidateMatches(candidate, _query))
                  .toList(growable: false)
                ..sort(
                  (left, right) => right.lastSeenAt.compareTo(left.lastSeenAt),
                );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _LocalDiscoveryStatus(
                    localDeviceName: widget.localDeviceName,
                    localPlatform: widget.localPlatform,
                    localAddress: widget.localAddress,
                    discovery: widget.discovery,
                    onRetry: widget.onRetryDiscovery,
                  ),
                  _CommandBar(
                    actions: widget.actions,
                    showLabels: showActionLabels,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: _buildSearchField(context),
                  ),
                  Expanded(
                    child: _buildSessions(
                      context,
                      filteredSessions,
                      filteredCandidates,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: WhisperUi.minInteractiveSize,
      ),
      child: TextField(
        key: DeviceWorkbenchPane.searchFieldKey,
        controller: _searchController,
        focusNode: _searchFocusNode,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          labelText: l10n.workbenchActionSearch,
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: _query.isEmpty
              ? null
              : Tooltip(
                  message: l10n.workbenchActionClearSearch,
                  child: IconButton(
                    onPressed: _clearSearch,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
        ),
        onChanged: (value) => setState(() => _query = value),
      ),
    );
  }

  Widget _buildSessions(
    BuildContext context,
    List<ChatSessionItem> sessions,
    List<NearbyCandidatePresentation> candidates,
  ) {
    final l10n = AppLocalizations.of(context)!;
    if (widget.sessions.isEmpty && widget.candidates.isEmpty) {
      final manualAction = widget.actions
          .where(
            (action) => action.kind == DeviceWorkbenchActionKind.manualConnect,
          )
          .firstOrNull;
      return AppEmptyState(
        icon: Icons.devices_outlined,
        title: l10n.emptyDevicesTitle,
        body: l10n.emptyDevicesBody,
        actionLabel: manualAction?.enabled == true
            ? l10n.workbenchActionManualConnect
            : null,
        onAction: manualAction?.onPressed,
      );
    }
    if (sessions.isEmpty && candidates.isEmpty) {
      return AppEmptyState(
        icon: Icons.search_off_rounded,
        title: l10n.emptySearchTitle,
        body: l10n.emptySearchBody,
        actionLabel: l10n.emptySearchClear,
        onAction: _clearSearch,
      );
    }

    final sections = ChatSessionListBuilder.group(sessions);
    final byKind = <ChatSessionSectionKind, ChatSessionSection>{
      for (final section in sections) section.kind: section,
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      children: <Widget>[
        for (final kind in ChatSessionSectionKind.values)
          if ((byKind[kind]?.items.isNotEmpty ?? false) ||
              (kind == ChatSessionSectionKind.nearby && candidates.isNotEmpty))
            _SessionSection(
              kind: kind,
              sessions: byKind[kind]?.items ?? const <ChatSessionItem>[],
              candidates: kind == ChatSessionSectionKind.nearby
                  ? candidates
                  : const <NearbyCandidatePresentation>[],
              selectedPeerId: widget.selectedPeerId,
              onSelectSession: widget.onSelectSession,
              onSelectCandidate: widget.onSelectCandidate,
              sessionContextActions: widget.sessionContextActions,
            ),
      ],
    );
  }

  bool _candidateMatches(NearbyCandidatePresentation candidate, String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return true;
    }
    return <String>[
      candidate.displayName ?? '',
      candidate.serviceName,
      candidate.publicKeyHash,
      candidate.endpoint.host,
      candidate.endpoint.port.toString(),
      candidate.platform ?? '',
    ].any((value) => value.toLowerCase().contains(normalized));
  }
}

class _LocalDiscoveryStatus extends StatelessWidget {
  const _LocalDiscoveryStatus({
    required this.localDeviceName,
    required this.localPlatform,
    required this.localAddress,
    required this.discovery,
    required this.onRetry,
  });

  final String localDeviceName;
  final String localPlatform;
  final String localAddress;
  final LocalDiscoveryPresentation discovery;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    final status = _statusText(l10n);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.borderSubtle)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    _platformIcon(localPlatform),
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        localDeviceName,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      SelectableText(
                        l10n.localDiscoveryAddress(localAddress),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (discovery.phase == LocalDiscoveryPhase.starting)
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      _statusIcon(),
                      size: 16,
                      color: _statusColor(context),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final compactRetry = constraints.maxWidth < 420 ||
                    MediaQuery.textScalerOf(context).scale(14) > 21;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        status,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.textMuted,
                        ),
                      ),
                    ),
                    if (discovery.canRetry && onRetry != null) ...<Widget>[
                      const SizedBox(width: 8),
                      if (compactRetry)
                        SizedBox.square(
                          dimension: WhisperUi.minInteractiveSize,
                          child: Tooltip(
                            message: l10n.workbenchActionRetryDiscovery,
                            child: IconButton(
                              onPressed: onRetry,
                              icon: const Icon(Icons.refresh_rounded),
                            ),
                          ),
                        )
                      else
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: WhisperUi.minInteractiveSize,
                          ),
                          child: TextButton.icon(
                            onPressed: onRetry,
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: Text(l10n.workbenchActionRetryDiscovery),
                          ),
                        ),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _statusText(AppLocalizations l10n) {
    final error = discovery.errorMessage;
    if (error?.isNotEmpty ?? false) {
      return l10n.localDiscoveryFailed(error!);
    }
    return switch (discovery.phase) {
      LocalDiscoveryPhase.starting => l10n.localDiscoveryStarting,
      LocalDiscoveryPhase.active => l10n.localDiscoveryActive,
      LocalDiscoveryPhase.stopped => l10n.localDiscoveryStopped,
      LocalDiscoveryPhase.unavailable => l10n.localDiscoveryUnavailable,
      LocalDiscoveryPhase.permissionDenied =>
        l10n.localDiscoveryPermissionDenied,
      LocalDiscoveryPhase.permissionRestricted =>
        l10n.localDiscoveryPermissionRestricted,
    };
  }

  IconData _statusIcon() => switch (discovery.phase) {
        LocalDiscoveryPhase.active => Icons.wifi_rounded,
        LocalDiscoveryPhase.permissionDenied => Icons.wifi_off_rounded,
        LocalDiscoveryPhase.permissionRestricted => Icons.block_rounded,
        LocalDiscoveryPhase.unavailable => Icons.error_outline_rounded,
        LocalDiscoveryPhase.stopped => Icons.pause_circle_outline_rounded,
        LocalDiscoveryPhase.starting => Icons.sync_rounded,
      };

  Color _statusColor(BuildContext context) => switch (discovery.phase) {
        LocalDiscoveryPhase.active => context.whisperPalette.connected,
        LocalDiscoveryPhase.permissionDenied ||
        LocalDiscoveryPhase.permissionRestricted ||
        LocalDiscoveryPhase.unavailable =>
          context.whisperPalette.warning,
        LocalDiscoveryPhase.stopped ||
        LocalDiscoveryPhase.starting =>
          context.whisperPalette.textMuted,
      };
}

class _CommandBar extends StatelessWidget {
  const _CommandBar({required this.actions, required this.showLabels});

  final List<DeviceWorkbenchAction> actions;
  final bool showLabels;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final action in actions)
            _WorkbenchActionButton(
              action: action,
              showLabel: showLabels,
            ),
        ],
      ),
    );
  }
}

class _WorkbenchActionButton extends StatelessWidget {
  const _WorkbenchActionButton({
    required this.action,
    required this.showLabel,
  });

  final DeviceWorkbenchAction action;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = _label(l10n);
    final semanticLabel = action.enabled
        ? label
        : l10n.workbenchActionUnavailable(action.disabledReason!);
    final color = action.active ? Theme.of(context).colorScheme.primary : null;
    final button = showLabel
        ? FilledButton.tonalIcon(
            onPressed: action.onPressed,
            icon: Icon(_icon(), color: color),
            label: Text(label),
          )
        : SizedBox.square(
            dimension: WhisperUi.minInteractiveSize,
            child: IconButton(
              onPressed: action.onPressed,
              icon: Icon(_icon(), color: color),
            ),
          );
    return Semantics(
      key: ValueKey<String>('workbench-action-${action.kind.name}'),
      container: true,
      button: true,
      enabled: action.enabled,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: Tooltip(message: semanticLabel, child: button),
      ),
    );
  }

  String _label(AppLocalizations l10n) => switch (action.kind) {
        DeviceWorkbenchActionKind.manualConnect =>
          l10n.workbenchActionManualConnect,
        DeviceWorkbenchActionKind.audioShare => l10n.workbenchActionAudioShare,
        DeviceWorkbenchActionKind.remoteInput =>
          l10n.workbenchActionRemoteInput,
        DeviceWorkbenchActionKind.settings => l10n.workbenchActionSettings,
      };

  IconData _icon() => switch (action.kind) {
        DeviceWorkbenchActionKind.manualConnect => Icons.add_link_rounded,
        DeviceWorkbenchActionKind.audioShare => Icons.volume_up_outlined,
        DeviceWorkbenchActionKind.remoteInput => Icons.keyboard_alt_outlined,
        DeviceWorkbenchActionKind.settings => Icons.settings_outlined,
      };
}

class _SessionSection extends StatelessWidget {
  const _SessionSection({
    required this.kind,
    required this.sessions,
    required this.candidates,
    required this.selectedPeerId,
    required this.onSelectSession,
    required this.onSelectCandidate,
    required this.sessionContextActions,
  });

  final ChatSessionSectionKind kind;
  final List<ChatSessionItem> sessions;
  final List<NearbyCandidatePresentation> candidates;
  final String? selectedPeerId;
  final ValueChanged<ChatSessionItem> onSelectSession;
  final ValueChanged<NearbyCandidatePresentation> onSelectCandidate;
  final List<ContextMenuActionItem> Function(ChatSessionItem)?
      sessionContextActions;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final count = sessions.length + candidates.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text(
                    _title(l10n),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    l10n.sessionGroupDeviceCount(count),
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.whisperPalette.textMuted,
                        ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: context.whisperPalette.borderSubtle),
          const SizedBox(height: 4),
          for (final session in sessions)
            LayoutBuilder(
              builder: (context, constraints) {
                final scaledBodySize =
                    MediaQuery.textScalerOf(context).scale(14);
                final showTrailingTime = session.lastTimestamp > 0 &&
                    (scaledBodySize <= 21 || constraints.maxWidth >= 420);
                final tile = AppInteractiveTile(
                  semanticLabel: '${session.device.name}, ${session.preview}',
                  selected: session.device.uid == selectedPeerId,
                  onActivate: () => onSelectSession(session),
                  leading: Icon(_platformIcon(session.device.platform)),
                  title: Text(session.device.name),
                  subtitle: Text(session.preview),
                  trailing: showTrailingTime
                      ? Text(_formatTime(session.lastTimestamp))
                      : null,
                );
                final actions = sessionContextActions?.call(session) ??
                    const <ContextMenuActionItem>[];
                if (actions.isEmpty) {
                  return tile;
                }
                final row = Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(child: tile),
                    _SessionActionsMenu(
                      peerId: session.device.uid,
                      deviceName: session.device.name,
                      actions: actions,
                    ),
                  ],
                );
                return ContextMenuRegion(child: row, items: actions);
              },
            ),
          for (final candidate in candidates)
            AppInteractiveTile(
              semanticLabel:
                  '${candidate.displayName ?? l10n.localDiscoveryUnpairedCandidate}, ${l10n.localDiscoveryUnpairedCandidate}',
              onActivate: () => onSelectCandidate(candidate),
              leading: Icon(_platformIcon(candidate.platform ?? '')),
              title: Text(
                candidate.displayName ?? l10n.localDiscoveryUnpairedCandidate,
              ),
              subtitle: Text(
                '${l10n.localDiscoveryUnpairedCandidate} · ${_formatEndpoint(candidate)}',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
            ),
        ],
      ),
    );
  }

  String _title(AppLocalizations l10n) => switch (kind) {
        ChatSessionSectionKind.connected => l10n.sessionGroupConnected,
        ChatSessionSectionKind.nearby => l10n.sessionGroupNearby,
        ChatSessionSectionKind.recent => l10n.sessionGroupRecent,
      };
}

class _SessionActionsMenu extends StatefulWidget {
  const _SessionActionsMenu({
    required this.peerId,
    required this.deviceName,
    required this.actions,
  });

  final String peerId;
  final String deviceName;
  final List<ContextMenuActionItem> actions;

  @override
  State<_SessionActionsMenu> createState() => _SessionActionsMenuState();
}

class _SessionActionsMenuState extends State<_SessionActionsMenu> {
  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
  };

  final FocusNode _focusNode = FocusNode();
  final GlobalKey<PopupMenuButtonState<int>> _menuKey = GlobalKey();
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _showMenu() {
    _menuKey.currentState?.showButtonMenu();
  }

  @override
  Widget build(BuildContext context) {
    final label =
        '${MaterialLocalizations.of(context).moreButtonTooltip}: ${widget.deviceName}';
    return Semantics(
      key: ValueKey<String>('device-session-menu-${widget.peerId}'),
      container: true,
      excludeSemantics: true,
      button: true,
      enabled: true,
      focusable: true,
      focused: _focused,
      label: label,
      onFocus: _focusNode.requestFocus,
      onTap: _showMenu,
      child: FocusableActionDetector(
        focusNode: _focusNode,
        shortcuts: _shortcuts,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _showMenu();
              return null;
            },
          ),
        },
        onFocusChange: (focused) {
          if (_focused != focused) {
            setState(() => _focused = focused);
          }
        },
        child: SizedBox.square(
          dimension: WhisperUi.minInteractiveSize,
          child: Tooltip(
            message: label,
            child: PopupMenuButton<int>(
              key: _menuKey,
              requestFocus: true,
              tooltip: label,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              itemBuilder: (context) => <PopupMenuEntry<int>>[
                for (var index = 0; index < widget.actions.length; index += 1)
                  PopupMenuItem<int>(
                    value: index,
                    enabled: widget.actions[index].enabled,
                    child: Text(widget.actions[index].label),
                  ),
              ],
              onSelected: (index) => widget.actions[index].onSelected(),
            ),
          ),
        ),
      ),
    );
  }
}

IconData _platformIcon(String platform) => switch (platform.toLowerCase()) {
      'android' => Icons.android_rounded,
      'macos' || 'ios' => Icons.laptop_mac_rounded,
      'windows' => Icons.laptop_windows_rounded,
      _ => Icons.devices_other_rounded,
    };

String _formatTime(int timestamp) {
  final messageTime = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  final now = DateTime.now();
  if (messageTime.year == now.year &&
      messageTime.month == now.month &&
      messageTime.day == now.day) {
    return DateFormat('HH:mm').format(messageTime);
  }
  if (messageTime.year == now.year) {
    return DateFormat('MM/dd').format(messageTime);
  }
  return DateFormat('yyyy/MM/dd').format(messageTime);
}

String _formatEndpoint(NearbyCandidatePresentation candidate) {
  final host = candidate.endpoint.host;
  final formattedHost = host.contains(':') ? '[$host]' : host;
  return '$formattedHost:${candidate.endpoint.port}';
}
