import 'package:flutter/material.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/shell_data.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/state/chat_session_list.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// docs/design/surfaces.md「设备页」: a toolbar and three pages, each built
/// when first shown and then kept, so the composer and scroll position stay.
class ShellDevicePage extends StatelessWidget {
  const ShellDevicePage({
    super.key,
    required this.session,
    required this.actions,
    required this.paired,
    required this.connecting,
    required this.tab,
    required this.onTab,
    required this.cardOpen,
    required this.onToggleCard,
    required this.rightInset,
    this.titleKey,
    this.controlsKey,
    this.touch = false,
    this.compact = false,
    this.onBack,
  });

  /// Phone density, whatever the width. The toolbar has no window to move.
  final bool touch;

  /// The phone's toolbar: back, a title that opens the device page, and no tabs.
  final bool compact;
  final VoidCallback? onBack;

  final ChatSessionItem session;
  final ShellActions actions;
  final bool paired, connecting;
  final int tab;
  final ValueChanged<int> onTab;
  final bool cardOpen;
  final VoidCallback onToggleCard;

  /// Room for the window buttons.
  final double rightInset;

  /// So the island can keep clear of them.
  final GlobalKey? titleKey, controlsKey;

  DeviceData get device => session.device;

  @override
  Widget build(BuildContext context) => _ShellDevicePageBody(page: this);

  Widget _away(BuildContext context, String body) {
    final l10n = context.shellL10n;
    if (!paired && session.isNearby) {
      return ShellDeviceState(
        touch: touch,
        art: deviceArtFor(device, size: 84, paired: false),
        title: l10n.shellNearbyTitle(device.name),
        body: l10n.shellPairHint,
        action: ShellFilledButton(
          touch: touch,
          label: connecting ? l10n.shellConnecting : l10n.shellConnect,
          onTap: connecting ? null : () => actions.connect(device),
        ),
      );
    }
    return ShellDeviceState(
      touch: touch,
      art: deviceArtFor(
        device,
        size: 84,
        state: session.isNearby
            ? DeviceArtState.nearby
            : DeviceArtState.offline,
      ),
      title: l10n.shellNotConnected(device.name),
      body: body,
      action: ShellFilledButton(
        touch: touch,
        label: connecting ? l10n.shellConnecting : l10n.shellConnect,
        onTap: connecting ? null : () => actions.connect(device),
      ),
    );
  }
}

class _ShellDevicePageBody extends StatefulWidget {
  const _ShellDevicePageBody({required this.page});

  final ShellDevicePage page;

  @override
  State<_ShellDevicePageBody> createState() => _ShellDevicePageBodyState();
}

class _ShellDevicePageBodyState extends State<_ShellDevicePageBody> {
  /// The toolbar blends into the content until the content scrolls under it.
  bool _scrolled = false;

  bool _onScroll(ScrollMetrics metrics) {
    // The conversation is a reversed list: its top is the far end.
    final under = metrics.axisDirection == AxisDirection.up
        ? metrics.extentAfter > 0
        : metrics.pixels > 0;
    if (under != _scrolled) setState(() => _scrolled = under);
    return false;
  }

  /// A phone's bar: back, then the title that opens the device page, then what
  /// is left of the desktop's controls.
  Widget _compactBar(BuildContext context) {
    final page = widget.page;
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: true);
    final device = page.device;
    final session = page.session;
    final onDevice = page.tab == 0;
    final title = Text(
      key: page.titleKey,
      switch (page.tab) {
        1 => l10n.shellTabFiles,
        2 => l10n.shellTabApps,
        _ => device.name,
      },
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: type.head,
        height: 1.25,
        fontWeight: FontWeight.w600,
        color: c.ink,
      ),
    );
    final known = session.isConnected || page.paired || !session.isNearby;
    return SizedBox(
      height: 50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            ShellIconButton(
              glyph: WhisperGlyph.back,
              iconSize: 20,
              weight: 2,
              touch: true,
              color: c.accent,
              label: l10n.back,
              onTap: page.onBack,
            ),
            Expanded(
              child: onDevice && known
                  ? Pressable(
                      onTap: page.onToggleCard,
                      radius: WhisperRadius.xs,
                      scale: 1,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: SizedBox(
                          height: 48,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: title,
                          ),
                        ),
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: title,
                    ),
            ),
            if (onDevice && known) ...[
              if (page.actions.canControl?.call(device) ?? false)
                PhoneBarButton(
                  glyph: WhisperGlyph.keyboard,
                  iconSize: 21,
                  label: l10n.mobileControlTitle,
                  onTap: () => page.actions.openControl?.call(device),
                ),
              PhoneBarButton(
                key: page.controlsKey,
                glyph: WhisperGlyph.more,
                iconSize: 22,
                weight: 2.6,
                label: l10n.deviceDetailsTitle,
                onTap: page.onToggleCard,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// `.tb` on touch beside a sidebar: the tabs, with a target of 48, and no window
  /// to move.
  Widget _touchBar(BuildContext context) {
    final page = widget.page;
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: true);
    final device = page.device;
    final session = page.session;
    final known = session.isConnected || page.paired || !session.isNearby;
    return SizedBox(
      height: 50,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .34,
                ),
                child: Text(
                  key: page.titleKey,
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: type.head,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
              ),
              const Spacer(),
              if (known) ...[
                LiquidSegmented<int>(
                  key: page.controlsKey,
                  height: 36,
                  fontSize: type.note,
                  segmentPadding: 16,
                  hitExtend: 6,
                  segments: {
                    0: l10n.shellTabChat,
                    1: l10n.shellTabFiles,
                    2: l10n.shellTabApps,
                  },
                  selected: page.tab,
                  onChanged: page.onTab,
                ),
                if (page.actions.canControl?.call(device) ?? false)
                  PhoneBarButton(
                    glyph: WhisperGlyph.keyboard,
                    iconSize: 21,
                    label: l10n.mobileControlTitle,
                    onTap: () => page.actions.openControl?.call(device),
                  ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: page.cardOpen ? c.fill : null,
                    borderRadius: BorderRadius.circular(WhisperRadius.xs),
                  ),
                  child: PhoneBarButton(
                    glyph: WhisperGlyph.info,
                    iconSize: 17,
                    label: l10n.shellDeviceInfo,
                    onTap: page.onToggleCard,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: false);
    final device = page.device;
    final session = page.session;
    final hairline = 1 / MediaQuery.devicePixelRatioOf(context);
    final actions = page.actions;
    // On a phone a connected device's files and apps are pages with their own
    // bar, with what they need at its end.
    final ownBar = page.compact && page.tab != 0 && session.isConnected;
    return SpringBuilder(
      from: 0,
      value: 1,
      spring: WhisperSprings.smooth,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, 5 * (1 - t)),
          child: child,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!ownBar)
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    width: hairline,
                    color: _scrolled ? c.sep : Colors.transparent,
                  ),
                ),
              ),
              child: page.touch
                  ? SafeArea(
                      bottom: false,
                      child: page.compact
                          ? _compactBar(context)
                          : _touchBar(context),
                    )
                  : ToolbarBand(
                      child: SpringBuilder(
                        value: page.rightInset,
                        spring: WhisperSprings.smooth,
                        builder: (context, right, child) => Padding(
                          padding: EdgeInsets.fromLTRB(20, 0, 12 + right, 0),
                          child: child,
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) => Row(
                            children: [
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: constraints.maxWidth * .34,
                                ),
                                child: Text(
                                  key: page.titleKey,
                                  device.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: type.head,
                                    height: 1.25,
                                    fontWeight: FontWeight.w600,
                                    color: c.ink,
                                  ),
                                ),
                              ),
                              const Spacer(),
                              if (session.isConnected ||
                                  page.paired ||
                                  !session.isNearby) ...[
                                LiquidSegmented<int>(
                                  key: page.controlsKey,
                                  segments: {
                                    0: l10n.shellTabChat,
                                    1: l10n.shellTabFiles,
                                    2: l10n.shellTabApps,
                                  },
                                  selected: page.tab,
                                  onChanged: page.onTab,
                                ),
                                const SizedBox(width: 6),
                                ShellIconButton(
                                  glyph: WhisperGlyph.info,
                                  iconSize: 17,
                                  label: l10n.shellDeviceInfo,
                                  pressed: page.cardOpen,
                                  onTap: page.onToggleCard,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                // No Scaffold here to do this: the keyboard moves the page and
                // not the list beside it.
                bottom: page.touch
                    ? MediaQuery.viewInsetsOf(context).bottom
                    : 0,
              ),
              child: MediaQuery.removeViewInsets(
                context: context,
                removeBottom: page.touch,
                // The toolbar has the status bar. Pages built for a stack of
                // their own would leave room for it again.
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: page.touch && !ownBar,
                  child: NotificationListener<ScrollMetricsNotification>(
                    onNotification: (n) => _onScroll(n.metrics),
                    child: NotificationListener<ScrollUpdateNotification>(
                      onNotification: (n) => _onScroll(n.metrics),
                      child:
                          !session.isConnected &&
                              !page.paired &&
                              session.isNearby
                          ? page._away(context, l10n.shellNotConnectedFiles)
                          : WhisperTabView(
                              index: page.tab,
                              itemCount: 3,
                              itemBuilder: (context, i) => switch (i) {
                                0 => actions.buildConversation(context, device),
                                1 =>
                                  session.isConnected
                                      ? actions.buildFiles(context, device)
                                      : page._away(
                                          context,
                                          l10n.shellNotConnectedFiles,
                                        ),
                                _ =>
                                  session.isConnected
                                      ? actions.buildApps(context, device)
                                      : page._away(
                                          context,
                                          l10n.shellNotConnectedApps,
                                        ),
                              },
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
