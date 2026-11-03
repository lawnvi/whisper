import 'dart:io';

import 'package:flutter/material.dart';
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
              ? _FirstDevice(onConnect: onOpenSelf)
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
            padding: const EdgeInsets.fromLTRB(10, 6, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Pressable(
                    onTap: onOpenSelf,
                    radius: WhisperRadius.s,
                    label: self?.name,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 5,
                      ),
                      child: Row(
                        children: [
                          DeviceGlyph(
                            kind: self == null
                                ? DeviceKind.laptop
                                : deviceKindOf(self),
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

class _FirstDevice extends StatelessWidget {
  const _FirstDevice({required this.onConnect});

  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: false);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.shellFirstDevice,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: type.body, color: c.ink2Glass),
            ),
            const SizedBox(height: 12),
            ShellFilledButton(label: l10n.shellConnectDevice, onTap: onConnect),
          ],
        ),
      ),
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
  final List<ContextMenuActionItem> Function(DeviceData) contextActions;

  static const _gap = 2.0;

  @override
  Widget build(BuildContext context) {
    // Two lines of text grow with the system's text size. The row stays one
    // height throughout, or the selection could not slide by index.
    final rowHeight = MediaQuery.textScalerOf(context).scale(touch ? 68 : 54);
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
                child: _DeviceRow(
                  session: row,
                  height: rowHeight,
                  facts: factsFor(row),
                  paired: isPaired(row.device),
                  selected: row.device.uid == selectedPeerId,
                  second: second,
                  touch: touch,
                  edgeToEdge: edgeToEdge,
                  first: i == 0,
                  onTap: () => onSelect(row.device.uid),
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
  Widget build(BuildContext context) {
    final radius = touch ? WhisperRadius.m : WhisperRadius.s;
    final brightness = Theme.of(context).brightness;
    return CustomPaint(
      painter: WhisperOutsideShadow(
        shadows: WhisperShadow.sidebarSelected(brightness),
        radius: radius,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.wc.sidebarSelected,
          borderRadius: BorderRadius.circular(radius),
          border: Border(
            top: BorderSide(
              width: .5,
              color: WhisperShadow.highlight(brightness),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.session,
    required this.height,
    required this.facts,
    required this.paired,
    required this.selected,
    required this.second,
    required this.onTap,
    this.touch = false,
    this.edgeToEdge = false,
    this.first = false,
  });

  final ChatSessionItem session;
  final double height;
  final DeviceRowFacts facts;
  final bool paired, selected, touch, edgeToEdge, first;
  final Color second;
  final VoidCallback onTap;

  DeviceArtState get _artState {
    if (session.isConnected) return DeviceArtState.normal;
    if (!session.isNearby) return DeviceArtState.offline;
    return paired ? DeviceArtState.nearby : DeviceArtState.normal;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    final type = WhisperType(touch: touch);
    final device = session.device;
    final live = deviceRowLineIsLive(deviceRowLine(facts));
    // What is gone steps back, words too: nearby and offline read differently at
    // a glance, before the words are read. Not while its row is the chosen one.
    final gone = !session.isConnected && !session.isNearby && !selected;
    // Every device in the same tile: a tall phone beside a wide computer does not
    // line up on its own. 1.25 times on touch.
    final big = touch ? 1.25 : 1.0;
    final row = Pressable(
      key: ShellFlyTargets.keyFor(device.uid),
      onTap: onTap,
      radius: edgeToEdge
          ? 0
          : touch
          ? WhisperRadius.m
          : WhisperRadius.s,
      selected: selected,
      scale: 1,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: edgeToEdge
              ? const EdgeInsets.fromLTRB(18, 0, 16, 0)
              : EdgeInsets.symmetric(horizontal: touch ? 12 : 10),
          child: Row(
            children: [
              Container(
                width: touch ? 44 : 36,
                height: touch ? 44 : 36,
                alignment: Alignment.center,
                decoration: ShapeDecoration(
                  color: c.fill,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(
                      touch ? WhisperRadius.m : WhisperRadius.s,
                    ),
                  ),
                ),
                child: deviceArtFor(
                  device,
                  size: (deviceKindOf(device).handheld ? 24 : 26) * big,
                  state: _artState,
                  paired: paired,
                ),
              ),
              SizedBox(
                width: edgeToEdge
                    ? 14
                    : touch
                    ? 12
                    : 10,
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: type.body,
                        fontWeight: FontWeight.w500,
                        color: gone ? second : c.ink,
                        height: 1.25,
                      ),
                    ),
                    SizedBox(height: touch ? 4 : 3),
                    Text(
                      deviceRowText(l10n, facts),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: type.note,
                        height: 1.25,
                        fontWeight: live ? FontWeight.w500 : FontWeight.w400,
                        color: live
                            ? c.accent
                            : gone && second != c.ink2Glass
                            ? c.ink3
                            : gone
                            ? c.ink2
                            : second,
                      ),
                    ),
                  ],
                ),
              ),
              if (edgeToEdge) ...[
                const SizedBox(width: 10),
                WhisperIcon(
                  WhisperGlyph.right,
                  size: 14,
                  weight: 2,
                  color: c.ink3,
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (!edgeToEdge || first) return row;
    // A phone's rows are tall and have no hover: a line parts them, lined up
    // with the text.
    return Stack(
      children: [
        row,
        Positioned(
          left: 76,
          right: 0,
          top: 0,
          height: 1 / MediaQuery.devicePixelRatioOf(context),
          child: IgnorePointer(child: ColoredBox(color: c.sep)),
        ),
      ],
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
