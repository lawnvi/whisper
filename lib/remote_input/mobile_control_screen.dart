import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/remote_input/mobile_input_controller.dart';
import 'package:whisper/remote_input/mobile_motion.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_lifecycle.dart';
import 'package:whisper/theme/app_theme.dart';

class MobileControlScreen extends StatefulWidget {
  const MobileControlScreen({
    super.key,
    required this.peerId,
    required this.peerName,
    required this.onStart,
    required this.onStop,
    this.coordinator,
    this.sensor,
  });
  final String peerId;
  final String peerName;
  final Future<void> Function() onStart;
  final Future<void> Function() onStop;
  final RemoteInputCoordinator? coordinator;
  final MobileMotionSensor? sensor;
  @override
  State<MobileControlScreen> createState() => _MobileControlScreenState();
}

class _MobileControlScreenState extends State<MobileControlScreen>
    with WidgetsBindingObserver {
  late final RemoteInputCoordinator _coordinator =
      widget.coordinator ?? RemoteInputCoordinator.shared;
  late final MobileMotionSensor _sensor = widget.sensor ?? MobileMotionSensor();
  late final MobileInputController _input = MobileInputController(
    _coordinator.sendManualInput,
  );
  final _text = TextEditingController();
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
    'permission' => l10n.mobileControlPermission,
    'busy' => l10n.remoteInputStopCurrentFirst,
    'trustRequired' => l10n.remoteInputRequiresMutualTrust,
    'unsupported' => l10n.remoteInputPeerUnsupported,
    _ => l10n.connectFailed,
  };
  bool? _landscape;
  bool _touchMoved = false;
  Offset? _touchOrigin;
  int _gestureGeneration = 0;
  final Map<int, Offset> _touches = {};
  AppLocalizations get l10n => AppLocalizations.of(context)!;
  bool get _ownsSession =>
      _coordinator.isManual &&
      _coordinator.state.isForPeer(widget.peerId) &&
      _coordinator.state.role == RemoteInputRuntimeRole.source;
  bool get _active => _ownsSession && _coordinator.state.isActive;
  bool get _enabled => _active && !_coordinator.isSendingText && !_stopping;

  @override
  void initState() {
    super.initState();
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
    if (!mounted) return;
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
      await widget.onStart();
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
    _touches.clear();
    _touchOrigin = null;
    _calibrationTimer?.cancel();
    _input.reset();
  }

  void _selectTab(int tab) {
    _reset();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _tab = tab;
    });
    _syncSensors();
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
  Widget build(BuildContext context) {
    _landscape ??=
        View.of(context).physicalSize.width >
        View.of(context).physicalSize.height;
    final state = _coordinator.state;
    final busy = _starting || _stopping || (_ownsSession && state.isBusy);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.mobileControlTitle),
        actions: [
          if (_ownsSession || _starting)
            TextButton(
              onPressed: _stopping ? null : _stop,
              child: Text(l10n.mobileControlStop),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.peerName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (busy)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Text(
                      _active
                          ? l10n.mobileControlActive
                          : l10n.mobileControlReady,
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    if (_error != null ||
                        state.status == RemoteInputRuntimeStatus.failed)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _error ?? _failureText(state.errorMessage),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (!_ownsSession && !_starting)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Text(l10n.mobileControlIdleHint),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _starting ? null : _start,
                              icon: const Icon(Icons.play_arrow),
                              label: Text(l10n.mobileControlStart),
                            ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          for (final (index, label, icon) in [
                            (
                              0,
                              _input.air
                                  ? l10n.mobileControlAir
                                  : l10n.mobileControlTouchpad,
                              Icons.mouse_outlined,
                            ),
                            (
                              1,
                              l10n.mobileControlKeyboard,
                              Icons.keyboard_outlined,
                            ),
                            (2, l10n.mobileControlText, Icons.edit_outlined),
                          ])
                            ChoiceChip(
                              label: Text(label),
                              avatar: Icon(icon, size: 18),
                              selected: _tab == index,
                              onSelected: _coordinator.isSendingText
                                  ? null
                                  : (_) => _selectTab(index),
                            ),
                        ],
                      ),
                    ),
                    _tab == 0
                        ? _pointerPanel()
                        : _tab == 1
                        ? _keyboard()
                        : _textPanel(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pointerPanel() => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.mobileControlAir),
          value: _input.air,
          onChanged: _available
              ? (value) {
                  _reset();
                  _input.setAir(value);
                  _syncSensors();
                }
              : null,
        ),
        if (_checkedSensor && !_available)
          Text(l10n.mobileControlSensorUnavailable),
        const SizedBox(height: 8),
        SizedBox(
          height: 220,
          width: double.infinity,
          child: _input.air
              ? _HoldArea(
                  generation: _gestureGeneration,
                  label: l10n.mobileControlHoldMove,
                  enabled: _enabled,
                  active: _input.moving,
                  onDown: () => _input.holdMotion(down: true),
                  onUp: () => _input.holdMotion(down: false),
                )
              : _touchpad(),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 60,
                child: _HoldArea(
                  generation: _gestureGeneration,
                  label: l10n.mobileControlLeft,
                  enabled: _enabled,
                  onDown: () => _input.button(0, true),
                  onUp: () => _input.button(0, false),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 60,
                child: _HoldArea(
                  generation: _gestureGeneration,
                  label: l10n.mobileControlRight,
                  enabled: _enabled,
                  onDown: () => _input.button(1, true),
                  onUp: () => _input.button(1, false),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_input.air)
          SizedBox(
            height: 56,
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
        const SizedBox(height: 8),
        GestureDetector(
          onVerticalDragUpdate: _enabled
              ? (d) => _input.move(Offset(0, d.delta.dy), scroll: true)
              : null,
          onVerticalDragEnd: (_) => _input.flush(),
          onVerticalDragCancel: _input.flush,
          child: Container(
            height: 64,
            alignment: Alignment.center,
            color: context.whisperPalette.surfaceElevated,
            child: Text(l10n.mobileControlScroll),
          ),
        ),
        if (_input.air) ...[
          const SizedBox(height: 12),
          Text(l10n.mobileControlSensitivity),
          Slider(
            value: _input.motion.sensitivity,
            min: 0.5,
            max: 3,
            divisions: 10,
            label: '${_input.motion.sensitivity.toStringAsFixed(1)}×',
            onChanged: (value) => setState(() {
              _input.motion.sensitivity = value;
            }),
            onChangeEnd: (value) =>
                unawaited(LocalSetting().setMobileInputSensitivity(value)),
          ),
          OutlinedButton(
            onPressed: !_enabled
                ? null
                : () {
                    _reset();
                    _input.motion.calibrate();
                    _redraw();
                    _calibrationTimer = Timer(const Duration(seconds: 5), () {
                      if (!mounted) return;
                      _input.motion.cancelCalibration();
                      _redraw();
                    });
                  },
            child: Text(
              _input.motion.calibrating
                  ? l10n.mobileControlCalibrating
                  : l10n.mobileControlCalibrate,
            ),
          ),
        ],
      ],
    ),
  );

  Widget _touchpad() => GestureDetector(
    onPanUpdate: (_) {},
    child: Listener(
      onPointerDown: (event) {
        if (!_enabled) return;
        if (_touches.isEmpty) {
          _touchMoved = false;
          _touchOrigin = event.localPosition;
        }
        _touches[event.pointer] = event.localPosition;
        if (_touches.length > 1) {
          _touchMoved = true;
          _input.flush();
        }
      },
      onPointerMove: (event) {
        if (!_enabled || !_touches.containsKey(event.pointer)) return;
        final previous = _touches[event.pointer]!;
        final delta = event.localPosition - previous;
        _touches[event.pointer] = event.localPosition;
        if (_touchOrigin != null &&
            (event.localPosition - _touchOrigin!).distance > kTouchSlop) {
          _touchMoved = true;
        }
        _input.move(
          delta / (_touches.length > 1 ? _touches.length.toDouble() : 1),
          scroll: _touches.length > 1,
        );
      },
      onPointerUp: (event) {
        if (!_touches.containsKey(event.pointer)) return;
        _touches.remove(event.pointer);
        _input.flush();
        if (_touches.isEmpty && !_touchMoved) _input.click();
      },
      onPointerCancel: (_) {
        _touches.clear();
        _input.reset();
      },
      child: Semantics(
        label: l10n.mobileControlTouchHint,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: context.whisperPalette.surfaceElevated,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.all(16),
          child: Text(l10n.mobileControlTouchHint, textAlign: TextAlign.center),
        ),
      ),
    ),
  );

  Widget _keyboard() {
    // Legends match physical key caps; application labels are localized.
    final rows = _keyPage == 0
        ? <List<(String, String)>>[
            [
              ('escape', 'Esc'),
              for (final v in '1234567890'.split('')) ('digit$v', v),
              ('minus', '-'),
              ('equal', '='),
              ('backspace', '⌫'),
            ],
            [
              ('tab', 'Tab'),
              for (final v in 'QWERTYUIOP'.split('')) ('key$v', v),
              ('bracketLeft', '['),
              ('bracketRight', ']'),
              ('backslash', '\\'),
            ],
            [
              ('capsLock', 'Caps'),
              for (final v in 'ASDFGHJKL'.split('')) ('key$v', v),
              ('semicolon', ';'),
              ('quote', "'"),
              ('enter', 'Enter'),
            ],
            [
              ('backquote', '`'),
              for (final v in 'ZXCVBNM'.split('')) ('key$v', v),
              ('comma', ','),
              ('period', '.'),
              ('slash', '/'),
              ('space', 'Space'),
            ],
          ]
        : <List<(String, String)>>[
            [for (var i = 1; i <= 6; i++) ('f$i', 'F$i')],
            [for (var i = 7; i <= 12; i++) ('f$i', 'F$i')],
            [
              ('home', 'Home'),
              ('end', 'End'),
              ('pageUp', 'PgUp'),
              ('pageDown', 'PgDn'),
              ('delete', 'Delete'),
            ],
            [
              ('arrowLeft', '←'),
              ('arrowUp', '↑'),
              ('arrowDown', '↓'),
              ('arrowRight', '→'),
            ],
          ];
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: Text(l10n.mobileControlMainKeys),
                selected: _keyPage == 0,
                onSelected: (_) {
                  _reset();
                  setState(() {
                    _keyPage = 0;
                  });
                },
              ),
              ChoiceChip(
                label: Text(l10n.mobileControlFunctionKeys),
                selected: _keyPage == 1,
                onSelected: (_) {
                  _reset();
                  setState(() {
                    _keyPage = 1;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(l10n.mobileControlShortcutHint),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (semantic, label) in [
                ('meta', '⌘ Command'),
                ('control', '⌃ Control'),
                ('alt', '⌥ Option'),
                ('shift', '⇧ Shift'),
              ])
                FilterChip(
                  label: Text(label),
                  selected: _input.modifiers.contains(semantic),
                  onSelected: _enabled
                      ? (_) => _input.toggleModifier(semantic)
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            key: ValueKey(_keyPage),
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final row in rows)
                  Row(
                    children: [
                      for (final (semantic, label) in row)
                        Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 8),
                          child: SizedBox(
                            width: semantic == 'space' ? 104 : 64,
                            height: 52,
                            child: _VirtualKey(
                              label: label,
                              enabled: _enabled,
                              onTap: () => _input.key(semantic),
                              repeat:
                                  semantic.startsWith('arrow') ||
                                  semantic == 'backspace',
                              onRepeatStart: () =>
                                  _input.beginRepeat(semantic, immediate: true),
                              onRepeatStop: _input.cancelRepeat,
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
    );
  }

  Widget _textPanel() => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      children: [
        Text(l10n.mobileControlTextHint),
        const SizedBox(height: 16),
        TextField(
          controller: _text,
          minLines: 3,
          maxLines: 8,
          readOnly: _coordinator.isSendingText,
          decoration: InputDecoration(labelText: l10n.mobileControlText),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _enabled ? _sendText : null,
          child: _coordinator.isSendingText
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.mobileControlSendText),
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
    enabled: widget.enabled,
    label: widget.label,
    onTap: widget.enabled
        ? () {
            widget.onDown();
            widget.onUp();
          }
        : null,
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
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: (_pointer != null || widget.active) && widget.enabled
              ? Theme.of(context).colorScheme.primaryContainer
              : context.whisperPalette.surfaceElevated,
        ),
        child: Text(
          widget.label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: widget.enabled ? null : Theme.of(context).disabledColor,
          ),
        ),
      ),
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
      style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
      child: Text(widget.label),
    ),
  );
}
