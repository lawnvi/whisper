import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/remote_input/mobile_control_keyboard.dart';
import 'package:whisper/remote_input/mobile_input_controller.dart';
import 'package:whisper/remote_input/mobile_motion.dart';
import 'package:whisper/remote_input/mobile_pointer_settings.dart';
import 'package:whisper/remote_input/mobile_touchpad.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_lifecycle.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/glass_bottom_sheet.dart';
import 'package:whisper/widget/subtle_motion.dart';
import 'package:whisper/widget/segmented_tabs.dart';

class MobileControlTarget {
  const MobileControlTarget(this.id, this.name, {this.platform = 'macos'});
  final String id, name, platform;
}

class MobileControlScreen extends StatefulWidget {
  const MobileControlScreen({
    super.key,
    required this.peerId,
    required this.peerName,
    required this.onStart,
    required this.onStop,
    this.targets,
    this.coordinator,
    this.sensor,
  });
  final String peerId;
  final String peerName;
  final Future<void> Function(String peerId) onStart;
  final List<MobileControlTarget> Function()? targets;
  final Future<void> Function() onStop;
  final RemoteInputCoordinator? coordinator;
  final MobileMotionSensor? sensor;
  @override
  State<MobileControlScreen> createState() => _MobileControlScreenState();
}

class _MobileControlScreenState extends State<MobileControlScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late MobileControlTarget _target = MobileControlTarget(
    widget.peerId,
    widget.peerName,
  );
  late final _transition = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 120),
  );
  static const _controlSheetAnimation = AnimationStyle(
    duration: Duration(milliseconds: 300),
    reverseDuration: Duration(milliseconds: 220),
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInOutCubic,
  );
  bool _transitioning = false;
  int _transitionGeneration = 0;
  late final RemoteInputCoordinator _coordinator =
      widget.coordinator ?? RemoteInputCoordinator.shared;
  late final MobileMotionSensor _sensor = widget.sensor ?? MobileMotionSensor();
  late final MobileInputController _input = MobileInputController(
    _coordinator.sendManualInput,
  );
  late final _pad = MobileTouchpad(
    move: _input.move,
    click: _input.click,
    flush: _input.flush,
    cancel: _input.reset,
  );
  final _text = TextEditingController();
  final _textFocus = FocusNode();
  bool _editingText = false;
  StreamSubscription<MotionSample>? _samples;
  Timer? _calibrationTimer;
  bool _available = false, _starting = false, _stopping = false;
  bool _awake = false;
  int _tab = 0, _keyPage = 0, _startGeneration = 0;
  String? _error;
  String _failureText(String reason) => switch (reason) {
    'permission' =>
      _target.platform.toLowerCase().contains('mac')
          ? l10n.mobileControlPermission
          : l10n.mobileControlPermissionDesktop,
    'busy' => l10n.remoteInputStopCurrentFirst,
    'trustRequired' => l10n.remoteInputRequiresMutualTrust,
    'unsupported' => l10n.remoteInputPeerUnsupported,
    'transport' => l10n.mobileControlTransportHelp,
    'injection' || 'capture' => l10n.mobileControlInjectionHelp,
    'protocol' => l10n.connectionDiagnosticVersion,
    _ => l10n.connectFailed,
  };
  bool? _landscape;

  int _gestureGeneration = 0;

  AppLocalizations get l10n => AppLocalizations.of(context)!;
  bool get _ownsSession =>
      _coordinator.isManual &&
      _coordinator.state.isForPeer(_target.id) &&
      _coordinator.state.role == RemoteInputRuntimeRole.source;
  bool get _active => _ownsSession && _coordinator.state.isActive;
  bool get _enabled =>
      _active && !_coordinator.isSendingText && !_stopping && !_transitioning;

  @override
  void initState() {
    super.initState();
    for (final target in widget.targets?.call() ?? <MobileControlTarget>[]) {
      if (target.id == widget.peerId) _target = target;
    }
    _textFocus.addListener(_textFocusChanged);
    WidgetsBinding.instance.addObserver(this);
    _coordinator.addListener(_refresh);
    _input.addListener(_redraw);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    bool available = false;
    try {
      available = await _sensor.available();
    } catch (_) {
      /* touchpad fallback */
    }
    final sensitivity = await LocalSetting().mobileInputSensitivity();
    final pointerSpeed = await LocalSetting().mobilePointerSpeed();
    final scrollSpeed = await LocalSetting().mobileScrollSpeed();
    if (!mounted) return;
    _input.pointerSpeed = pointerSpeed;
    _input.scrollSpeed = scrollSpeed;
    _available = available;
    _input.motion.sensitivity = sensitivity;
    _input.setAir(available);
    _refresh();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  void _refresh() {
    if (!mounted) return;
    _input.active = _enabled;
    if (!_enabled) _pad.reset();
    _syncSensors();
    if (_awake != _active) {
      _awake = _active;
      unawaited(WakelockPlus.toggle(enable: _awake).catchError((Object _) {}));
    }
    setState(() {});
  }

  void _syncSensors() {
    if (_enabled &&
        _available &&
        ((_input.air && _tab == 0) || _input.motion.calibrating)) {
      _samples ??= _sensor.samples().listen(
        (sample) {
          final calibrating = _input.motion.calibrating;
          _input.sample(sample);
          if (calibrating && !_input.motion.calibrating && mounted) {
            _calibrationTimer?.cancel();
            _syncSensors();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.mobileControlCalibrationDone)),
            );
          }
        },
        onError: (Object error) {
          if (!mounted) return;
          _available = false;
          _input.setAir(false);
          final subscription = _samples;
          _samples = null;
          unawaited(subscription?.cancel());
          _redraw();
        },
      );
    } else {
      final subscription = _samples;
      _samples = null;
      unawaited(subscription?.cancel());
    }
  }

  Future<void> _start() async {
    final generation = ++_startGeneration;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      await widget.onStart(_target.id);
      if (!mounted || generation != _startGeneration) {
        if (_ownsSession) await widget.onStop();
        return;
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is MobileControlStartException
              ? error.localizedMessage
              : error is RemoteInputBusyException
              ? l10n.remoteInputStopCurrentFirst
              : l10n.connectFailed;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _starting = false;
        });
      }
    }
  }

  Future<void> _stop() async {
    ++_startGeneration;
    _reset();
    if (_stopping) return;
    setState(() {
      _stopping = true;
    });
    try {
      if (_ownsSession || _starting) await widget.onStop();
    } catch (_) {
      // Native and transport cleanup are both attempted by the lifecycle owner.
      if (mounted) _error = l10n.connectFailed;
    } finally {
      if (mounted) {
        setState(() {
          _stopping = false;
        });
      }
    }
  }

  void _reset() {
    _gestureGeneration++;
    _pad.reset();
    _calibrationTimer?.cancel();
    _input.reset();
  }

  Future<void> _selectTab(int tab, {bool animate = true}) async {
    if (tab == _tab && !_transitioning) return;
    final generation = ++_transitionGeneration;
    final useAnimation = animate && !MediaQuery.disableAnimationsOf(context);
    _reset();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _transitioning = true);
    _syncSensors();
    if (useAnimation) {
      try {
        await _transition.reverse().orCancel;
        await WidgetsBinding.instance.endOfFrame;
        await Future<void>.delayed(const Duration(milliseconds: 32));
      } on TickerCanceled {
        return;
      }
    } else {
      _transition.value = 0;
    }
    if (!mounted || generation != _transitionGeneration) return;
    setState(() {
      _tab = tab;
      _editingText = false;
    });
    setState(() => _transitioning = false);
    _refresh();
    if (useAnimation) {
      unawaited(_transition.forward());
    } else {
      _transition.value = 1;
    }
  }

  void _textFocusChanged() {
    if (!_textFocus.hasFocus || !mounted) return;
    _reset();
    setState(() => _editingText = true);
  }

  void _returnToKeys() {
    _textFocus.unfocus();
    _reset();
    setState(() => _editingText = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_stop());
  }

  @override
  void didChangeMetrics() {
    final size = View.of(context).physicalSize;
    final landscape = size.width > size.height;
    if (_landscape != null && _landscape != landscape) _reset();
    _landscape = landscape;
  }

  @override
  void dispose() {
    ++_startGeneration;
    ++_transitionGeneration;
    _transition.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _coordinator.removeListener(_refresh);
    _input.removeListener(_redraw);
    _input.dispose();
    _calibrationTimer?.cancel();
    unawaited(_samples?.cancel());
    if (_ownsSession || _starting) {
      unawaited(widget.onStop().catchError((Object _) {}));
    }
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    _textFocus.removeListener(_textFocusChanged);
    _textFocus.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _sendText() async {
    if (!_enabled) return;
    if (utf8.encode(_text.text).length > 4096) {
      setState(() {
        _error = l10n.mobileControlTextTooLong;
      });
      return;
    }
    if (_text.text.isEmpty ||
        (_text.value.composing.isValid && !_text.value.composing.isCollapsed)) {
      return;
    }
    _reset();
    FocusManager.instance.primaryFocus?.unfocus();
    final sent = await _coordinator.sendManualText(_text.text);
    if (!mounted) return;
    if (sent) {
      _text.clear();
      _editingText = false;
    }
    setState(() {
      _error = sent ? null : l10n.mobileControlTextUnconfirmed;
    });
    if (sent) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.mobileControlTextSent)));
    }
  }

  @override
  Widget build(BuildContext context) {
    _landscape ??=
        View.of(context).physicalSize.width >
        View.of(context).physicalSize.height;
    final state = _coordinator.state;
    final busy = _starting || _stopping || (_ownsSession && state.isBusy);
    final palette = context.whisperPalette;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        systemNavigationBarColor: palette.surfaceCanvas,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness:
            Theme.of(context).brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: palette.surfaceCanvas,
        appBar: AppBar(
          backgroundColor: palette.surfaceCanvas,
          titleSpacing: 0,
          title: _deviceTitle(),
          actions: [
            _toolbarIcon(
              key: const ValueKey('mobile-control-toggle'),
              tooltip: _tab == 0
                  ? l10n.mobileControlKeysTab
                  : l10n.mobileControlPointer,
              icon: _tab == 0 ? Icons.keyboard_outlined : Icons.mouse_outlined,
              color: Theme.of(context).colorScheme.primary,
              onPressed: _coordinator.isSendingText || _transitioning
                  ? null
                  : () => _selectTab(_tab == 0 ? 1 : 0),
            ),
            const SizedBox(width: 8),
            _sessionAction(busy),
            const SizedBox(width: 8),
            IconButton(
              tooltip: l10n.mobileControlSettings,
              onPressed: _coordinator.isSendingText
                  ? null
                  : _showPointerSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: SafeArea(
          minimum: EdgeInsets.only(
            bottom: _tab == 1 && !_editingText
                ? math.max(
                    8,
                    math.max(
                      MediaQuery.viewPaddingOf(context).bottom,
                      MediaQuery.systemGestureInsetsOf(context).bottom,
                    ),
                  )
                : 0,
          ),
          child: Column(
            children: [
              if (_error != null ||
                  state.status == RemoteInputRuntimeStatus.failed)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 96),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _error ?? _failureText(state.errorMessage),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: IgnorePointer(
                  ignoring: _transitioning,
                  child: FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _transition,
                      curve: Curves.easeOutCubic,
                    ),
                    child: _tab == 0 ? _pointerPanel() : _keyboardPanel(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _deviceTitle() => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap:
        widget.targets == null ||
            _starting ||
            _stopping ||
            _coordinator.isSendingText
        ? null
        : _chooseTarget,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Flexible(child: _deviceLabel()),
          if (widget.targets != null)
            const Icon(Icons.expand_more_rounded, size: 18),
        ],
      ),
    ),
  );

  Future<void> _chooseTarget() async {
    _textFocus.unfocus();
    _reset();
    final targets = widget.targets!();
    final selected = await showWhisperModalBottomSheet<MobileControlTarget>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      sheetAnimationStyle: _controlSheetAnimation,
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          key: const ValueKey('mobile-control-target-sheet'),
          padding: const EdgeInsets.only(bottom: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.mobileControlTarget,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.mobileControlTargetHint,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: context.whisperPalette.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final target in targets)
                      ListTile(
                        key: ValueKey('mobile-control-target-${target.id}'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 4,
                        ),
                        leading: const Icon(Icons.desktop_windows_outlined),
                        title: Text(target.name),
                        trailing: target.id == _target.id
                            ? const Icon(Icons.check_rounded)
                            : null,
                        onTap: () => Navigator.pop(context, target),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null || selected.id == _target.id) return;
    await _stop();
    if (!mounted) return;
    setState(() {
      _target = selected;
      _error = null;
    });
    _text.clear();
  }

  Widget _deviceLabel() => Semantics(
    label: l10n.mobileControlTitle,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _target.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        WhisperAnimatedSwitcher(
          value: _active,
          alignment: Alignment.centerLeft,
          child: Text(
            _active ? l10n.mobileControlActive : l10n.mobileControlReady,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: _active
                  ? context.whisperPalette.trusted
                  : context.whisperPalette.textMuted,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _toolbarIcon({
    required Key key,
    required String tooltip,
    required IconData icon,
    required Color color,
    required VoidCallback? onPressed,
    bool pending = false,
  }) => SizedBox.square(
    dimension: 48,
    child: IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        foregroundColor: color,
        backgroundColor: color.withValues(alpha: .1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: WhisperAnimatedSwitcher(
        value: (pending, icon),
        scale: true,
        child: pending
            ? SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            : Icon(icon, size: 24),
      ),
    ),
  );

  Widget _sessionAction(bool busy) {
    final stop = _ownsSession || _starting;
    return _toolbarIcon(
      key: const ValueKey('mobile-control-session'),
      tooltip: stop ? l10n.mobileControlStop : l10n.mobileControlStart,
      icon: stop ? Icons.stop_rounded : Icons.play_arrow_rounded,
      color: stop
          ? context.whisperPalette.danger
          : context.whisperPalette.trusted,
      onPressed: stop ? (_stopping ? null : _stop) : (busy ? null : _start),
      pending: _starting || _stopping,
    );
  }

  Widget _pointerPanel() => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final height = math.max(
        constraints.maxHeight,
        scale < 1.4 ? 360.0 : 400.0 * scale,
      );
      final panel = SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Column(
            children: [
              _ModeSelector(
                labels: [l10n.mobileControlAir, l10n.mobileControlTouchpad],
                selected: _input.air ? 0 : 1,
                onSelected: (index) {
                  if ((index == 0 && !_available) ||
                      (index == 0) == _input.air) {
                    return;
                  }
                  _reset();
                  _input.setAir(index == 0);
                  _syncSensors();
                },
                disabledIndex: _available ? null : 0,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: Material(
                    key: const ValueKey('mobile-pointer-surface'),
                    color: context.whisperPalette.surfaceElevated,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                      side: BorderSide(
                        color: context.whisperPalette.borderSubtle,
                      ),
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: WhisperTabPanels(
                            key: const ValueKey('mobile-pointer-mode-content'),
                            selected: _input.air ? 0 : 1,
                            children: [_airSurface(), _touchpad()],
                          ),
                        ),
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: context.whisperPalette.borderSubtle,
                        ),
                        _pointerActions(),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      return height > constraints.maxHeight
          ? SingleChildScrollView(child: panel)
          : panel;
    },
  );

  Widget _airSurface() {
    final generation = _gestureGeneration;
    bool acceptsInput() =>
        _enabled && _input.air && generation == _gestureGeneration;
    return Semantics(
      key: const ValueKey('mobile-air-surface'),
      button: true,
      toggled: _input.moving,
      enabled: _enabled,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: ValueKey(generation),
          onTap: _enabled
              ? () {
                  if (acceptsInput()) _input.toggleMotion();
                }
              : null,
          onTapCancel: _enabled
              ? () {
                  if (acceptsInput()) _input.reset();
                }
              : null,
          child: CustomPaint(
            painter: _PointerTexture(context.whisperPalette.borderSubtle),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: _SurfaceLabel(
                  label: _input.moving
                      ? l10n.mobileControlMotionPause
                      : l10n.mobileControlMotionStart,
                  subtitle: _input.scrolling
                      ? l10n.mobileControlHoldScroll
                      : _input.moving
                      ? l10n.mobileControlMotionOnHint
                      : l10n.mobileControlMotionOffHint,
                  icon: Icons.smartphone_rounded,
                  enabled: _enabled,
                  active: _input.moving || _input.scrolling,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pointerActions() {
    final buttonHeight = math.max(
      88.0,
      MediaQuery.textScalerOf(context).scale(14) * 4 + 24,
    );
    Widget button(int number, String label, String shortLabel) => Expanded(
      child: _HoldArea(
        key: ValueKey(number == 0 ? 'mobile-mouse-left' : 'mobile-mouse-right'),
        generation: _gestureGeneration,
        label: label,
        displayLabel: shortLabel,
        enabled: _enabled,
        onDown: () => _input.button(number, true),
        onUp: () => _input.button(number, false),
      ),
    );
    return SizedBox(
      height: buttonHeight,
      child: Row(
        children: [
          button(0, l10n.mobileControlLeft, l10n.mobileControlLeftShort),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: context.whisperPalette.borderSubtle,
          ),
          SizedBox(
            width: 64,
            child: _HoldArea(
              key: const ValueKey('mobile-mouse-scroll'),
              generation: _gestureGeneration,
              label: _input.air
                  ? l10n.mobileControlHoldScroll
                  : l10n.mobileControlScroll,
              displayLabel: l10n.mobileControlScrollShort,
              icon: Icons.drag_indicator_rounded,
              enabled: _enabled,
              active: _input.scrolling,
              onDown: () {
                if (_input.air) _input.holdMotion(down: true, scroll: true);
              },
              onMove: _input.air
                  ? null
                  : (delta) => _input.move(Offset(0, delta.dy), scroll: true),
              onUp: () {
                if (_input.air) _input.holdMotion(down: false, scroll: true);
                _input.flush();
              },
            ),
          ),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: context.whisperPalette.borderSubtle,
          ),
          button(1, l10n.mobileControlRight, l10n.mobileControlRightShort),
        ],
      ),
    );
  }

  Future<void> _showPointerSettings() async {
    _textFocus.unfocus();
    _reset();
    await showWhisperModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      sheetAnimationStyle: _controlSheetAnimation,
      builder: (context) => ListenableBuilder(
        listenable: _input,
        builder: (context, _) => MobilePointerSettings(
          controller: _input,
          sensorsAvailable: _available,
          enabled: _enabled,
          onCalibrate: _beginCalibration,
        ),
      ),
    );
    if (mounted) {
      _reset();
      _syncSensors();
    }
  }

  void _beginCalibration() {
    _reset();
    _input.calibrate();
    _syncSensors();
    _calibrationTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      _input.cancelCalibration();
      _syncSensors();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.mobileControlCalibrationRetry)),
      );
    });
  }

  Widget _touchpad() {
    final generation = _gestureGeneration;
    // A fading-out surface can still receive events from an earlier touch.
    bool acceptsInput() =>
        _enabled && !_input.air && generation == _gestureGeneration;
    return GestureDetector(
      key: ValueKey(generation),
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (_) {},
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (acceptsInput()) {
            _pad.down(event.pointer, event.localPosition, event.timeStamp);
          }
        },
        onPointerMove: (event) {
          if (acceptsInput()) _pad.update(event.pointer, event.localPosition);
        },
        onPointerUp: (event) {
          if (acceptsInput()) _pad.up(event.pointer, event.timeStamp);
        },
        onPointerCancel: (_) {
          if (acceptsInput()) _pad.pointerCancel();
        },
        child: Semantics(
          excludeSemantics: true,
          label: l10n.mobileControlTouchHint,
          onTap: _enabled ? _input.click : null,
          child: Container(
            key: const ValueKey('mobile-touchpad'),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(20),
            child: _SurfaceLabel(
              icon: Icons.touch_app_outlined,
              label: l10n.mobileControlTouchpad,
              subtitle: l10n.mobileControlTouchHint,
              enabled: _enabled,
            ),
          ),
        ),
      ),
    );
  }

  Widget _keyboardPanel() => LayoutBuilder(
    builder: (context, constraints) {
      const padding = EdgeInsets.fromLTRB(12, 8, 12, 16);
      return SingleChildScrollView(
        key: const ValueKey('mobile-keyboard-panel'),
        padding: padding,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: math.max(0, constraints.maxHeight - padding.vertical),
          ),
          child: Column(
            mainAxisAlignment: _editingText
                ? MainAxisAlignment.start
                : MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _textPanel(),
              if (_editingText) ...[
                const SizedBox(height: 12),
                Text(
                  _target.platform.toLowerCase().contains('linux')
                      ? l10n.mobileControlLinuxTextHint
                      : l10n.mobileControlTextHint,
                  style: TextStyle(color: context.whisperPalette.textMuted),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _coordinator.isSendingText ? null : _returnToKeys,
                  child: Text(l10n.mobileControlReturnKeys),
                ),
              ] else
                _directKeyboard(),
            ],
          ),
        ),
      );
    },
  );

  Widget _directKeyboard() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                l10n.mobileControlDirectKeys,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            Tooltip(
              message: l10n.mobileControlShortcutHint,
              child: Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: context.whisperPalette.textMuted,
              ),
            ),
          ],
        ),
      ),
      MobileControlKeyboard(
        key: ValueKey('mobile-keyboard-$_keyPage'),
        controller: _input,
        enabled: _enabled,
        targetPlatform: _target.platform,
        page: _keyPage,
        onPageChanged: (page) {
          // Local modifiers may be combined with Fn keys; held repeats may not.
          _input.cancelRepeat();
          setState(() => _keyPage = page);
        },
      ),
    ],
  );

  Widget _textPanel() => Container(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
    decoration: BoxDecoration(
      color: context.whisperPalette.surfaceElevated,
      border: Border.all(color: context.whisperPalette.borderSubtle),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.mobileControlText,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        TextField(
          controller: _text,
          focusNode: _textFocus,
          minLines: 1,
          maxLines: 4,
          readOnly: _coordinator.isSendingText,
          decoration: InputDecoration(
            hintText: l10n.mobileControlDraftHint,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
          ),
        ),
        Align(
          alignment: Alignment.bottomRight,
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _text,
            builder: (context, value, _) => FilledButton(
              onPressed: _enabled && value.text.isNotEmpty ? _sendText : null,
              child: _coordinator.isSendingText
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.mobileControlSendText),
            ),
          ),
        ),
      ],
    ),
  );
}

class MobileControlStartException implements Exception {
  const MobileControlStartException(this.localizedMessage);
  // Only app-localized UI copy is accepted, never a native/network error.
  final String localizedMessage;
}

class _HoldArea extends StatefulWidget {
  const _HoldArea({
    super.key,
    this.displayLabel,
    this.icon,
    this.onMove,
    required this.label,
    required this.enabled,
    required this.onDown,
    required this.onUp,
    this.active = false,
    required this.generation,
  });
  final String label;
  final String? displayLabel;
  final IconData? icon;
  final ValueChanged<Offset>? onMove;
  final bool enabled, active;
  final int generation;
  final VoidCallback onDown, onUp;
  @override
  State<_HoldArea> createState() => _HoldAreaState();
}

class _HoldAreaState extends State<_HoldArea> {
  int? _pointer;
  void _release() {
    if (_pointer == null) return;
    _pointer = null;
    widget.onUp();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _HoldArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || widget.generation != oldWidget.generation) {
      _pointer = null;
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    excludeSemantics: true,
    enabled: widget.enabled,
    label: widget.label,
    onTap: widget.enabled
        ? () {
            widget.onDown();
            widget.onUp();
          }
        : null,
    child: RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: widget.enabled
          ? {
              EagerGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                    EagerGestureRecognizer.new,
                    (_) {},
                  ),
            }
          : {},
      child: Listener(
        onPointerDown: (event) {
          if (!widget.enabled || _pointer != null) return;
          _pointer = event.pointer;
          widget.onDown();
          setState(() {});
        },
        onPointerMove: (event) {
          if (widget.enabled && _pointer == event.pointer) {
            widget.onMove?.call(event.delta);
          }
        },
        onPointerUp: (event) {
          if (_pointer == event.pointer) _release();
        },
        onPointerCancel: (event) {
          if (_pointer == event.pointer) _release();
        },
        child: AnimatedContainer(
          // Input is delivered above immediately; only release feedback fades.
          duration:
              (_pointer != null || widget.active) ||
                  !widget.enabled ||
                  MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          decoration: BoxDecoration(
            color: (_pointer != null || widget.active) && widget.enabled
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                : context.whisperPalette.surfaceElevated,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(
                  widget.icon,
                  size: 22,
                  color: context.whisperPalette.textMuted,
                ),
                const SizedBox(height: 4),
              ],
              Flexible(
                child: Text(
                  widget.displayLabel ?? widget.label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: widget.enabled
                        ? null
                        : context.whisperPalette.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SurfaceLabel extends StatelessWidget {
  const _SurfaceLabel({
    required this.label,
    required this.enabled,
    this.icon,
    this.subtitle,
    this.active = false,
  });
  final String label;
  final String? subtitle;
  final IconData? icon;
  final bool enabled, active;
  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null &&
              constraints.maxHeight >=
                  MediaQuery.textScalerOf(
                    context,
                  ).scale(icon == Icons.smartphone_rounded ? 280 : 220)) ...[
            if (icon == Icons.smartphone_rounded)
              Container(
                width: 112,
                height: 112,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active
                      ? Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: .1)
                      : palette.surfaceElevated,
                  border: Border.all(color: palette.borderSubtle),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: palette.borderSubtle),
                  ),
                  child: Transform.rotate(
                    angle: -.15,
                    child: Icon(
                      icon,
                      size: 32,
                      color: active
                          ? Theme.of(context).colorScheme.primary
                          : palette.textMuted,
                    ),
                  ),
                ),
              )
            else
              Icon(icon, size: 32, color: palette.textMuted),
            const SizedBox(height: 16),
          ],
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: enabled ? null : palette.textMuted,
            ),
          ),
          if (subtitle != null && constraints.maxHeight >= 120) ...[
            const SizedBox(height: 8),
            Flexible(
              child: Text(
                subtitle!,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: palette.textMuted),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Duration _pointerModeDuration(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 260);

class _ModeSelector extends StatefulWidget {
  const _ModeSelector({
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.disabledIndex,
  });
  final List<String> labels;
  final int selected;
  final int? disabledIndex;
  final ValueChanged<int> onSelected;

  @override
  State<_ModeSelector> createState() => _ModeSelectorState();
}

class _ModeSelectorState extends State<_ModeSelector>
    with SingleTickerProviderStateMixin {
  late final _controller = _PointerTabController(
    length: widget.labels.length,
    initialIndex: widget.selected,
    vsync: this,
    canSelect: (index) => index != widget.disabledIndex,
    duration: () => _pointerModeDuration(context),
  );

  @override
  void didUpdateWidget(_ModeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controller.index != widget.selected) {
      _controller.animateTo(widget.selected);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WhisperTabBar(
    controller: _controller,
    scrollable: MediaQuery.textScalerOf(context).scale(14) > 18,
    onTap: widget.onSelected,
    tabs: [
      for (var i = 0; i < widget.labels.length; i++)
        Semantics(
          enabled: i != widget.disabledIndex,
          child: Tab(
            child: Text(
              widget.labels[i],
              maxLines: 1,
              style: i == widget.disabledIndex
                  ? TextStyle(color: Theme.of(context).disabledColor)
                  : null,
            ),
          ),
        ),
    ],
  );
}

// TabBar initiates animation before onTap; block unavailable sensor tabs here.
class _PointerTabController extends TabController {
  _PointerTabController({
    required super.length,
    required super.initialIndex,
    required super.vsync,
    required this.canSelect,
    required this.duration,
  }) : super(animationDuration: const Duration(milliseconds: 260));

  final bool Function(int) canSelect;
  final Duration Function() duration;

  @override
  void animateTo(int value, {Duration? duration, Curve curve = Curves.ease}) {
    if (!canSelect(value)) return;
    super.animateTo(value, duration: duration ?? this.duration(), curve: curve);
  }
}

class _PointerTexture extends CustomPainter {
  const _PointerTexture(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var x = 10.0; x < size.width; x += 20) {
      for (var y = 10.0; y < size.height; y += 20) {
        canvas.drawCircle(Offset(x, y), .65, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_PointerTexture oldDelegate) => oldDelegate.color != color;
}
