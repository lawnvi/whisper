import 'package:flutter/material.dart';
import 'package:whisper/model/LocalDatabase.dart';
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

  Widget _away(BuildContext context) {
    final l10n = context.shellL10n;
    if (!paired && session.isNearby) {
      return ShellDeviceState(
        touch: touch,
        art: deviceArtFor(device, size: 84, paired: false),
        title: l10n.shellNearbyTitle(device.name),
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

  /// Connect or disconnect: said once, in the toolbar, and not in the composer.
  /// Blue is what can be done, red is letting go.
  Widget _connection(BuildContext context) {
    final page = widget.page;
    final c = context.wc;
    final l10n = context.shellL10n;
    final device = page.device;
    final connected = page.session.isConnected;
    final busy = !connected && page.connecting;
    return ShellToolCapsuleItem(
      key: const ValueKey('device-connection'),
      glyph: WhisperGlyph.power,
      touch: page.touch,
      weight: 1.8,
      busy: busy,
      color: connected ? c.bad : c.accentText,
      label: connected
          ? l10n.shellCardDisconnect
          : busy
          ? l10n.shellConnecting
          : l10n.shellConnect,
      onTap: () => connected
          ? page.actions.disconnect(device)
          : page.actions.connect(device),
    );
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
              color: c.ink,
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
            if (onDevice && known)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ShellToolCapsule(
                  key: page.controlsKey,
                  touch: true,
                  children: [
                    _connection(context),
                    ShellToolCapsuleItem(
                      glyph: WhisperGlyph.more,
                      touch: true,
                      iconSize: 20,
                      weight: 2.6,
                      color: c.ink,
                      label: l10n.deviceDetailsTitle,
                      onTap: page.onToggleCard,
                    ),
                  ],
                ),
              ),
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
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              // What the controls leave, up to a third of the bar.
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
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
                ),
              ),
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
                const SizedBox(width: 6),
                ShellToolCapsule(
                  touch: true,
                  children: [
                    _connection(context),
                    ShellToolCapsuleItem(
                      glyph: WhisperGlyph.info,
                      touch: true,
                      color: c.ink,
                      selected: page.cardOpen,
                      label: l10n.shellDeviceInfo,
                      onTap: page.onToggleCard,
                    ),
                  ],
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
    final body = Column(
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
                        padding: EdgeInsets.fromLTRB(16, 0, 16 + right, 0),
                        child: child,
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) => Row(
                          children: [
                            // What the controls leave, up to a third of the
                            // bar.
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: ConstrainedBox(
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
                              ),
                            ),
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
                              ShellToolCapsule(
                                children: [
                                  _connection(context),
                                  ShellToolCapsuleItem(
                                    glyph: WhisperGlyph.info,
                                    color: c.ink,
                                    selected: page.cardOpen,
                                    label: l10n.shellDeviceInfo,
                                    onTap: page.onToggleCard,
                                  ),
                                ],
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
              bottom: page.touch ? MediaQuery.viewInsetsOf(context).bottom : 0,
            ),
            // One MediaQuery: two nested from the same context would put back
            // what the first took off, and the keyboard would count twice.
            child: MediaQuery(
              data: MediaQuery.of(context)
                  .removeViewInsets(removeBottom: page.touch)
                  // The toolbar has the status bar. Pages built for a stack of
                  // their own would leave room for it again.
                  .removePadding(removeTop: page.touch && !ownBar),
              child: Builder(
                builder: (context) =>
                    NotificationListener<ScrollMetricsNotification>(
                      onNotification: (n) => _onScroll(n.metrics),
                      child: NotificationListener<ScrollUpdateNotification>(
                        onNotification: (n) => _onScroll(n.metrics),
                        child:
                            !session.isConnected &&
                                !page.paired &&
                                session.isNearby
                            ? page._away(context)
                            : WhisperTabView(
                                index: page.tab,
                                itemCount: 3,
                                contentKey: (device, session.isConnected),
                                heavyPages: true,
                                resetKey: session.isConnected,
                                keptPages: const {0},
                                itemBuilder: (context, i) => switch (i) {
                                  0 => actions.buildConversation(
                                    context,
                                    device,
                                  ),
                                  1 =>
                                    session.isConnected
                                        ? actions.buildFiles(context, device)
                                        : page._away(context),
                                  _ =>
                                    session.isConnected
                                        ? actions.buildApps(context, device)
                                        : page._away(context),
                                },
                              ),
                      ),
                    ),
              ),
            ),
          ),
        ),
      ],
    );
    // On touch the page slides in by itself. Fading it as well would draw the whole
    // screen to one side first, on every frame of the way in, glass and all.
    if (page.touch) return body;
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
      child: body,
    );
  }
}
