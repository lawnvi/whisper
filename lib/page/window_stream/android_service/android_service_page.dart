import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../helper/toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../../settings.dart' show SettingsSectionSurface;
import 'android_service_controller.dart';

/// The phone's "window flow service" page: status, a guided one-time setup
/// that pairs with the phone's own Wireless debugging, and start/stop. Lets
/// this phone's apps flow to trusted computers even when none of them has
/// adb. Built from the settings page's own grouped rows.
class AndroidWindowServicePage extends StatefulWidget {
  const AndroidWindowServicePage({super.key, this.controller});

  /// Injected in tests; the real page makes its own.
  final AndroidWindowServiceController? controller;

  @override
  State<AndroidWindowServicePage> createState() =>
      _AndroidWindowServicePageState();
}

class _AndroidWindowServicePageState extends State<AndroidWindowServicePage> {
  late final AndroidWindowServiceController _controller =
      widget.controller ?? AndroidWindowServiceController();
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChange);
    _controller.init();
  }

  void _onChange() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChange);
    if (widget.controller == null) {
      _controller.dispose();
    }
    _code.dispose();
    super.dispose();
  }

  AppLocalizations get _s => AppLocalizations.of(context)!;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: palette.surfaceCanvas,
      appBar: AppBar(
        backgroundColor: palette.surfaceCanvas,
        leading: MediaQuery.withNoTextScaling(
          child: CupertinoNavigationBarBackButton(
            previousPageTitle: '',
            onPressed: () => Navigator.of(context).maybePop(),
            color: colors.onSurface,
          ),
        ),
        title: Text(
          _s.androidWindowServiceTitle,
          style: TextStyle(color: colors.onSurface),
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: WhisperUi.settingsMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 16),
              children: _sections(palette, colors),
            ),
          ),
        ),
      ),
    );
  }

  // The same pieces as the settings page: grouped rows with a muted icon,
  // the state as a dot at the end, actions as rows rather than buttons.
  List<Widget> _sections(WhisperPalette palette, ColorScheme colors) {
    final state = _controller.state;
    final busy = _controller.busy;
    final self = _controller.canSelfStart;
    final running = state == AndroidWindowServiceState.running;
    return [
      _section(null, [
        _statusRow(palette, colors),
        if (self && running)
          _actionRow(
            _s.androidWindowServiceStop,
            CupertinoIcons.stop_circle,
            palette.danger,
            busy ? null : _stop,
          ),
        if (self && state == AndroidWindowServiceState.stopped)
          _actionRow(
            _s.androidWindowServiceStart,
            CupertinoIcons.play_circle,
            palette.connected,
            busy ? null : _start,
          ),
        if (self && state != AndroidWindowServiceState.needsSetup)
          _row(
            palette,
            colors,
            icon: CupertinoIcons.arrow_clockwise,
            title: _s.androidWindowServiceAutoStart,
            desc: _s.androidWindowServiceAutoStartHint,
            lines: 4,
            onTap: busy
                ? null
                : () => _controller.setAutoStart(!_controller.autoStart),
            trailing: CupertinoSwitch(
              value: _controller.autoStart,
              onChanged: busy ? null : _controller.setAutoStart,
            ),
          ),
      ], footer: self ? null : _s.androidWindowServiceComputerHint),
      if (self && !running) _setupSection(palette, colors),
    ];
  }

  Widget _section(String? title, List<Widget> rows, {String? footer}) {
    final palette = context.whisperPalette;
    final caption = Theme.of(context).textTheme.labelMedium?.copyWith(
      fontSize: 13,
      height: 1.4,
      letterSpacing: 0,
      color: palette.textMuted,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                title,
                style: caption?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          SettingsSectionSurface(children: rows),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(footer, style: caption),
            ),
        ],
      ),
    );
  }

  Widget _statusRow(WhisperPalette palette, ColorScheme colors) {
    final (title, hint, tone) = switch (_controller.state) {
      AndroidWindowServiceState.running => (
        _s.androidWindowServiceRunning,
        _s.androidWindowServiceRunningHint,
        palette.trusted,
      ),
      AndroidWindowServiceState.stopped => (
        _s.androidWindowServiceStopped,
        _s.androidWindowServiceStoppedHint,
        palette.textMuted,
      ),
      AndroidWindowServiceState.needsSetup => (
        _s.androidWindowServiceNeedsSetup,
        _s.androidWindowServiceNeedsSetupHint,
        palette.warning,
      ),
      AndroidWindowServiceState.working => (
        _s.androidWindowServiceStarting,
        _s.androidWindowServiceNeedsSetupHint,
        palette.connected,
      ),
    };
    return _row(
      palette,
      colors,
      icon: CupertinoIcons.rectangle_on_rectangle_angled,
      title: title,
      desc: hint,
      lines: 3,
      trailing: _controller.state == AndroidWindowServiceState.working
          ? const CupertinoActivityIndicator(radius: 8)
          : Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
            ),
    );
  }

  Widget _actionRow(
    String label,
    IconData icon,
    Color tone,
    VoidCallback? onTap,
  ) {
    final enabled = onTap != null;
    final color = enabled ? tone : tone.withValues(alpha: 0.4);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 16,
                  height: 1.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _setupSection(WhisperPalette palette, ColorScheme colors) {
    final chevron = Icon(Icons.chevron_right_rounded, color: palette.textMuted);
    return _section(_s.androidWindowServiceHowTitle, [
      _row(
        palette,
        colors,
        leading: _stepNumber(palette, 1),
        title: _s.androidWindowServiceStep1,
        desc: _s.androidWindowServiceStep1Hint,
        semanticsHint: _s.androidWindowServiceStep1Action,
        onTap: _controller.openDeviceInfo,
        trailing: chevron,
      ),
      _row(
        palette,
        colors,
        leading: _stepNumber(palette, 2),
        title: _s.androidWindowServiceStep2,
        desc: _s.androidWindowServiceStep2Hint,
        semanticsHint: _s.androidWindowServiceStep2Action,
        onTap: _controller.openDeveloperOptions,
        trailing: chevron,
        lines: 3,
      ),
      _row(
        palette,
        colors,
        leading: _stepNumber(palette, 3),
        title: _s.androidWindowServiceStep3,
        desc: _s.androidWindowServiceStep3Hint,
        lines: 3,
        below: _pairingField(palette, colors),
      ),
    ]);
  }

  Widget _stepNumber(WhisperPalette palette, int number) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: palette.textMuted, width: 1.5),
      ),
      child: Text(
        '$number',
        style: TextStyle(
          color: palette.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _pairingField(WhisperPalette palette, ColorScheme colors) {
    final enabled = _controller.canSelfStart && !_controller.busy;
    final ready = enabled && _code.text.trim().length >= 6;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            child: CupertinoTextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              enabled: enabled,
              onChanged: (_) => setState(() {}),
              placeholder: _s.androidWindowServicePairingCode,
              style: TextStyle(color: colors.onSurface, letterSpacing: 4),
              decoration: BoxDecoration(
                color: palette.surfaceMuted,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
          const SizedBox(width: 6),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 40),
            onPressed: ready ? _pair : null,
            child: Text(
              _controller.busy
                  ? _s.androidWindowServicePairing
                  : _s.androidWindowServicePair,
              style: TextStyle(
                color: ready ? palette.connected : palette.textMuted,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One settings row: icon, title and description, an accessory at the
  /// end (a switch beside the title, anything else centred on the row).
  Widget _row(
    WhisperPalette palette,
    ColorScheme colors, {
    IconData? icon,
    Widget? leading,
    required String title,
    required String desc,
    String? semanticsHint,
    VoidCallback? onTap,
    Widget? trailing,
    Widget? below,
    int lines = 2,
  }) {
    final toggle = trailing is CupertinoSwitch;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      button: onTap != null,
      hint: semanticsHint,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            crossAxisAlignment: toggle || below != null
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: Center(
                          child:
                              leading ?? Icon(icon, color: palette.textMuted),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: textTheme.titleMedium?.copyWith(
                              fontSize: 16,
                              height: 1.5,
                              letterSpacing: 0,
                              color: colors.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            desc,
                            maxLines: lines,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall?.copyWith(
                              fontSize: 13,
                              height: 1.5,
                              letterSpacing: 0,
                              color: palette.textMuted,
                            ),
                          ),
                          ?below,
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 6),
                Padding(
                  padding: EdgeInsets.only(top: toggle ? 2 : 0),
                  child: trailing,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pair() async {
    final ok = await _controller.pairAndStart(_code.text);
    if (!mounted) {
      return;
    }
    if (ok) {
      _code.clear();
      showAppToast(_s.androidWindowServiceStarted, tone: AppToastTone.success);
    } else {
      showAppToast(_s.androidWindowServicePairFailed, tone: AppToastTone.error);
    }
  }

  Future<void> _start() async {
    final ok = await _controller.start();
    if (!mounted) {
      return;
    }
    showAppToast(
      ok ? _s.androidWindowServiceStarted : _s.androidWindowServiceStartFailed,
      tone: ok ? AppToastTone.success : AppToastTone.error,
    );
  }

  Future<void> _stop() async {
    await _controller.stop();
    if (mounted) {
      showAppToast(_s.androidWindowServiceStopped2, tone: AppToastTone.info);
    }
  }
}
