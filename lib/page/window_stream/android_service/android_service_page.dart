import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../helper/toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import 'android_service_controller.dart';

/// The phone's "window flow service" page: status, a guided one-time setup
/// that pairs with the phone's own Wireless debugging, and start/stop. Lets
/// this phone's apps flow to trusted computers even when none of them has
/// adb. Styled like the rest of Whisper's iOS-flavoured settings.
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
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _statusCard(palette, colors),
                const SizedBox(height: 20),
                ..._actions(palette, colors),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- status card

  Widget _statusCard(WhisperPalette palette, ColorScheme colors) {
    final running = _controller.state == AndroidWindowServiceState.running;
    final working = _controller.state == AndroidWindowServiceState.working;
    final (title, hint) = switch (_controller.state) {
      AndroidWindowServiceState.running => (
        _s.androidWindowServiceRunning,
        _s.androidWindowServiceRunningHint,
      ),
      AndroidWindowServiceState.stopped => (
        _s.androidWindowServiceStopped,
        _s.androidWindowServiceStoppedHint,
      ),
      AndroidWindowServiceState.needsSetup => (
        _s.androidWindowServiceNeedsSetup,
        _s.androidWindowServiceNeedsSetupHint,
      ),
      AndroidWindowServiceState.working => (
        _s.androidWindowServiceStarting,
        _s.androidWindowServiceNeedsSetupHint,
      ),
    };
    final dot = running
        ? palette.trusted
        : working
        ? palette.connected
        : palette.textMuted;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: dot.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(14),
            ),
            child: working
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: CupertinoActivityIndicator(),
                  )
                : Icon(
                    running
                        ? CupertinoIcons.rectangle_on_rectangle_angled
                        : CupertinoIcons.rectangle_dock,
                    color: dot,
                    size: 24,
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hint,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 13.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- actions

  List<Widget> _actions(WhisperPalette palette, ColorScheme colors) {
    switch (_controller.state) {
      case AndroidWindowServiceState.running:
        return [
          _primaryButton(
            _s.androidWindowServiceStop,
            onPressed: _controller.busy ? null : _stop,
            tone: palette.danger,
          ),
          if (_controller.canSelfStart) ...[
            const SizedBox(height: 16),
            _autoStartRow(palette, colors),
          ],
        ];
      case AndroidWindowServiceState.stopped:
        if (!_controller.canSelfStart) {
          return [
            _hintCard(palette, colors, _s.androidWindowServiceComputerHint),
          ];
        }
        return [
          _primaryButton(
            _s.androidWindowServiceStart,
            onPressed: _controller.busy ? null : _start,
            tone: palette.connected,
          ),
          const SizedBox(height: 16),
          _setupSection(palette, colors),
          const SizedBox(height: 16),
          _autoStartRow(palette, colors),
        ];
      case AndroidWindowServiceState.needsSetup:
      case AndroidWindowServiceState.working:
        if (!_controller.canSelfStart) {
          return [
            _hintCard(palette, colors, _s.androidWindowServiceComputerHint),
          ];
        }
        return [_setupSection(palette, colors)];
    }
  }

  Widget _setupSection(WhisperPalette palette, ColorScheme colors) {
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        children: [
          _stepTile(
            palette,
            colors,
            number: 1,
            title: _s.androidWindowServiceStep1,
            hint: _s.androidWindowServiceStep1Hint,
            actionLabel: _s.androidWindowServiceStep1Action,
            onAction: _controller.openDeviceInfo,
          ),
          _divider(palette),
          _stepTile(
            palette,
            colors,
            number: 2,
            title: _s.androidWindowServiceStep2,
            hint: _s.androidWindowServiceStep2Hint,
            actionLabel: _s.androidWindowServiceStep2Action,
            onAction: _controller.openDeveloperOptions,
          ),
          _divider(palette),
          _stepTile(
            palette,
            colors,
            number: 3,
            title: _s.androidWindowServiceStep3,
            hint: _s.androidWindowServiceStep3Hint,
            child: _pairingField(palette, colors),
          ),
        ],
      ),
    );
  }

  Widget _pairingField(WhisperPalette palette, ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: CupertinoTextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              enabled: _controller.canSelfStart && !_controller.busy,
              placeholder: _s.androidWindowServicePairingCode,
              style: TextStyle(color: colors.onSurface, letterSpacing: 4),
              decoration: BoxDecoration(
                color: palette.surfaceMuted,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed:
                _controller.canSelfStart &&
                    !_controller.busy &&
                    _code.text.trim().length >= 6
                ? _pair
                : null,
            style: FilledButton.styleFrom(
              backgroundColor: palette.connected,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            ),
            child: Text(
              _controller.busy
                  ? _s.androidWindowServicePairing
                  : _s.androidWindowServicePair,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepTile(
    WhisperPalette palette,
    ColorScheme colors, {
    required int number,
    required String title,
    required String hint,
    String? actionLabel,
    VoidCallback? onAction,
    Widget? child,
  }) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.connected.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: TextStyle(
                color: palette.connected,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  hint,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                if (actionLabel != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: CupertinoButton(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 30),
                      onPressed: onAction,
                      child: Text(
                        actionLabel,
                        style: TextStyle(
                          color: palette.connected,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                if (child != null) child,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _autoStartRow(WhisperPalette palette, ColorScheme colors) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _s.androidWindowServiceAutoStart,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _s.androidWindowServiceAutoStartHint,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          CupertinoSwitch(
            value: _controller.autoStart,
            activeTrackColor: palette.trusted,
            onChanged: _controller.busy
                ? null
                : (value) => _controller.setAutoStart(value),
          ),
        ],
      ),
    );
  }

  Widget _hintCard(WhisperPalette palette, ColorScheme colors, String text) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            CupertinoIcons.desktopcomputer,
            color: palette.connected,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: colors.onSurface,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _primaryButton(
    String label, {
    required VoidCallback? onPressed,
    required Color tone,
  }) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: tone,
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _divider(WhisperPalette palette) =>
      Divider(height: 1, thickness: 1, indent: 52, color: palette.borderSubtle);

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
