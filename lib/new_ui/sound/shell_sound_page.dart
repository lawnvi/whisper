import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:whisper/audio/audio_failure_reason.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/share/share_parts.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/sound/sound_controller.dart';
import 'package:whisper/new_ui/sound/sound_rules.dart';
import 'package:whisper/state/chat_session_list.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/island/island_home.dart';

const _maxColumn = 620.0;
const _narrowColumn = 520.0;

/// docs/design/surfaces.md「声音」: playing this device's sound on others, or
/// another device's sound here. Fills the area right of the sidebar, toolbar
/// included.
class ShellSoundPage extends StatefulWidget {
  const ShellSoundPage({
    super.key,
    required this.rightInset,
    required this.selfDevice,
    required this.sessions,
    this.controller,
    this.titleKey,
    this.controlsKey,
  });

  /// Room for the window buttons, as on a device's page.
  final double rightInset;
  final DeviceData? selfDevice;

  /// Every device in the sidebar's order. Only connected and nearby ones show.
  final List<ChatSessionItem> sessions;
  final ShellSoundController? controller;
  final GlobalKey? titleKey, controlsKey;

  @override
  State<ShellSoundPage> createState() => _ShellSoundPageState();
}

class _ShellSoundPageState extends State<ShellSoundPage> {
  late final ShellSoundController _controller =
      widget.controller ?? ShellSoundController.shared;
  final _scroll = ScrollController();
  bool _scrolled = false;

  @override
  void initState() {
    super.initState();
    _controller.attach();
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    final scrolled = _scroll.hasClients && _scroll.offset > 0;
    if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
  }

  @override
  void dispose() {
    _controller.detach();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    return IslandHome(
      home: IslandHomes.sound,
      child: ColoredBox(
        color: c.canvas,
        child: Material(
          type: MaterialType.transparency,
          child: ShareEntrance(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ShareToolbar(
                  title: l10n.shellSound,
                  rightInset: widget.rightInset,
                  titleKey: widget.titleKey,
                  controlsKey: widget.controlsKey,
                ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ListenableBuilder(
                        listenable: _controller,
                        builder: (context, _) => LayoutBuilder(
                          builder: (context, constraints) {
                            final column = math.min(
                              _maxColumn,
                              math.max(0.0, constraints.maxWidth - 40),
                            );
                            final sink = _controller.sinkView;
                            return SingleChildScrollView(
                              controller: _scroll,
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                              child: Center(
                                child: SizedBox(
                                  width: column,
                                  child: sink != null
                                      ? _SinkView(
                                          view: sink,
                                          controller: _controller,
                                          sessions: widget.sessions,
                                          column: column,
                                        )
                                      : _SourceView(
                                          controller: _controller,
                                          selfDevice: widget.selfDevice,
                                          sessions: widget.sessions,
                                          narrow: column < _narrowColumn,
                                        ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      ShareToolbarLine(visible: _scrolled),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Words a failed member's row shows.
String _failureDetail(AppLocalizations l10n, AudioFailureReason? reason) =>
    switch (reason) {
      AudioFailureReason.unsupported => l10n.audioShareUnsupportedCapture,
      AudioFailureReason.busy => l10n.soundMemberBusy,
      _ => l10n.connectFailed,
    };

class _SourceView extends StatelessWidget {
  const _SourceView({
    required this.controller,
    required this.selfDevice,
    required this.sessions,
    required this.narrow,
  });

  final ShellSoundController controller;
  final DeviceData? selfDevice;
  final List<ChatSessionItem> sessions;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final l10n = context.shellL10n;
    final rows = [
      for (final session in sessions)
        if (session.isConnected || session.isNearby)
          controller.rowFor(session.device, connected: session.isConnected),
    ];
    final live = rows.where((row) => row.checked && row.live).toList();
    final quality = controller.headerQuality(live);
    final solo = live.any((row) => row.phase == SoundRowPhase.soloPlaying);
    final permission = controller.permissionNeeded;
    final failure = controller.failure;
    final subtitle = permission
        ? l10n.soundPermissionNeeded
        : failure != null
        ? l10n.audioShareFailed(_failureDetail(l10n, failure))
        : live.isEmpty
        ? l10n.soundHeroIdleBody
        : solo
        ? l10n.soundMemberSoloOnly
        : live.every((row) => row.sink == null)
        ? l10n.shellConnecting
        : switch (quality) {
            AudioSyncQuality.fair => l10n.audioGroupSyncFair,
            AudioSyncQuality.unstable => l10n.audioGroupSyncUnstable,
            AudioSyncQuality.good => l10n.audioGroupSyncGood,
            _ => l10n.audioGroupSyncCalibrating,
          };
    final self = selfDevice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hero(
          art: DeviceArt(
            kind: self == null
                ? DeviceKind.laptop
                : deviceKindFor(self.platform),
            wallpaper: DeviceWallpaper.self,
            size: 96,
          ),
          live: live.isNotEmpty,
          title: live.isEmpty
              ? l10n.soundHeroIdleTitle
              : l10n.soundHeroPlaying(live.length),
          subtitle: subtitle,
          action: permission
              ? ShareButton(
                  label: l10n.shareOpenSettings,
                  large: true,
                  onTap: () => unawaited(controller.openPermission()),
                )
              : null,
        ),
        const SizedBox(height: 18),
        ShareGroup(
          inset: 60,
          children: [
            if (rows.isEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 60),
                child: Center(
                  child: Text(
                    l10n.soundNoDevices,
                    style: TextStyle(
                      fontSize: const WhisperType(touch: false).body,
                      color: context.wc.ink2,
                    ),
                  ),
                ),
              ),
            for (final row in rows)
              _MemberRow(
                key: ValueKey(row.device.uid),
                row: row,
                narrow: narrow,
                controller: controller,
              ),
          ],
        ),
        if (controller.hasMembers) ...[
          const SizedBox(height: 18),
          ShareGroup(
            children: [
              _LabelRow(
                label: l10n.soundShareThisDevice,
                trailing: ShareSwitch(
                  label: l10n.soundShareThisDevice,
                  value: controller.on,
                  onChanged: permission
                      ? null
                      : (on) => unawaited(controller.setOn(on)),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// `.pane-hero`: picture, wave, title, one line. Every height here follows the
/// prototype's line heights so the page sits exactly where it does there.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.art,
    required this.live,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final Widget art;
  final bool live;
  final String title, subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 4),
      child: Column(
        children: [
          art,
          const SizedBox(height: 9),
          _Wave(live: live),
          const SizedBox(height: 11),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: type.title,
              fontWeight: FontWeight.w600,
              height: 1.4,
              leadingDistribution: TextLeadingDistribution.even,
              color: c.ink,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: type.body,
              height: 1.4,
              leadingDistribution: TextLeadingDistribution.even,
              color: c.ink2,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}

/// `.wave`: five bars, 3 wide, 3 apart, 18 high. They dance while sound plays
/// and lie down as grey dots when it does not.
class _Wave extends StatefulWidget {
  const _Wave({required this.live});

  final bool live;

  @override
  State<_Wave> createState() => _WaveState();
}

class _WaveState extends State<_Wave> with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: WhisperLoops.wave,
  );

  void _sync() {
    final run = widget.live && !MediaQuery.disableAnimationsOf(context);
    if (run && !_loop.isAnimating) {
      unawaited(_loop.repeat());
    } else if (!run && _loop.isAnimating) {
      _loop.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Wave old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      excludeSemantics: true,
      child: RepaintBoundary(
        child: SpringBuilder(
          value: widget.live ? 1 : 0,
          animateWhenReduced: true,
          builder: (context, amount, _) => AnimatedBuilder(
            animation: _loop,
            builder: (context, _) => CustomPaint(
              size: const Size(27, 18),
              painter: _WavePainter(
                phase: _loop.value,
                amount: amount.clamp(0.0, 1.0),
                reduced: reduced,
                on: c.accent,
                off: c.ink3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.phase,
    required this.amount,
    required this.reduced,
    required this.on,
    required this.off,
  });

  // Each bar's place in the loop: animation-delay over the 1.1 s period.
  static const _offsets = [0.0, .2 / 1.1, .55 / 1.1, .8 / 1.1, .35 / 1.1];
  static const _bar = 3.0, _gap = 3.0, _rest = .18, _low = .22;

  final double phase, amount;
  final bool reduced;
  final Color on, off;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Color.lerp(off, on, amount)!;
    for (var i = 0; i < _offsets.length; i++) {
      final beat = (phase + _offsets[i]) % 1;
      // Ease in and out between .22 and full height, and back.
      final swing = .5 - .5 * math.cos(2 * math.pi * beat);
      final live = reduced ? .7 : _low + (1 - _low) * swing;
      final scale = _rest + (live - _rest) * amount;
      final height = size.height * scale;
      final x = i * (_bar + _gap);
      final rect = Rect.fromLTWH(x, (size.height - height) / 2, _bar, height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(_bar / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.phase != phase ||
      old.amount != amount ||
      old.reduced != reduced ||
      old.on != on ||
      old.off != off;
}

/// `.row`: a label and a control, 40 high.
class _LabelRow extends StatelessWidget {
  const _LabelRow({required this.label, required this.trailing});

  final String label;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 40),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: const WhisperType(touch: false).body,
                color: context.wc.ink,
              ),
            ),
          ),
          const SizedBox(width: 10),
          trailing,
        ],
      ),
    ),
  );
}

/// `.row-a`: 60 high whatever its state, so that nothing moves as a device
/// joins, finds its sync or drops out.
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    super.key,
    required this.row,
    required this.narrow,
    required this.controller,
  });

  final SoundRow row;
  final bool narrow;
  final ShellSoundController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = context.shellL10n;
    final device = row.device;
    final phone = deviceKindOf(device).handheld;
    final channel = row.channel;
    return Opacity(
      opacity: row.connected ? 1 : .5,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          // 12 at the right too: the check's target is 3 wider than its circle.
          padding: const EdgeInsets.fromLTRB(12, 6, 9, 6),
          child: Row(
            children: [
              SizedBox(
                width: 38,
                child: Center(
                  child: deviceArtFor(device, size: phone ? 36 : 38),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: _MemberText(row: row)),
              _Reveal(
                visible: channel != null,
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: channel == null
                      ? const SizedBox.shrink()
                      : narrow
                      ? _ChannelPopup(
                          device: device,
                          channel: channel,
                          onChanged: (role) => unawaited(
                            controller.setChannel(device.uid, role),
                          ),
                        )
                      : _ChannelSegments(
                          device: device,
                          channel: channel,
                          onChanged: (role) => unawaited(
                            controller.setChannel(device.uid, role),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 7),
              ShareCheck(
                label: l10n.soundCheckLabel(device.name),
                value: row.checked,
                onChanged: row.connected
                    ? (_) => unawaited(controller.toggle(device.uid))
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Grows sideways from nothing, on the smooth spring, keeping its last content
/// while it goes. A row never changes height for it.
class _Reveal extends StatefulWidget {
  const _Reveal({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> {
  late Widget _shown = widget.child;

  @override
  void didUpdateWidget(_Reveal old) {
    super.didUpdateWidget(old);
    if (widget.visible) _shown = widget.child;
  }

  @override
  Widget build(BuildContext context) => SpringBuilder(
    value: widget.visible ? 1 : 0,
    spring: WhisperSprings.snappy,
    child: _shown,
    builder: (context, t, child) {
      final p = t.clamp(0.0, 1.0);
      if (p <= 0) return const SizedBox.shrink();
      if (p >= 1) return child!;
      return ClipRect(
        child: Align(
          alignment: Alignment.centerRight,
          widthFactor: p,
          child: Opacity(opacity: p, child: child),
        ),
      );
    },
  );
}

class _MemberText extends StatelessWidget {
  const _MemberText({required this.row});

  final SoundRow row;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: false);
    final (String? beside, bool warnBeside) = switch (row.phase) {
      SoundRowPhase.connecting => (l10n.shellConnecting, false),
      SoundRowPhase.calibrating => (l10n.audioGroupSyncCalibrating, false),
      SoundRowPhase.good => (l10n.audioGroupSyncGood, false),
      SoundRowPhase.fair => (l10n.audioGroupSyncFair, true),
      SoundRowPhase.unstable => (l10n.audioGroupSyncUnstable, true),
      _ => (null, false),
    };
    final sink = row.sink;
    final (String? below, bool warnBelow) = switch (row.phase) {
      SoundRowPhase.notConnected => (l10n.soundMemberNotConnected, false),
      SoundRowPhase.stopped => (l10n.soundMemberStopped, false),
      SoundRowPhase.soloOnly ||
      SoundRowPhase.soloPlaying => (l10n.soundMemberSoloOnly, false),
      SoundRowPhase.disconnected => (l10n.soundMemberStoppedThere, false),
      SoundRowPhase.failed => (
        l10n.soundMemberFailed(_failureDetail(l10n, row.failure)),
        true,
      ),
      SoundRowPhase.idle => (null, false),
      _ =>
        row.hasNumbers && sink != null
            ? (
                l10n.soundSyncNumbers(
                  formatAudioMillis(sink.rttMicros),
                  formatAudioMillis(sink.jitterMicros),
                  formatAudioMillis(sink.bufferTargetMicros),
                  sink.latePacketCount,
                ),
                false,
              )
            : (l10n.soundSyncNumbersPending, false),
    };
    TextStyle style(double size, Color color) => TextStyle(
      fontSize: size,
      height: 1.3,
      leadingDistribution: TextLeadingDistribution.even,
      color: color,
    );
    final detail = below == null
        ? null
        : Text(
            below,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style(
              type.note,
              warnBelow ? c.warn : c.ink2,
            ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                row.device.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style(type.body, c.ink),
              ),
            ),
            if (beside != null) ...[
              const SizedBox(width: 8),
              Text(
                beside,
                maxLines: 1,
                style: style(type.note, warnBeside ? c.warn : c.ink2),
              ),
            ],
          ],
        ),
        if (detail != null)
          row.phase == SoundRowPhase.failed
              ? Tooltip(message: below!, child: detail)
              : detail,
      ],
    );
  }
}

/// The two names a channel has: short in the row, whole in the menu.
String _shortChannel(AppLocalizations l10n, AudioChannelRole role) =>
    switch (role) {
      AudioChannelRole.left => l10n.soundChannelLeft,
      AudioChannelRole.right => l10n.soundChannelRight,
      AudioChannelRole.stereo => l10n.audioGroupRoleStereo,
      AudioChannelRole.mono => l10n.audioGroupRoleMono,
    };

String _fullChannel(AppLocalizations l10n, AudioChannelRole role) =>
    switch (role) {
      AudioChannelRole.left => l10n.audioGroupRoleLeft,
      AudioChannelRole.right => l10n.audioGroupRoleRight,
      AudioChannelRole.stereo => l10n.audioGroupRoleStereo,
      AudioChannelRole.mono => l10n.audioGroupRoleMono,
    };

const _channelOrder = [
  AudioChannelRole.left,
  AudioChannelRole.stereo,
  AudioChannelRole.right,
  AudioChannelRole.mono,
];

class _ChannelSegments extends StatelessWidget {
  const _ChannelSegments({
    required this.device,
    required this.channel,
    required this.onChanged,
  });

  final DeviceData device;
  final AudioChannelRole channel;
  final ValueChanged<AudioChannelRole> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.shellL10n;
    return Semantics(
      label: l10n.soundChannelLabel(device.name, _fullChannel(l10n, channel)),
      child: LiquidSegmented<AudioChannelRole>(
        height: 36,
        padding: 3,
        minSegmentWidth: 42,
        fontSize: const WhisperType(touch: false).note,
        segments: {
          for (final role in _channelOrder) role: _shortChannel(l10n, role),
        },
        selected: channel,
        onChanged: onChanged,
      ),
    );
  }
}

/// `.popb`: in a narrow window the channels fold into a button so that the name
/// keeps its room.
class _ChannelPopup extends StatefulWidget {
  const _ChannelPopup({
    required this.device,
    required this.channel,
    required this.onChanged,
  });

  final DeviceData device;
  final AudioChannelRole channel;
  final ValueChanged<AudioChannelRole> onChanged;

  @override
  State<_ChannelPopup> createState() => _ChannelPopupState();
}

class _ChannelPopupState extends State<_ChannelPopup> {
  Future<void> _open(BuildContext context) async {
    final l10n = context.shellL10n;
    final box = context.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final picked = await showShareMenu<AudioChannelRole>(
      context,
      anchor: anchor,
      items: [
        for (final role in _channelOrder)
          ShareMenuItem(
            value: role,
            label: _fullChannel(l10n, role),
            checked: role == widget.channel,
          ),
      ],
    );
    if (picked != null) widget.onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    return ShareHover(
      builder: (context, hover) => Pressable(
        radius: WhisperRadius.s,
        label: l10n.soundChannelLabel(
          widget.device.name,
          _fullChannel(l10n, widget.channel),
        ),
        onTap: () => unawaited(_open(context)),
        child: Container(
          height: 28,
          padding: const EdgeInsets.fromLTRB(11, 0, 8, 0),
          decoration: BoxDecoration(
            color: Color.lerp(c.fill, c.fill2, hover),
            borderRadius: BorderRadius.circular(WhisperRadius.s),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _fullChannel(l10n, widget.channel),
                maxLines: 1,
                style: TextStyle(
                  fontSize: const WhisperType(touch: false).note,
                  fontWeight: FontWeight.w500,
                  color: c.ink,
                ),
              ),
              const SizedBox(width: 6),
              ShareGlyphIcon(
                ShareGlyph.updown,
                size: 12,
                stroke: 2,
                color: c.ink2,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `placeAudioSink()`: another device's sound is playing here.
class _SinkView extends StatelessWidget {
  const _SinkView({
    required this.view,
    required this.controller,
    required this.sessions,
    required this.column,
  });

  final SoundSinkView view;
  final ShellSoundController controller;
  final List<ChatSessionItem> sessions;
  final double column;

  DeviceData? get _source {
    for (final session in sessions) {
      if (session.device.uid == view.sourcePeerId) return session.device;
    }
    return controller.deviceFor(view.sourcePeerId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.shellL10n;
    final source = _source;
    final resuming = view.phase == SoundSinkPhase.resuming;
    final playing = view.phase == SoundSinkPhase.playing;
    return Column(
      children: [
        _Hero(
          art: source == null
              ? const DeviceArt(
                  kind: DeviceKind.desktop,
                  wallpaper: DeviceWallpaper.unpaired,
                  size: 96,
                )
              : deviceArtFor(source, size: 96),
          live: playing,
          title: l10n.soundSinkTitle(source?.name ?? ''),
          subtitle: switch (view.phase) {
            SoundSinkPhase.playing => l10n.soundSinkHint,
            SoundSinkPhase.paused => l10n.soundSinkPaused,
            SoundSinkPhase.resuming => l10n.soundSinkResuming,
          },
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: math.min(320, column),
          child: ShareGroup(children: [_GainRow(controller: controller)]),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (view.canPause) ...[
              ShareButton(
                label: l10n.mediaActionPause,
                kind: ShareButtonKind.tinted,
                large: true,
                onTap: () => unawaited(controller.pause()),
              ),
              const SizedBox(width: 8),
            ],
            if (view.canResume) ...[
              ShareButton(
                label: l10n.soundResume,
                kind: ShareButtonKind.tinted,
                large: true,
                onTap: resuming ? null : () => unawaited(controller.resume()),
              ),
              const SizedBox(width: 8),
            ],
            ShareButton(
              label: l10n.mediaActionDisconnect,
              large: true,
              onTap: resuming ? null : () => unawaited(controller.disconnect()),
            ),
          ],
        ),
      ],
    );
  }
}

class _GainRow extends StatelessWidget {
  const _GainRow({required this.controller});

  final ShellSoundController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: false);
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Text(
              l10n.soundGain,
              style: TextStyle(fontSize: type.body, color: c.ink),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SliderTheme(
                data: whisperSliderTheme(context).copyWith(
                  trackShape: const _RangeInputTrack(),
                  // A rounded track starts its thumb half a track height in.
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Slider(
                  min: 1,
                  max: 3,
                  divisions: 20,
                  value: controller.gain.clamp(1.0, 3.0),
                  semanticFormatterCallback: (value) =>
                      l10n.soundGainValue(value.toStringAsFixed(1)),
                  onChanged: controller.setGain,
                  onChangeEnd: (value) =>
                      unawaited(controller.commitGain(value)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 38),
              child: Text(
                l10n.soundGainValue(controller.gain.toStringAsFixed(1)),
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: type.note,
                  color: c.ink2,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `input[type=range]`: the track runs the whole width, past the ends of the
/// thumb's travel, which the stock shape stops short of.
class _RangeInputTrack extends RoundedRectSliderTrackShape {
  const _RangeInputTrack();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final thumb = sliderTheme.thumbShape!
        .getPreferredSize(isEnabled, isDiscrete)
        .width;
    final radius = Radius.circular(rect.height / 2);
    final canvas = context.canvas;
    // The thumb's travel is inset by half the track's height; its far edges
    // are where the track ends.
    final reach = thumb / 2 - rect.height / 2;
    final whole = RRect.fromLTRBR(
      rect.left - reach,
      rect.top,
      rect.right + reach,
      rect.bottom,
      radius,
    );
    canvas.drawRRect(whole, Paint()..color = sliderTheme.inactiveTrackColor!);
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(whole.left, whole.top, thumbCenter.dx, whole.bottom),
    );
    canvas.drawRRect(whole, Paint()..color = sliderTheme.activeTrackColor!);
    canvas.restore();
  }
}
