import 'dart:io';

import 'package:flutter/material.dart';
import 'package:whisper/new_ui/shell/shell_device_drop.dart';
import 'package:whisper/page/remote_files/remote_files_page.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/device_row_status.dart';
import 'package:whisper/new_ui/shell/shell_data.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/state/chat_session_list.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/context_menu_region.dart';

/// docs/design/surfaces.md「侧栏」.
class ShellSidebar extends StatelessWidget {
  const ShellSidebar({
    super.key,
    required this.data,
    required this.actions,
    required this.order,
    required this.material,
    required this.leftButtonsWidth,
    required this.onOpenSearch,
    required this.onOpenSelf,
    required this.onOpenCard,
  });

  final ShellData data;
  final ShellActions actions;

  /// Device ids in [StableDeviceOrder]'s order.
  final List<String> order;
  final bool material;
  final double leftButtonsWidth;
  final VoidCallback onOpenSearch, onOpenSelf;
  final ValueChanged<DeviceData> onOpenCard;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: false);
    final second = material ? c.ink2Glass : c.ink2;
    final mac = Platform.isMacOS;
    final self = data.self;
    final byId = {for (final s in data.sessions) s.device.uid: s};
    final rows = [
      for (final id in order)
        if (byId[id] != null) byId[id]!,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ToolbarBand(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              mac ? 86 : (leftButtonsWidth > 0 ? leftButtonsWidth + 8 : 20),
              10,
              10,
              10,
            ),
            child: Row(
              children: [
                if (!mac && leftButtonsWidth == 0)
                  Text(
                    'Whisper',
                    style: TextStyle(
                      fontSize: type.note,
                      fontWeight: FontWeight.w500,
                      color: c.ink2,
                    ),
                  ),
                const Spacer(),
                ShellIconButton(
                  glyph: WhisperGlyph.search,
                  label: l10n.shellSearch,
                  color: second,
                  onTap: onOpenSearch,
                ),
                if (data.soundSupported) ...[
                  const SizedBox(width: 2),
                  ShellIconButton(
                    glyph: WhisperGlyph.speaker,
                    label: l10n.shellSound,
                    color: second,
                    active: data.soundActive,
                    selected: data.place == ShellPlace.sound,
                    onTap: actions.openSound,
                  ),
                ],
                if (data.inputSupported) ...[
                  const SizedBox(width: 2),
                  ShellIconButton(
                    glyph: WhisperGlyph.keyboard,
                    label: l10n.shellInput,
                    color: second,
                    active: data.inputActive,
                    selected: data.place == ShellPlace.input,
                    onTap: actions.openInput,
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: rows.isEmpty && !data.loading
              // The content says what to do: see ShellFirstDevice.
              ? const SizedBox.shrink()
              : _BottomEdge(
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      child: ShellDeviceRows(
                        rows: rows,
                        // Lets go on a page that is not about one device.
                        selectedPeerId: data.place == ShellPlace.device
                            ? data.selectedPeerId
                            : null,
                        factsFor: data.factsFor,
                        isPaired: data.isPaired,
                        second: second,
                        onSelect: (uid) => actions.select(uid),
                        onDropPaths: actions.sendDropped,
                        contextActions: (device) => actions.contextActions(
                          device,
                          openCard: () => onOpenCard(device),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 46),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: Pressable(
                    onTap: onOpenSelf,
                    radius: WhisperRadius.s,
                    label: self?.name,
                    child: Padding(
                      // The icon starts where the rows' pictures start.
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      child: Row(
                        children: [
                          DeviceGlyph(
                            kind: self == null
                                ? DeviceKind.laptop
                                : selfKindOf(self),
                            color: data.lanDown ? c.warn : second,
                            size: 18,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              self?.name ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: type.note,
                                fontWeight: FontWeight.w500,
                                color: c.ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (data.linksSupported)
                  ShellIconButton(
                    glyph: WhisperGlyph.link,
                    label: l10n.shellShareLinks,
                    color: second,
                    active: data.linksActive,
                    selected: data.place == ShellPlace.links,
                    onTap: actions.openShareLinks,
                  ),
                const SizedBox(width: 2),
                ShellIconButton(
                  glyph: WhisperGlyph.gear,
                  label: l10n.shellSettings,
                  color: second,
                  onTap: actions.openSettings,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The list. Each row is positioned by a spring, so a row that moves up slides
/// there instead of jumping, and one element slides behind the selected row.
class ShellDeviceRows extends StatelessWidget {
  const ShellDeviceRows({
    super.key,
    required this.rows,
    required this.selectedPeerId,
    required this.factsFor,
    required this.isPaired,
    required this.second,
    required this.onSelect,
    this.onDropPaths,
    required this.contextActions,
    this.touch = false,
    this.edgeToEdge = false,
  });

  /// `touch` density, wherever the list is.
  final bool touch;

  /// The phone's rows: edge to edge, parted by a line, no selection.
  final bool edgeToEdge;

  final List<ChatSessionItem> rows;
  final String? selectedPeerId;
  final DeviceRowFacts Function(ChatSessionItem) factsFor;
  final bool Function(DeviceData) isPaired;
  final Color second;
  final ValueChanged<String> onSelect;
  final void Function(DeviceData target, List<String> paths)? onDropPaths;
  final List<ContextMenuActionItem> Function(DeviceData) contextActions;

  static const _gap = 2.0;

  @override
  Widget build(BuildContext context) {
    // Two lines of text grow with the system's text size. The row stays one
    // height throughout, or the selection could not slide by index.
    final rowHeight = MediaQuery.textScalerOf(context).scale(touch ? 72 : 60);
    final step = rowHeight + _gap;
    final selectedIndex = rows.indexWhere(
      (row) => row.device.uid == selectedPeerId,
    );
    return SizedBox(
      height: rows.length * step,
      child: Stack(
        children: [
          if (selectedIndex >= 0)
            SpringBuilder(
              value: selectedIndex * step,
              spring: WhisperSprings.snappy,
              builder: (context, top, _) => Positioned(
                left: 0,
                right: 0,
                top: top,
                height: rowHeight,
                child: _SelectionBackground(touch: touch),
              ),
            ),
          for (final (i, row) in rows.indexed)
            SpringBuilder(
              key: ValueKey(row.device.uid),
              value: i * step,
              spring: WhisperSprings.smooth,
              child: ContextMenuRegion(
                items: contextActions(row.device),
                child: ShellDeviceDrop(
                  peerId: row.device.uid,
                  connected: row.isConnected,
                  radius: touch ? WhisperRadius.l : WhisperRadius.m,
                  onPaths: onDropPaths == null
                      ? null
                      : (paths) => onDropPaths!(row.device, paths),
                  child: FilesDropBridgeTarget(
                    peerId: row.device.uid,
                    radius: touch ? WhisperRadius.l : WhisperRadius.m,
                    child: _DeviceRow(
                      session: row,
                      height: rowHeight,
                      facts: factsFor(row),
                      selected: row.device.uid == selectedPeerId,
                      touch: touch,
                      edgeToEdge: edgeToEdge,
                      onTap: () => onSelect(row.device.uid),
                    ),
                  ),
                ),
              ),
              builder: (context, top, child) => Positioned(
                left: 0,
                right: 0,
                top: top,
                height: rowHeight,
                child: child!,
              ),
            ),
        ],
      ),
    );
  }
}

class _SelectionBackground extends StatelessWidget {
  const _SelectionBackground({this.touch = false});

  final bool touch;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.wc.deviceSelected,
      borderRadius: BorderRadius.circular(
        touch ? WhisperRadius.l : WhisperRadius.m,
      ),
    ),
  );
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.session,
    required this.height,
    required this.facts,
    required this.selected,
    required this.onTap,
    this.touch = false,
    this.edgeToEdge = false,
  });

  final ChatSessionItem session;
  final double height;
  final DeviceRowFacts facts;
  final bool selected, touch, edgeToEdge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    final device = session.device;
    final live = deviceRowLineIsLive(deviceRowLine(facts));
    final avatar = touch ? 48.0 : 38.0;
    final state = session.isConnected || session.isSelf
        ? c.deviceOn
        : session.isNearby
        ? c.deviceNear
        : null;
    return Pressable(
      key: ShellFlyTargets.keyFor(device.uid),
      onTap: onTap,
      radius: edgeToEdge
          ? 0
          : touch
          ? WhisperRadius.l
          : WhisperRadius.m,
      selected: selected,
      scale: 1,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: edgeToEdge
              ? const EdgeInsets.fromLTRB(16, 0, 16, 0)
              : const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Tooltip(
                message: touch ? '' : deviceSystemName(device.platform) ?? '',
                child: Container(
                  width: avatar,
                  height: avatar,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: state ?? c.deviceOff,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    session.avatarLabel.toUpperCase(),
                    style: TextStyle(
                      fontSize: touch ? 20 : 16,
                      fontWeight: FontWeight.w600,
                      height: 1,
                      color: Radix.white,
                    ),
                  ),
                ),
              ),
              SizedBox(width: touch ? 14 : 11),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            device.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: touch ? 17 : 14,
                              fontWeight: FontWeight.w600,
                              color: c.deviceName,
                              height: 1.25,
                            ),
                          ),
                        ),
                        if (facts.lastMessage case final time?) ...[
                          const SizedBox(width: 6),
                          Text(
                            time,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: touch ? 12 : 11,
                              height: 1.25,
                              color: c.deviceMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                    SizedBox(height: touch ? 5 : 4),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: state ?? c.deviceOffDot,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            deviceRowText(l10n, facts),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: touch ? 13 : 12,
                              height: 1.25,
                              fontWeight: live
                                  ? FontWeight.w500
                                  : FontWeight.w400,
                              color: live ? c.accentText : c.deviceMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A hairline where rows go under the bottom strip, only while some do: a row cut
/// off with nothing there looks like something is covering it.
class _BottomEdge extends StatefulWidget {
  const _BottomEdge({required this.child});

  final Widget child;

  @override
  State<_BottomEdge> createState() => _BottomEdgeState();
}

class _BottomEdgeState extends State<_BottomEdge> {
  bool _more = false;

  bool _update(ScrollMetrics metrics) {
    final more = metrics.extentAfter > 0;
    if (more != _more) setState(() => _more = more);
    return false;
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(
          width: 1 / MediaQuery.devicePixelRatioOf(context),
          color: _more ? context.wc.sep : Colors.transparent,
        ),
      ),
    ),
    child: NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _update(n.metrics),
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (n) => _update(n.metrics),
        child: widget.child,
      ),
    ),
  );
}
