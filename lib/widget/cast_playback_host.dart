import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import 'package:whisper/cast_receiver/player.dart';
import 'package:whisper/cast_receiver/request_gate.dart';
import 'package:whisper/cast_receiver/upnp.dart' show timeText;
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/cast_request_prompt.dart';

/// Keeps the main navigation mounted while playback is shown in a child window.
class CastPlaybackHost extends StatelessWidget {
  const CastPlaybackHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final requests = CastRequestGate.shared;
    return AnimatedBuilder(
      animation: requests,
      child: child,
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [
          child ?? const SizedBox.shrink(),
          if (requests.pending case final request?)
            CastRequestPrompt(
              key: ObjectKey(request),
              request: request,
              gate: requests,
            ),
        ],
      ),
    );
  }
}

class CastPlaybackView extends StatefulWidget {
  const CastPlaybackView({
    super.key,
    required this.player,
    this.localVideo = false,
  });
  final CastPlayer player;
  final bool localVideo;

  @override
  State<CastPlaybackView> createState() => _CastPlaybackViewState();
}

class _CastPlaybackViewState extends State<CastPlaybackView>
    with WindowListener {
  double? _seekPreview;
  double? _volumePreview;
  double? _pendingVolume;
  bool _sendingVolume = false;
  bool _draggingVolume = false;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  bool _pointerDown = false;
  bool _keyboardControls = false;
  Timer? _hideTimer;

  bool get _showPlay =>
      widget.player.paused || widget.player.status['state'] == 'STOPPED';

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  void _activity({bool pointer = false}) {
    if (!mounted) return;
    if (pointer) _keyboardControls = false;
    _hideTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    if (!_fullscreen ||
        _pointerDown ||
        _keyboardControls ||
        _seekPreview != null ||
        _volumePreview != null) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _fullscreen) setState(() => _controlsVisible = false);
    });
  }

  void _setFullscreen(bool value) {
    if (!mounted) return;
    setState(() => _fullscreen = value);
    _activity();
  }

  @override
  void onWindowEnterFullScreen() => _setFullscreen(true);
  @override
  void onWindowLeaveFullScreen() => _setFullscreen(false);

  Future<void> _command(
    String command, [
    Map<String, Object> data = const {},
  ]) async {
    _activity();
    try {
      await widget.player.command(command, data);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.castControlFailed),
        ),
      );
    }
  }

  Future<void> _toggleFullscreen() async {
    final fullscreen = !await windowManager.isFullScreen();
    await windowManager.setFullScreen(fullscreen);
    _setFullscreen(fullscreen);
  }

  void _changeVolume(double value) {
    setState(() => _volumePreview = value);
    _pendingVolume = value;
    _activity();
    if (!_sendingVolume) unawaited(_sendVolume());
  }

  Future<void> _sendVolume() async {
    _sendingVolume = true;
    try {
      // Keep only the newest unsent value while the player acknowledges a write.
      while (mounted && _pendingVolume != null) {
        final value = _pendingVolume!;
        _pendingVolume = null;
        await _command('volume', {'value': value});
      }
    } finally {
      _sendingVolume = false;
      if (mounted && !_draggingVolume) _finishVolumeChange();
    }
  }

  void _finishVolumeChange() {
    _draggingVolume = false;
    // Preserve the thumb position until the last write has completed.
    if (!_sendingVolume) setState(() => _volumePreview = null);
    _activity();
  }

  @override
  void dispose() {
    _pendingVolume = null;
    _hideTimer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  Widget _chrome({required Widget child, required bool visible}) =>
      IgnorePointer(
        ignoring: !visible,
        child: ExcludeFocus(
          excluding: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            child: child,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final l10n = AppLocalizations.of(context)!;
    final state = player.status;
    final failed = state['error'] != '';
    final controller = player.videoController;
    final visible = !_fullscreen || _controlsVisible || failed;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.tab) {
          _keyboardControls = true;
        }
        _activity();
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          unawaited(_fullscreen ? _toggleFullscreen() : _command('stop'));
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyF &&
            node.hasPrimaryFocus) {
          unawaited(_toggleFullscreen());
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.space &&
            node.hasPrimaryFocus &&
            controller != null &&
            !failed) {
          unawaited(_command(_showPlay ? 'play' : 'pause'));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: visible ? MouseCursor.defer : SystemMouseCursors.none,
        onHover: (_) => _activity(pointer: true),
        onEnter: (_) => _activity(pointer: true),
        child: Listener(
          onPointerDown: (_) {
            _pointerDown = true;
            _activity(pointer: true);
          },
          onPointerMove: (_) => _activity(pointer: true),
          onPointerUp: (_) {
            _pointerDown = false;
            _activity(pointer: true);
          },
          onPointerCancel: (_) {
            _pointerDown = false;
            _activity(pointer: true);
          },
          onPointerSignal: (_) => _activity(pointer: true),
          child: Theme(
            data: AppTheme.darkTheme,
            child: Scaffold(
              backgroundColor: Colors.black,
              body: Stack(
                fit: StackFit.expand,
                children: [
                  if (controller != null)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: failed
                          ? null
                          : () => unawaited(
                              _command(_showPlay ? 'play' : 'pause'),
                            ),
                      child: Video(
                        controller: controller,
                        controls: NoVideoControls,
                        pauseUponEnteringBackgroundMode: false,
                        resumeUponEnteringForegroundMode: false,
                      ),
                    ),
                  if (failed)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.localVideo
                                ? l10n.videoPlaybackFailed
                                : l10n.castPlaybackFailed,
                          ),
                          TextButton(
                            onPressed: () => unawaited(_command('play')),
                            child: Text(l10n.retry),
                          ),
                        ],
                      ),
                    )
                  else if (controller == null ||
                      state['state'] == 'TRANSITIONING')
                    const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  Align(
                    alignment: Alignment.topCenter,
                    child: _chrome(
                      visible: visible,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0xB3000000), Colors.transparent],
                          ),
                        ),
                        padding: const EdgeInsets.fromLTRB(24, 12, 16, 28),
                        child: SafeArea(
                          bottom: false,
                          child: Row(
                            children: [
                              Icon(
                                widget.localVideo
                                    ? Icons.movie_outlined
                                    : Icons.tv_rounded,
                                size: 18,
                                color: Colors.white70,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  widget.localVideo
                                      ? player.metadata
                                      : l10n.castReceiverTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: l10n.close,
                                onPressed: () => unawaited(_command('stop')),
                                icon: const Icon(
                                  Icons.close_rounded,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: _chrome(visible: visible, child: _controls(context)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final player = widget.player;
    final state = player.status;
    final l10n = AppLocalizations.of(context)!;
    final duration = (state['duration'] as num).toDouble();
    final position = (state['position'] as num).toDouble();
    final volume = (state['volume'] as num).toDouble();
    final failed = state['error'] != '';
    final controller = player.videoController;
    const numbers = TextStyle(
      fontSize: 12,
      color: Colors.white70,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0xD9000000)],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 16),
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Keep the volume control compact so it does not dominate the
            // transport controls on normal desktop widths.
            final volumeWidth = (constraints.maxWidth * .14).clamp(96.0, 160.0);
            return SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: Colors.white12,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    label: l10n.castSeek,
                    child: Slider(
                      value: (_seekPreview ?? position).clamp(
                        0,
                        duration > 0 ? duration : 1,
                      ),
                      max: duration > 0 ? duration : 1,
                      semanticFormatterCallback: timeText,
                      onChanged: duration <= 0 || failed
                          ? null
                          : (value) {
                              setState(() => _seekPreview = value);
                              _activity();
                            },
                      onChangeEnd: (value) {
                        setState(() => _seekPreview = null);
                        unawaited(_command('seek', {'seconds': value}));
                      },
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: _showPlay ? l10n.castPlay : l10n.castPause,
                        onPressed: failed || controller == null
                            ? null
                            : () => unawaited(
                                _command(_showPlay ? 'play' : 'pause'),
                              ),
                        iconSize: 30,
                        icon: Icon(
                          _showPlay
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${timeText(_seekPreview ?? position)} / ${timeText(duration)}',
                        style: numbers,
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: state['muted'] == true
                            ? l10n.castUnmute
                            : l10n.castMute,
                        onPressed: () => unawaited(
                          _command('mute', {'value': state['muted'] != true}),
                        ),
                        icon: Icon(
                          state['muted'] == true
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                        ),
                      ),
                      SizedBox(
                        width: volumeWidth,
                        child: Semantics(
                          label: l10n.castVolume,
                          child: Slider(
                            semanticFormatterCallback: (value) =>
                                '${(value * 100).round()}%',
                            value: _volumePreview ?? volume,
                            onChangeStart: (_) {
                              _draggingVolume = true;
                              _activity();
                            },
                            onChanged: _changeVolume,
                            onChangeEnd: (_) => _finishVolumeChange(),
                          ),
                        ),
                      ),
                      if (constraints.maxWidth >= 650)
                        SizedBox(
                          width: 38,
                          child: Text(
                            '${((_volumePreview ?? volume) * 100).round()}%',
                            style: numbers,
                            textAlign: TextAlign.right,
                          ),
                        ),
                      const SizedBox(width: 12),
                      IconButton(
                        tooltip: _fullscreen
                            ? l10n.castExitFullscreen
                            : l10n.castFullscreen,
                        onPressed: _toggleFullscreen,
                        icon: Icon(
                          _fullscreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
