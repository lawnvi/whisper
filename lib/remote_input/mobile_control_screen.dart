import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/remote_input/mobile_input_controller.dart';
import 'package:whisper/remote_input/mobile_motion.dart';
import 'package:whisper/remote_input/mobile_touchpad.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_lifecycle.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/glass_bottom_sheet.dart';

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
  bool _transitioning = false;
  int _transitionGeneration = 0;
  Completer<void>? _orientationReady;
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
  bool _keyboardOrientation = false;
  StreamSubscription<MotionSample>? _samples;
  Timer? _calibrationTimer;
  bool _available = false,
      _checkedSensor = false,
      _starting = false,
      _stopping = false;
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
    _checkedSensor = true;
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
    if (_enabled && _available && _input.air && _tab == 0) {
      _samples ??= _sensor.samples().listen(
        (sample) {
          final calibrating = _input.motion.calibrating;
          _input.sample(sample);
          if (calibrating && !_input.motion.calibrating && mounted) {
            _calibrationTimer?.cancel();
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
    setState(() => _tab = tab);
    await _orientKeyboard(tab == 1, waitForMetrics: useAnimation);
    if (!mounted || generation != _transitionGeneration) return;
    setState(() => _transitioning = false);
    _refresh();
    if (useAnimation) {
      unawaited(_transition.forward());
    } else {
      _transition.value = 1;
    }
  }

  Future<void> _orientKeyboard(
    bool landscape, {
    bool waitForMetrics = false,
  }) async {
    if (_keyboardOrientation == landscape ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _keyboardOrientation = landscape;
    final ready = Completer<void>();
    _orientationReady = ready;
    try {
      await SystemChrome.setPreferredOrientations(
        landscape
            ? [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : [DeviceOrientation.portraitUp],
      );
      if (waitForMetrics && _landscape != landscape) {
        // Keep the old layout hidden until Android has delivered the new size.
        await ready.future.timeout(
          const Duration(milliseconds: 450),
          onTimeout: () {},
        );
      }
    } catch (_) {
      /* The scrollable layout remains usable if rotation is unavailable. */
    }
    if (_orientationReady == ready) _orientationReady = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_stop());
    if (state == AppLifecycleState.paused &&
        (_tab == 1 || _keyboardOrientation)) {
      unawaited(_selectTab(0, animate: false));
    }
  }

  @override
  void didChangeMetrics() {
    final size = View.of(context).physicalSize;
    final landscape = size.width > size.height;
    if (_landscape != null && _landscape != landscape) _reset();
    _landscape = landscape;
    if (landscape == _keyboardOrientation &&
        _orientationReady?.isCompleted == false) {
      _orientationReady!.complete();
    }
  }

  @override
  void dispose() {
    ++_startGeneration;
    ++_transitionGeneration;
    unawaited(_orientKeyboard(false));
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
    if (sent) _text.clear();
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
  Widget build(BuildContext context) => ColoredBox(
    color: context.whisperPalette.surfaceCanvas,
    child: IgnorePointer(
      ignoring: _transitioning,
      child: FadeTransition(
        opacity: CurvedAnimation(
          parent: _transition,
          curve: Curves.easeOutCubic,
        ),
        child: _buildPage(context),
      ),
    ),
  );

  Widget _buildPage(BuildContext context) {
    _landscape ??=
        View.of(context).physicalSize.width >
        View.of(context).physicalSize.height;
    final state = _coordinator.state;
    final busy = _starting || _stopping || (_ownsSession && state.isBusy);
    final palette = context.whisperPalette;
    if (_tab == 1) return _keyboardScreen(busy);
    return Scaffold(
      backgroundColor: palette.surfaceCanvas,
      appBar: AppBar(
        backgroundColor: palette.surfaceCanvas,
        title: _deviceTitle(),
        actions: [
          if (_tab == 0)
            IconButton(
              tooltip: l10n.mobileControlSettings,
              onPressed: _showPointerSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
          _sessionAction(busy),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (_error != null ||
                state.status == RemoteInputRuntimeStatus.failed)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 96),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    _error ?? _failureText(state.errorMessage),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _tab == 0
                  ? _pointerPanel()
                  : SingleChildScrollView(
                      child: _tab == 1 ? _keyboard() : _textPanel(),
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        height: 64,
        backgroundColor: palette.surfaceElevated,
        indicatorColor: Theme.of(
          context,
        ).colorScheme.primary.withValues(alpha: 0.12),
        selectedIndex: _tab,
        onDestinationSelected: _coordinator.isSendingText ? null : _selectTab,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.mouse_outlined),
            selectedIcon: Icon(
              Icons.mouse_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            label: l10n.mobileControlPointer,
          ),
          NavigationDestination(
            icon: const Icon(Icons.keyboard_outlined),
            selectedIcon: Icon(
              Icons.keyboard_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            label: l10n.mobileControlKeysTab,
          ),
          NavigationDestination(
            icon: const Icon(Icons.notes_rounded),
            selectedIcon: Icon(
              Icons.notes_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            label: l10n.mobileControlTextTab,
          ),
        ],
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
    _reset();
    final targets = widget.targets!();
    final selected = await showWhisperModalBottomSheet<MobileControlTarget>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
                  Text(l10n.mobileControlTargetHint),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final target in targets)
                    ListTile(
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
        Text(
          _active ? l10n.mobileControlActive : l10n.mobileControlReady,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: _active
                ? context.whisperPalette.trusted
                : context.whisperPalette.textMuted,
          ),
        ),
      ],
    ),
  );

  Widget _sessionAction(bool busy) => _ownsSession || _starting
      ? IconButton(
          tooltip: l10n.mobileControlStop,
          onPressed: _stopping ? null : _stop,
          icon: const Icon(Icons.stop_rounded),
        )
      : Tooltip(
          message: l10n.mobileControlStart,
          child: TextButton(
            onPressed: busy ? null : _start,
            child: Text(l10n.mobileControlStartShort),
          ),
        );

  Widget _pointerPanel() => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final wide =
          constraints.maxWidth > 600 &&
          constraints.maxHeight < 420 &&
          scale < 1.4;
      final minimumHeight = wide
          ? 300.0
          : scale < 1.4
          ? 360.0
          : 480.0 * scale;
      final height = math.max(constraints.maxHeight, minimumHeight);
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
                  if (index == 0 && !_available) return;
                  _reset();
                  _input.setAir(index == 0);
                  _syncSensors();
                },
                disabledIndex: _available ? null : 0,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _movementSurface()),
                          const SizedBox(width: 12),
                          SizedBox(width: 216, child: _pointerActions()),
                        ],
                      )
                    : Column(
                        children: [
                          Expanded(child: _movementSurface()),
                          const SizedBox(height: 12),
                          _pointerActions(),
                        ],
                      ),
              ),
              const SizedBox(height: 6),
              if (_input.air || (_checkedSensor && !_available))
                Text(
                  _checkedSensor && !_available
                      ? l10n.mobileControlSensorUnavailable
                      : !_active
                      ? l10n.mobileControlIdleHint
                      : l10n.mobileControlDragHint,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.whisperPalette.textMuted,
                  ),
                ),
            ],
          ),
        ),
      );
      // Only constrained windows scroll. Each input surface claims its own
      // pointers, including a second finger used to drag with a held button.
      return height > constraints.maxHeight
          ? SingleChildScrollView(child: panel)
          : panel;
    },
  );

  Widget _movementSurface() => !_input.air
      ? _touchpad()
      : Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Semantics(
                button: true,
                toggled: _input.moving,
                enabled: _enabled,
                child: Material(
                  color: _input.moving
                      ? Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.12)
                      : context.whisperPalette.surfaceElevated,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                    side: BorderSide(
                      color: context.whisperPalette.borderSubtle,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _enabled ? _input.toggleMotion : null,
                    onTapCancel: _enabled ? _input.reset : null,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: _SurfaceLabel(
                          label: _input.moving
                              ? l10n.mobileControlMotionPause
                              : l10n.mobileControlMotionStart,
                          subtitle: _input.moving
                              ? l10n.mobileControlMotionOnHint
                              : l10n.mobileControlMotionOffHint,
                          icon: _input.moving
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          enabled: _enabled,
                          active: _input.moving,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 52,
              child: Semantics(
                label: l10n.mobileControlScroll,
                child: Tooltip(
                  message: l10n.mobileControlScroll,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragUpdate: _enabled
                        ? (d) =>
                              _input.move(Offset(0, d.delta.dy), scroll: true)
                        : null,
                    onVerticalDragEnd: (_) => _input.flush(),
                    onVerticalDragCancel: _input.flush,
                    child: Container(
                      decoration: _surfaceDecoration(),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.swipe_vertical_rounded,
                            color: context.whisperPalette.textMuted,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l10n.mobileControlScrollRail,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: context.whisperPalette.textMuted,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );

  BoxDecoration _surfaceDecoration() => BoxDecoration(
    color: context.whisperPalette.surfaceElevated,
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: context.whisperPalette.borderSubtle),
  );

  Widget _pointerActions() {
    final buttonHeight = math.max(
      _input.air ? 64.0 : 48.0,
      MediaQuery.textScalerOf(context).scale(14) * 3.2 + 18,
    );
    Widget button(int number, String label) => Expanded(
      child: _HoldArea(
        generation: _gestureGeneration,
        label: label,
        enabled: _enabled,
        onDown: () => _input.button(number, true),
        onUp: () => _input.button(number, false),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: buttonHeight,
          child: Row(
            children: [
              button(0, l10n.mobileControlLeft),
              const SizedBox(width: 10),
              button(1, l10n.mobileControlRight),
            ],
          ),
        ),
        if (_input.air) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: buttonHeight,
            width: double.infinity,
            child: _HoldArea(
              generation: _gestureGeneration,
              label: l10n.mobileControlHoldScroll,
              enabled: _enabled,
              active: _input.scrolling,
              onDown: () => _input.holdMotion(down: true, scroll: true),
              onUp: () => _input.holdMotion(down: false, scroll: true),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _showPointerSettings() async {
    _reset();
    await showWhisperModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => ListenableBuilder(
        listenable: _input,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.mobileControlSettings,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 24),
              _speedSlider(
                l10n.mobileControlPointerSpeed,
                _input.pointerSpeed,
                (value) {
                  _input.setPointerSpeed(value);
                },
                LocalSetting().setMobilePointerSpeed,
              ),
              _speedSlider(
                l10n.mobileControlScrollSpeed,
                _input.scrollSpeed,
                (value) {
                  _input.setScrollSpeed(value);
                },
                LocalSetting().setMobileScrollSpeed,
              ),
              if (_available) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(child: Text(l10n.mobileControlSensitivity)),
                    Text(
                      '${_input.motion.sensitivity.toStringAsFixed(2)}×',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                Slider(
                  value: _input.motion.sensitivity,
                  min: 0.5,
                  max: 3,
                  divisions: 10,
                  onChanged: (value) {
                    _input.setSensitivity(value);
                  },
                  onChangeEnd: (value) => unawaited(
                    LocalSetting().setMobileInputSensitivity(value),
                  ),
                ),
                Text(
                  l10n.mobileControlPrecisionHint,
                  style: TextStyle(color: context.whisperPalette.textMuted),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.center_focus_strong_rounded),
                    onPressed: !_enabled || _input.motion.calibrating
                        ? null
                        : () {
                            _reset();
                            _input.calibrate();
                            _calibrationTimer = Timer(
                              const Duration(seconds: 5),
                              () {
                                if (!mounted) return;
                                _input.cancelCalibration();
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      l10n.mobileControlCalibrationRetry,
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                    label: Text(
                      _input.motion.calibrating
                          ? l10n.mobileControlCalibrating
                          : l10n.mobileControlCalibrate,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (mounted) _reset();
  }

  Widget _speedSlider(
    String label,
    double value,
    ValueChanged<double> onChanged,
    Future<void> Function(double) save,
  ) => Column(
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text('${value.toStringAsFixed(2)}×'),
        ],
      ),
      Slider(
        value: value,
        min: 0.5,
        max: 3,
        divisions: 10,
        label: label,
        onChanged: onChanged,
        onChangeEnd: (value) => unawaited(save(value)),
      ),
    ],
  );

  Widget _touchpad() => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanUpdate: (_) {},
    child: Listener(
      onPointerDown: (event) {
        if (_enabled) {
          _pad.down(event.pointer, event.localPosition, event.timeStamp);
        }
      },
      onPointerMove: (event) {
        if (_enabled) _pad.update(event.pointer, event.localPosition);
      },
      onPointerUp: (event) {
        if (_enabled) _pad.up(event.pointer, event.timeStamp);
      },
      onPointerCancel: (_) => _pad.pointerCancel(),
      child: Semantics(
        excludeSemantics: true,
        label: l10n.mobileControlTouchHint,
        onTap: _enabled ? _input.click : null,
        child: Container(
          key: const ValueKey('mobile-touchpad'),
          alignment: Alignment.center,
          decoration: _surfaceDecoration(),
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

  Widget _keyboardScreen(bool busy) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _selectTab(0);
    },
    child: Scaffold(
      backgroundColor: context.whisperPalette.surfaceCanvas,
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: context.whisperPalette.surfaceCanvas,
        leading: IconButton(
          tooltip: l10n.mobileControlPointer,
          onPressed: () => _selectTab(0),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        titleSpacing: 4,
        title: Row(
          children: [
            if (View.of(context).physicalSize.width /
                    View.of(context).devicePixelRatio >
                550) ...[
              SizedBox(width: 110, child: _deviceTitle()),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: _ModeSelector(
                compact: true,
                labels: [
                  l10n.mobileControlMainKeys,
                  l10n.mobileControlFunctionKeys,
                ],
                selected: _keyPage,
                onSelected: (index) {
                  _reset();
                  setState(() => _keyPage = index);
                },
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: l10n.mobileControlShortcutHint,
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.mobileControlShortcutHint)),
            ),
            icon: const Icon(Icons.info_outline_rounded),
          ),
          _sessionAction(busy),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_error != null ||
                _coordinator.state.status == RemoteInputRuntimeStatus.failed)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 64),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    _error ?? _failureText(_coordinator.state.errorMessage),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            Expanded(child: _keyboard()),
          ],
        ),
      ),
    ),
  );

  bool get _macTarget => _target.platform.toLowerCase().contains('mac');
  String get _metaLabel => _macTarget
      ? 'Cmd'
      : _target.platform.toLowerCase().contains('win')
      ? 'Win'
      : 'Super';

  Widget _keyboard() {
    // Keep 12 columns in landscape. Less-used punctuation shares the Fn page.
    final rows = <List<(String, String)>>[
      if (_keyPage == 0) ...[
        [
          ('escape', 'Esc'),
          for (final v in '1234567890'.split('')) ('digit$v', v),
          ('backspace', '⌫'),
        ],
        [
          ('tab', 'Tab'),
          for (final v in 'QWERTYUIOP'.split('')) ('key$v', v),
          ('backslash', '\\'),
        ],
        [
          ('capsLock', 'Caps'),
          for (final v in 'ASDFGHJKL'.split('')) ('key$v', v),
          ('enter', 'Enter'),
        ],
        [
          ('shift', 'Shift'),
          for (final v in 'ZXCVBNM'.split('')) ('key$v', v),
          ('comma', ','),
          ('period', '.'),
          ('slash', '/'),
        ],
      ] else ...[
        [for (var i = 1; i <= 12; i++) ('f$i', 'F$i')],
        [
          ('home', 'Home'),
          ('end', 'End'),
          ('pageUp', 'PgUp'),
          ('pageDown', 'PgDn'),
          ('delete', 'Delete'),
        ],
        [
          ('backquote', '`'),
          ('minus', '-'),
          ('equal', '='),
          ('bracketLeft', '['),
          ('bracketRight', ']'),
          ('semicolon', ';'),
          ('quote', "'"),
        ],
      ],
      [
        ('meta', _metaLabel),
        ('control', 'Ctrl'),
        ('alt', _macTarget ? 'Opt' : 'Alt'),
        if (_keyPage == 1) ('shift', 'Shift'),
        ('space', 'Space'),
        ('arrowLeft', '←'),
        ('arrowDown', '↓'),
        ('arrowUp', '↑'),
        ('arrowRight', '→'),
      ],
    ];
    double weight(String key) => switch (key) {
      'capsLock' => 1.25,
      'enter' => 1.75,
      'shift' => 1.75,
      'space' => 3.25,
      'meta' || 'control' || 'alt' => 1.1,
      _ => 1,
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final width = math.max(
          620.0 * math.max(1, scale),
          constraints.maxWidth - 16,
        );
        final keyHeight = math.max(
          48.0 * math.max(1, scale),
          math.min(
            56.0,
            (constraints.maxHeight - 16 - (rows.length - 1) * 4) / rows.length,
          ),
        );
        return SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: SingleChildScrollView(
              key: ValueKey('keyboard-$_keyPage'),
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: Column(
                  children: [
                    for (
                      var rowIndex = 0;
                      rowIndex < rows.length;
                      rowIndex++
                    ) ...[
                      if (rowIndex > 0) const SizedBox(height: 4),
                      SizedBox(
                        height: keyHeight,
                        child: Row(
                          children: [
                            for (
                              var index = 0;
                              index < rows[rowIndex].length;
                              index++
                            ) ...[
                              if (index > 0) const SizedBox(width: 4),
                              Expanded(
                                flex: (weight(rows[rowIndex][index].$1) * 100)
                                    .round(),
                                child: _keyboardKey(
                                  rows[rowIndex][index].$1,
                                  rows[rowIndex][index].$2,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _keyboardKey(String semantic, String label) {
    final modifier = switch (semantic) {
      'meta' => _macTarget ? 'Command' : _metaLabel,
      'control' => 'Control',
      'alt' => _macTarget ? 'Option' : 'Alt',
      'shift' => 'Shift',
      _ => null,
    };
    return SizedBox(
      key: ValueKey('mobile-key-$semantic'),
      child: modifier == null
          ? _VirtualKey(
              label: label,
              enabled: _enabled,
              onTap: () => _input.key(semantic),
              repeat: semantic.startsWith('arrow') || semantic == 'backspace',
              onRepeatStart: () =>
                  _input.beginRepeat(semantic, immediate: true),
              onRepeatStop: _input.cancelRepeat,
            )
          : Tooltip(
              message: modifier,
              child: Semantics(
                label: modifier,
                selected: _input.modifiers.contains(semantic),
                child: OutlinedButton(
                  onPressed: _enabled
                      ? () => _input.toggleModifier(semantic)
                      : null,
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                    backgroundColor: _input.modifiers.contains(semantic)
                        ? Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.12)
                        : context.whisperPalette.surfaceElevated,
                    side: BorderSide(
                      color: _input.modifiers.contains(semantic)
                          ? Theme.of(context).colorScheme.primary
                          : context.whisperPalette.borderSubtle,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _textPanel() => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      children: [
        Text(
          _target.platform.toLowerCase().contains('linux')
              ? l10n.mobileControlLinuxTextHint
              : l10n.mobileControlTextHint,
          style: TextStyle(color: context.whisperPalette.textMuted),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _text,
          minLines: 6,
          maxLines: 12,
          readOnly: _coordinator.isSendingText,
          decoration: InputDecoration(
            labelText: l10n.mobileControlText,
            filled: true,
            fillColor: context.whisperPalette.surfaceElevated,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _enabled ? _sendText : null,
            child: _coordinator.isSendingText
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.mobileControlSendText),
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
    required this.label,
    required this.enabled,
    required this.onDown,
    required this.onUp,
    this.active = false,
    required this.generation,
  });
  final String label;
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
        onPointerUp: (event) {
          if (_pointer == event.pointer) _release();
        },
        onPointerCancel: (event) {
          if (_pointer == event.pointer) _release();
        },
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: context.whisperPalette.borderSubtle),
            color: (_pointer != null || widget.active) && widget.enabled
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                : context.whisperPalette.surfaceElevated,
          ),
          child: _SurfaceLabel(
            label: widget.label,
            enabled: widget.enabled,
            active: _pointer != null || widget.active,
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
          if (icon != null && constraints.maxHeight >= 160) ...[
            Icon(
              icon,
              size: 32,
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : palette.textMuted,
            ),
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
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: palette.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.disabledIndex,
    this.compact = false,
  });
  final bool compact;
  final List<String> labels;
  final int selected;
  final int? disabledIndex;
  final ValueChanged<int> onSelected;
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(compact ? 0 : 4),
    decoration: BoxDecoration(
      color: context.whisperPalette.surfaceMuted,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: Semantics(
              selected: selected == i,
              child: TextButton(
                onPressed: disabledIndex == i ? null : () => onSelected(i),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
                  backgroundColor: selected == i
                      ? context.whisperPalette.surfaceElevated
                      : null,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  labels[i],
                  textAlign: TextAlign.center,
                  style: compact ? const TextStyle(fontSize: 12) : null,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _VirtualKey extends StatefulWidget {
  const _VirtualKey({
    required this.label,
    required this.enabled,
    required this.onTap,
    required this.repeat,
    required this.onRepeatStart,
    required this.onRepeatStop,
  });
  final String label;
  final bool enabled, repeat;
  final VoidCallback onTap, onRepeatStart, onRepeatStop;
  @override
  State<_VirtualKey> createState() => _VirtualKeyState();
}

class _VirtualKeyState extends State<_VirtualKey> {
  void _cancel() {
    widget.onRepeatStop();
  }

  @override
  void didUpdateWidget(covariant _VirtualKey oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _cancel();
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    gestures: widget.enabled && widget.repeat
        ? <Type, GestureRecognizerFactory>{
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer
                >(
                  () => LongPressGestureRecognizer(
                    duration: const Duration(milliseconds: 400),
                  ),
                  (recognizer) {
                    recognizer.onLongPressStart = (_) {
                      widget.onRepeatStart();
                    };
                    recognizer.onLongPressEnd = (_) {
                      _cancel();
                    };
                    recognizer.onLongPressCancel = _cancel;
                  },
                ),
          }
        : const <Type, GestureRecognizerFactory>{},
    child: OutlinedButton(
      onPressed: widget.enabled ? widget.onTap : null,
      style: OutlinedButton.styleFrom(
        padding: EdgeInsets.zero,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        backgroundColor: context.whisperPalette.surfaceElevated,
        side: BorderSide(color: context.whisperPalette.borderSubtle),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(widget.label),
    ),
  );
}
