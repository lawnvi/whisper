import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide TextInput;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../widget/island/island_center.dart';
import '../../window_stream/android/window_activity.dart';
import '../../window_stream/core/window_input_event.dart';
import '../../window_stream/core/window_stream_models.dart';
import '../../window_stream/window_stream_log.dart';
import '../../window_stream/pipeline/surface_backend.dart';
import '../../window_stream/pipeline/texture_surface.dart';
import '../../window_stream/remote/remote_peer_source.dart';
import '../../window_stream/window_stream_coordinator.dart';
import 'flow_space_theme.dart';
import 'viewer/viewer_chrome.dart';
import 'viewer/viewer_keyboard.dart';
import 'viewer/viewer_loading.dart';
import 'viewer/viewer_pointer_input.dart';
import 'viewer/viewer_settle.dart';

/// Shows one streamed window full screen on a phone or tablet (iPhone and
/// iPad; Android shows Mac windows in an activity of its own with the same
/// behaviour). Everything that points at the picture becomes the other
/// device's pointer ([ViewerPointerInput]); the keyboard, hardware or on
/// screen, types there ([HardwareKeyRouter], [ImeTextBuffer]). A floating
/// capsule holds the window controls and hides while the window is used.
///
/// Until the picture settles ([PictureSettle]: the other device resizes
/// the window for this screen first, so early frames come stretched) it
/// shows the window's last picture dimmed, with a spinner, and crossfades
/// to the live picture once it is stable.
///
/// While it shows: no status bar or home indicator, the screen stays on,
/// and on an iPhone the window keeps the orientation it was last turned to.
/// Leaving pauses the window and keeps its last picture for its card.
class FlowWindowViewerPage extends StatefulWidget {
  const FlowWindowViewerPage({
    super.key,
    required this.session,
    WindowStreamCoordinator? coordinator,
  }) : _coordinator = coordinator;

  final WindowStreamSession session;
  final WindowStreamCoordinator? _coordinator;

  @override
  State<FlowWindowViewerPage> createState() => _FlowWindowViewerPageState();
}

class _FlowWindowViewerPageState extends State<FlowWindowViewerPage>
    with TickerProviderStateMixin {
  late final WindowStreamCoordinator _coordinator =
      widget._coordinator ?? WindowStreamCoordinator.shared;
  late final AppLifecycleListener _lifecycle;
  late final ViewerPointerInput _input = ViewerPointerInput(
    send: _send,
    vsync: this,
    onLongPress: HapticFeedback.mediumImpact,
  );
  final _keys = HardwareKeyRouter();
  final _viewerFocus = FocusNode(debugLabel: 'window viewer');
  final _textFocus = FocusNode(debugLabel: 'window viewer text');
  final _text = TextEditingController.fromValue(ImeTextBuffer.empty);
  ValueListenable<SurfaceVisual>? _visual;

  bool _chromeVisible = true;
  Timer? _hideChrome;
  bool _scaleOpen = false;

  /// The person asked for the keyboard (its button).
  bool _userKeyboard = false;

  /// The keyboard came up because a text field took focus over there.
  bool _followsFocus = false;

  /// The system put the keyboard away (its own hide key): stays down
  /// until asked again.
  bool _keyboardDismissed = false;

  /// The text field should have focus (what [_syncTextField] last did).
  bool _textFieldWanted = false;
  String _composing = '';

  /// The keyboard's height over the screen's bottom, as last laid out.
  double _keyboardHeight = 0;

  Timer? _viewportDebounce;
  Size? _reportedViewport;
  Timer? _insetDebounce;
  double _reportedInset = 0;
  double _pendingInset = 0;

  /// Releases the island's quiet mode taken while the window fills the
  /// screen.
  VoidCallback? _unhushIsland;

  /// When the picture can be shown (see [PictureSettle]).
  final _clock = Stopwatch()..start();
  late final PictureSettle _settle = PictureSettle(now: () => _clock.elapsed);
  Timer? _settleTimer;
  StreamSubscription<TextureFrame>? _frames;
  StreamSubscription<TextureSurfaceEvent>? _decoderEvents;
  bool _watching = false;

  /// The decoder reports each frame; where it cannot (Android) its size
  /// reports stand in.
  bool _frameReports = true;
  ({int width, int height})? _sizeSeen;
  SurfaceVisual? _lastVisual;

  /// The source's own picture of the window, while there is none from here.
  Uint8List? _thumbnail;

  /// The app's icon, for the placeholder when there is no picture at all.
  Uint8List? _appIcon;

  /// iPhone: the window's orientation (null until known).
  bool? _landscape;
  bool _left = false;

  static const _insetDelay = Duration(milliseconds: 120);
  static const _viewportDelay = Duration(milliseconds: 250);
  static const _chromeDelay = Duration(milliseconds: 3500);

  /// The longest edge of the picture kept for the window's card.
  static const _snapshotEdge = 720;

  WindowStreamSession get _session => widget.session;

  RemoteStreamHandle? get _remote {
    final handle = _session.handle;
    return handle is RemoteStreamHandle ? handle : null;
  }

  bool get _live =>
      (_visual?.value ?? SurfaceVisual.live) == SurfaceVisual.live;

  /// Touches go to the window once its picture is live and settled (not
  /// at the stretched early frames).
  bool get _interactive => _live && _settle.stable;

  /// A hardware keyboard is attached, and taking the text field for it
  /// draws no software keyboard (so the input method composes its keys).
  bool get _hardwareKeyboard =>
      TextureStreamSurface.hardwareKeyboard.value == true &&
      !_hardwareKeyboardShowsKeys;

  /// The text field was taken for a hardware keyboard and the software
  /// keyboard came up anyway (the system counts no keyboard): hardware
  /// keys then go out without the input method, and nothing is fought.
  bool _hardwareKeyboardShowsKeys = false;

  /// Taller than the bar a hardware keyboard leaves: a software keyboard.
  static const _softwareKeyboardHeight = 120.0;

  /// An iPhone (not an iPad): orientation is this page's to choose.
  static bool get _phone {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return false;
    }
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) {
      return false;
    }
    final view = views.first;
    final shortest = (view.physicalSize / view.devicePixelRatio).shortestSide;
    return shortest > 0 && shortest < 600;
  }

  @override
  void initState() {
    super.initState();
    _session.handle.state.addListener(_onState);
    _visual = _coordinator.backend?.visualOf(_session.surface);
    _visual?.addListener(_onVisual);
    _remote?.textFocus.addListener(_onTextFocus);
    TextureStreamSurface.hardwareKeyboard.addListener(_onHardwareKeyboard);
    NativeWindowActivity.lastFrames.addListener(_onState);
    _text.addListener(_onTextChanged);
    _textFocus.addListener(_onTextFieldFocus);
    unawaited(TextureStreamSurface.refreshHardwareKeyboard());
    // Leaving the viewer pauses the window; coming back resumes it.
    if (_session.state.status == StreamStatus.suspended) {
      unawaited(_coordinator.resume(_session));
    }
    _lifecycle = AppLifecycleListener(
      onHide: () => _visibility(false),
      onShow: () => _visibility(true),
    );
    _enterSystemUi();
    _startSettle();
    _input.enabled = _interactive;
    _scheduleHideChrome();
    if (_remote?.textFocus.value == true) {
      _followsFocus = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterOpening());
  }

  /// The keyboard (when a text field over there already has focus) comes
  /// up once the page has finished growing in, not during it.
  void _afterOpening() {
    if (!mounted) {
      return;
    }
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) {
      _syncTextField();
      return;
    }
    void done(AnimationStatus status) {
      if (status.isCompleted) {
        animation.removeStatusListener(done);
        _syncTextField();
      }
    }

    animation.addStatusListener(done);
  }

  @override
  void dispose() {
    _leave();
    // Back to the space: the window stays in the dock, paused, so the
    // other device stops capturing until it is reopened or closed.
    if (_session.state.status == StreamStatus.live &&
        _session.source.info.capabilities.suspend) {
      unawaited(_coordinator.pause(_session));
    }
    _hideChrome?.cancel();
    _viewportDebounce?.cancel();
    _insetDebounce?.cancel();
    _settleTimer?.cancel();
    _keyboardAfterFade?.cancel();
    TextureStreamSurface.of(
      _session.surface,
    )?.hasAudio.removeListener(_onAudio);
    unawaited(_frames?.cancel());
    unawaited(_decoderEvents?.cancel());
    _lifecycle.dispose();
    _input.dispose();
    _session.handle.state.removeListener(_onState);
    _visual?.removeListener(_onVisual);
    _remote?.textFocus.removeListener(_onTextFocus);
    TextureStreamSurface.hardwareKeyboard.removeListener(_onHardwareKeyboard);
    NativeWindowActivity.lastFrames.removeListener(_onState);
    _text.removeListener(_onTextChanged);
    _textFocus.removeListener(_onTextFieldFocus);
    _viewerFocus.dispose();
    _textFocus.dispose();
    _text.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ system UI

  void _enterSystemUi() {
    // Immersive: the window gets the whole screen; a swipe from an edge
    // brings the bars back for a moment.
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    unawaited(WakelockPlus.enable().catchError((Object _) {}));
    // The island keeps to what needs the user while the window is shown.
    _unhushIsland = IslandCenter.shared.hush();
    if (_phone) {
      unawaited(_loadOrientation());
    }
  }

  /// Once, when the page goes (popped, or disposed): the system UI comes
  /// back, an iPhone turns upright again, the picture is kept for the card.
  void _leave() {
    if (_left) {
      return;
    }
    _left = true;
    _syncWatch();
    _releaseKeys();
    _input.reset();
    unawaited(_snapshot());
    // As the media preview leaves it: the app's usual edge-to-edge bars.
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    _unhushIsland?.call();
    _unhushIsland = null;
    if (_phone) {
      unawaited(
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
      );
    }
  }

  String get _orientationKey {
    final handle = _session.handle;
    final appId = handle is RemoteStreamHandle
        ? handle.window.appId
        : handle.target.appId;
    return 'window_stream.viewer.landscape.${_session.source.info.id}/$appId';
  }

  /// Each window opens the way it was last turned; one never turned opens
  /// the way windows were last turned (upright on a phone at first).
  Future<void> _loadOrientation() async {
    bool? saved;
    try {
      final prefs = await SharedPreferences.getInstance();
      saved = prefs.getBool(_orientationKey);
    } catch (_) {
      saved = null;
    }
    if (!mounted || _left) {
      return;
    }
    _applyOrientation(saved ?? RemoteViewport.landscape);
  }

  void _applyOrientation(bool landscape) {
    setState(() => _landscape = landscape);
    unawaited(
      SystemChrome.setPreferredOrientations(
        landscape
            ? const [
                DeviceOrientation.landscapeRight,
                DeviceOrientation.landscapeLeft,
              ]
            : const [DeviceOrientation.portraitUp],
      ),
    );
  }

  Future<void> _rotate() async {
    final landscape = !(_landscape ?? RemoteViewport.landscape);
    _applyOrientation(landscape);
    _flashChrome();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_orientationKey, landscape);
    } catch (_) {
      // Only the memory of it is lost.
    }
    // Windows never turned follow the last turn.
    await RemoteViewport.setLandscape(landscape);
  }

  // ------------------------------------------------------------ state

  void _onState() {
    if (!mounted) {
      return;
    }
    if (_session.state.status == StreamStatus.closed &&
        _session.state.failure == null) {
      Navigator.of(context).maybePop();
      return;
    }
    _forwardSize();
    setState(() {});
  }

  void _onVisual() {
    if (!mounted) {
      return;
    }
    final visual = _visual?.value ?? SurfaceVisual.live;
    final was = _lastVisual;
    _lastVisual = visual;
    final live = _live;
    if (!live) {
      // Paused or reconnecting: nothing in progress may stay held.
      _input.reset();
      _releaseKeys();
    } else if (was != null &&
        was != SurfaceVisual.live &&
        was != SurfaceVisual.connecting) {
      // Playing again (not the first time it went live): the spinner
      // returns only if no frame comes soon.
      _settle.resumed();
      _afterSettleEvent();
    }
    _input.enabled = _interactive;
    // The keyboard goes while the window is paused or gone and comes back
    // with the picture (not for a moment's reconnect).
    _syncTextField();
  }

  void _visibility(bool visible) {
    if (visible) {
      _settle.resumed();
      _afterSettleEvent();
    } else {
      // Into the background: the picture as it looks now, for the card.
      unawaited(_snapshot());
      _input.reset();
      _releaseKeys();
    }
    final backend = _coordinator.backend;
    if (backend is TextureSurfaceBackend) {
      backend.visibilityChanged(_session.surface, visible: visible);
    }
  }

  Future<void> _snapshot() async {
    final handle = _remote;
    final surface = TextureStreamSurface.of(_session.surface);
    if (handle == null || surface == null || !_session.firstFrameShown) {
      return;
    }
    final key = NativeWindowActivity.frameKey(
      _session.source.info.id,
      handle.window.id,
    );
    final jpeg = await surface.snapshot(maxEdge: _snapshotEdge);
    if (jpeg == null || jpeg.isEmpty) {
      return;
    }
    NativeWindowActivity.lastFrames.value = {
      ...NativeWindowActivity.lastFrames.value,
      key: jpeg,
    };
  }

  // ------------------------------------------------------------ settle

  void _startSettle() {
    final texture = TextureStreamSurface.of(_session.surface);
    _frames = texture?.frames.listen((frame) {
      // The frame already on screen helps a first open settle; after a
      // resume only a new one counts.
      if (!frame.replay || !_settle.stable) {
        _onFrame(frame.width, frame.height);
      }
    });
    _decoderEvents = texture?.events.listen((event) {
      if (event is TextureVideoSize && !_frameReports) {
        _onFrame(event.width, event.height);
      }
    });
    if (_session.firstFrameShown) {
      // Opened again from its card: it settled before; the last picture is
      // still in the texture.
      _settle.alreadySettled();
      _settle.resumed();
    }
    _lastVisual = _visual?.value;
    _starting = true;
    _forwardSize();
    _afterSettleEvent();
    _starting = false;
    unawaited(_loadThumbnail());
    unawaited(_loadIcon());
    // The window's sound: a mute button once it plays; muted stays muted.
    texture?.hasAudio.addListener(_onAudio);
    if (_session.muted) {
      unawaited(texture?.setAudioMuted(true));
    }
  }

  void _onAudio() {
    if (mounted && !_left) {
      setState(() {});
    }
  }

  bool get _hasAudio =>
      TextureStreamSurface.of(_session.surface)?.hasAudio.value ?? false;

  void _toggleMute() {
    final muted = !_session.muted;
    _session.muted = muted;
    unawaited(TextureStreamSurface.of(_session.surface)?.setAudioMuted(muted));
    setState(() {});
    _flashChrome();
  }

  Future<void> _loadIcon() async {
    if (_settle.stable) {
      return;
    }
    try {
      final png = await _session.source
          .icon(_session.handle.target.appId)
          .timeout(const Duration(seconds: 3));
      if (png != null && mounted && !_settle.stable) {
        setState(() => _appIcon = png);
      }
    } catch (_) {
      // The spinner alone.
    }
  }

  /// In initState: the first build is coming anyway.
  bool _starting = false;

  /// The source's SIZE message, as the stream's state carries it.
  void _forwardSize() {
    final state = _session.state;
    final width = state.videoWidth;
    final height = state.videoHeight;
    if (width == null || height == null) {
      return;
    }
    final size = (width: width, height: height);
    if (size == _sizeSeen) {
      return;
    }
    _sizeSeen = size;
    _settle.sizeMessage(width, height);
    _afterSettleEvent();
  }

  void _onFrame(int width, int height) {
    _settle.frame(width, height);
    _afterSettleEvent();
  }

  void _afterSettleEvent() {
    final wasStable = _shownStable;
    _shownStable = _settle.stable;
    if (!wasStable && _shownStable) {
      if (!_starting) {
        // A keyboard coming up costs frames: let the crossfade finish first.
        _keyboardAfterFade?.cancel();
        _keyboardAfterFade = Timer(
          viewerCrossfade + const Duration(milliseconds: 60),
          _syncTextField,
        );
      }
      WindowStreamLog.write(
        '${DateTime.now().toIso8601String().substring(11, 23)} viewer '
        '${_session.id.substring(0, 8)} picture stable after '
        '${_clock.elapsed.inMilliseconds} ms'
        '${_settle.settledByCap ? ' (cap)' : ''}: ${_settle.describe()}',
      );
    }
    _input.enabled = _interactive;
    _syncWatch();
    _settleTimer?.cancel();
    final next = _settle.nextCheck();
    if (next != null) {
      _settleTimer = Timer(next, () {
        _settle.check();
        _afterSettleEvent();
      });
    }
    if (mounted && !_left && !_starting) {
      setState(() {});
    }
  }

  bool _shownStable = false;
  Timer? _keyboardAfterFade;

  /// Frame reports from the decoder only while they matter.
  void _syncWatch() {
    final want = _settle.watching && !_left;
    if (want == _watching) {
      return;
    }
    _watching = want;
    final texture = TextureStreamSurface.of(_session.surface);
    if (texture == null) {
      _frameReports = false;
      return;
    }
    unawaited(
      texture.watchFrames(want).then((ok) {
        if (!ok) {
          _frameReports = false;
        }
      }),
    );
  }

  /// The source's thumbnail of the window, for the placeholder when this
  /// device never showed it.
  Future<void> _loadThumbnail() async {
    final handle = _remote;
    if (handle == null ||
        handle.window.id == 0 ||
        _placeholder != null ||
        _settle.stable) {
      return;
    }
    try {
      final bytes = await handle.source
          .snapshot(
            TaskEntry(
              id: handle.window.id,
              appId: handle.window.appId,
              label: handle.title,
            ),
          )
          .timeout(const Duration(seconds: 3));
      if (bytes != null && mounted && !_settle.stable) {
        setState(() => _thumbnail = bytes);
      }
    } catch (_) {
      // The placeholder stays plain.
    }
  }

  /// The picture this window last showed here, while there is no live one.
  Uint8List? get _placeholder {
    final handle = _remote;
    if (handle == null) {
      return null;
    }
    return NativeWindowActivity.lastFrames.value[NativeWindowActivity.frameKey(
      _session.source.info.id,
      handle.window.id,
    )];
  }

  // ------------------------------------------------------------ chrome

  void _scheduleHideChrome() {
    _hideChrome?.cancel();
    _hideChrome = Timer(_chromeDelay, () {
      if (mounted && !_keyboardOnScreen && !_scaleOpen) {
        setState(() => _chromeVisible = false);
      }
    });
  }

  void _flashChrome() {
    if (!_chromeVisible) {
      setState(() => _chromeVisible = true);
    }
    _scheduleHideChrome();
  }

  void _setTextScale(double scale) {
    final handle = _remote;
    if (handle != null && scale != RemoteViewport.scale) {
      unawaited(handle.setTextScale(scale));
      setState(() {});
    }
    _scheduleHideChrome();
  }

  // ------------------------------------------------------------ viewport

  /// A Mac window is sized for this screen: tell the Mac when the usable
  /// area changes (rotation), a moment after it settles. The keyboard does
  /// not resize it; it is reported as an inset instead.
  void _reportViewport(Size size) {
    final handle = _remote;
    if (handle == null || size.isEmpty || size == _reportedViewport) {
      return;
    }
    _reportedViewport = size;
    _viewportDebounce?.cancel();
    _viewportDebounce = Timer(_viewportDelay, () {
      unawaited(
        handle.setViewport(
          width: size.width.round(),
          height: size.height.round(),
        ),
      );
    });
  }

  /// The keyboard covers the bottom of the picture: the window over there
  /// stops above it, as an app here would (its text field just over the
  /// keys).
  void _reportInset(double covered) {
    final handle = _remote;
    if (handle == null) {
      return;
    }
    _pendingInset = covered;
    if ((covered - _reportedInset).abs() < 0.01) {
      _insetDebounce?.cancel();
      return;
    }
    _insetDebounce?.cancel();
    _insetDebounce = Timer(_insetDelay, () {
      _reportedInset = _pendingInset;
      unawaited(handle.setKeyboardInset(_pendingInset));
    });
  }

  static Rect _fit(Size video, Size area) {
    if (video.isEmpty || area.isEmpty) {
      return Rect.zero;
    }
    final scale = math.min(
      area.width / video.width,
      area.height / video.height,
    );
    return Rect.fromCenter(
      center: area.center(Offset.zero),
      width: video.width * scale,
      height: video.height * scale,
    );
  }

  // ------------------------------------------------------------ input

  void _send(WindowInputEvent event) => _coordinator.input(_session.id, event);

  void _releaseKeys() {
    for (final event in _keys.releaseAll()) {
      _send(event);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final events = _keys.route(
      event,
      modifiers: HardwareKeyRouter.modifiersOf(HardwareKeyboard.instance),
      textField: _textFocus.hasFocus,
      composing: _composing.isNotEmpty,
    );
    if (events == null) {
      return KeyEventResult.ignored;
    }
    if (_live) {
      events.forEach(_send);
    }
    return KeyEventResult.handled;
  }

  void _onViewerFocus(bool focused) {
    if (!focused) {
      // Keys held when focus left would never come up over there.
      _releaseKeys();
    }
  }

  // ------------------------------------------------------------ keyboard

  bool get _keyboardOnScreen => _textFocus.hasFocus && _keyboardHeight > 0;

  /// The keyboard comes up by itself (for a text field over there, or for
  /// a hardware keyboard's input method) once the picture has settled, not
  /// over the spinner; asked for by hand, at once.
  bool get _wantsTextField =>
      _typingVisual &&
      !_keyboardDismissed &&
      (_userKeyboard ||
          (_settle.stable && (_followsFocus || _hardwareKeyboard)));

  /// Typing makes sense now or in a moment: live, or (re)connecting.
  bool get _typingVisual => switch (_visual?.value ?? SurfaceVisual.live) {
    SurfaceVisual.live || SurfaceVisual.reconnecting => true,
    _ => false,
  };

  /// Gives the hidden text field focus (the keyboard comes up, or with a
  /// hardware keyboard the input method takes its keys) or takes it away.
  void _syncTextField() {
    if (!mounted || _left) {
      return;
    }
    final want = _wantsTextField;
    _textFieldWanted = want;
    if (want && !_textFocus.hasFocus) {
      _text.value = ImeTextBuffer.empty;
      _textFocus.requestFocus();
    } else if (!want && _textFocus.hasFocus) {
      _viewerFocus.requestFocus();
    }
    setState(() {});
  }

  void _onTextFieldFocus() {
    if (_textFocus.hasFocus) {
      // Once the field's own undo history has claimed the system's undo
      // (the iPad keyboard's undo and redo keys, shake to undo), nothing
      // here may be undone: the field only ever holds what was already
      // sent, and undoing would send it again.
      scheduleMicrotask(() {
        if (_textFocus.hasFocus) {
          UndoManager.client = _NoUndo.instance;
          UndoManager.setUndoState(canUndo: false, canRedo: false);
        }
      });
    } else if (UndoManager.client == _NoUndo.instance) {
      UndoManager.client = null;
    }
    if (!_textFocus.hasFocus && _textFieldWanted && !_left) {
      // Not ours: the system put the keyboard away (its hide key).
      _keyboardDismissed = true;
      _userKeyboard = false;
      _followsFocus = false;
      _textFieldWanted = false;
      _composing = '';
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _toggleKeyboard() {
    _keyboardDismissed = false;
    if (_keyboardOnScreen || _userKeyboard) {
      _userKeyboard = false;
      _followsFocus = false;
    } else {
      _userKeyboard = true;
    }
    _syncTextField();
    _flashChrome();
  }

  /// The other device's keyboard focus moved into ([typing]) or out of
  /// somewhere to type: the keyboard follows, unless it was put away by
  /// hand meanwhile.
  void _onTextFocus() {
    final typing = _remote?.textFocus.value ?? false;
    if (typing && !_keyboardOnScreen) {
      _followsFocus = true;
      _keyboardDismissed = false;
    } else if (!typing && _followsFocus) {
      _followsFocus = false;
    }
    _syncTextField();
  }

  void _onHardwareKeyboard() {
    _keyboardDismissed = false;
    _hardwareKeyboardShowsKeys = false;
    _syncTextField();
  }

  void _onTextChanged() {
    final value = _text.value;
    final composing = ImeTextBuffer.composingOf(value);
    if (composing != _composing && mounted) {
      setState(() => _composing = composing);
    }
    final result = ImeTextBuffer.consume(value);
    if (_live) {
      result.events.forEach(_send);
    }
    if (result.reset) {
      _text.value = ImeTextBuffer.empty;
    }
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final media = MediaQuery.of(context);
    // View padding, not padding: the keyboard must not move the picture.
    final safe = media.viewPadding;
    final keyboard = media.viewInsets.bottom;
    if (keyboard != _keyboardHeight) {
      final wasShown = _keyboardHeight > 0;
      _keyboardHeight = keyboard;
      if (wasShown && keyboard == 0) {
        _scheduleHideChrome();
      }
      if (keyboard > _softwareKeyboardHeight &&
          _hardwareKeyboard &&
          !_userKeyboard &&
          !_followsFocus) {
        _hardwareKeyboardShowsKeys = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _syncTextField());
      }
    }
    final keyboardShown = keyboard > 0 && _textFocus.hasFocus;
    final visual = _visual?.value ?? SurfaceVisual.live;
    final placeholder = _placeholder ?? _thumbnail;
    final video = Size(
      (_session.state.videoWidth ?? 16).toDouble(),
      (_session.state.videoHeight ?? 10).toDouble(),
    );
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _leave();
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Colors.black,
          resizeToAvoidBottomInset: false,
          body: Focus(
            focusNode: _viewerFocus,
            autofocus: true,
            onKeyEvent: _onKey,
            onFocusChange: _onViewerFocus,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Padding(
                  padding: safe,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final area = constraints.biggest;
                      final picture = _fit(video, area);
                      _input.picture = picture;
                      _reportViewport(area);
                      // How much of the picture the keyboard covers.
                      final visibleBottom =
                          media.size.height - keyboard - safe.top;
                      final covered = keyboardShown && picture.height > 0
                          ? ((picture.bottom - visibleBottom) / picture.height)
                                .clamp(0.0, 0.8)
                          : 0.0;
                      _reportInset(covered);
                      return _buildPicture(picture, placeholder, visual, l10n);
                    },
                  ),
                ),
                _buildOverlay(visual, l10n),
                _buildTextInput(safe),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: math.max(safe.bottom, keyboard),
                  child: Center(
                    child: ViewerGrabber(
                      visible: !_chromeVisible,
                      onShow: _flashChrome,
                    ),
                  ),
                ),
                _buildChrome(l10n, math.max(safe.bottom, keyboard)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPicture(
    Rect picture,
    Uint8List? placeholder,
    SurfaceVisual visual,
    AppLocalizations l10n,
  ) {
    final stable = _settle.stable;
    // Played again but the first new frame is late: a dim and the spinner
    // over the last picture.
    final resumeStall = stable && _settle.loading;
    // The loading stage owns these states; the others have their overlay.
    final waiting =
        visual == SurfaceVisual.live || visual == SurfaceVisual.connecting;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _input.onPointerDown,
      onPointerMove: _input.onPointerMove,
      onPointerUp: _input.onPointerUp,
      onPointerCancel: _input.onPointerCancel,
      onPointerHover: _input.onPointerHover,
      onPointerSignal: _input.onPointerSignal,
      onPointerPanZoomStart: _input.onPointerPanZoomStart,
      onPointerPanZoomUpdate: _input.onPointerPanZoomUpdate,
      onPointerPanZoomEnd: _input.onPointerPanZoomEnd,
      child: Stack(
        children: [
          // Always drawn (an external texture under a fading opacity layer
          // does not draw on iOS); the loading stage covers it until the
          // picture settles, then fades away over it.
          Positioned.fromRect(
            rect: picture,
            child: Semantics(
              image: true,
              label: '${_session.handle.title} · ${_session.source.info.name}',
              child: Texture(
                textureId: _session.surface,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
          Positioned.fill(
            child: ViewerLoadingStage(
              visible: !stable || (resumeStall && waiting),
              // Fading out, it keeps what it showed.
              image: resumeStall ? null : placeholder,
              icon: resumeStall ? null : _appIcon,
              dimOnly: resumeStall,
              spinner: waiting,
              slowText: _settle.slow ? l10n.windowStreamConnecting : null,
            ),
          ),
        ],
      ),
    );
  }

  /// The hidden field that brings up the keyboard and the input method,
  /// and above it what the input method is composing. At the top: a
  /// landscape keyboard covers most of the bottom, and an iPad's floating
  /// candidates appear next to the field.
  Widget _buildTextInput(EdgeInsets safe) {
    return Positioned(
      top: safe.top + 12,
      left: 0,
      right: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IgnorePointer(child: ViewerComposingChip(text: _composing)),
          SizedBox(
            width: 2,
            height: 2,
            child: Opacity(
              opacity: 0,
              child: TextField(
                focusNode: _textFocus,
                controller: _text,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                maxLines: null,
                keyboardAppearance: Brightness.dark,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                textCapitalization: TextCapitalization.none,
                spellCheckConfiguration:
                    const SpellCheckConfiguration.disabled(),
                stylusHandwritingEnabled: false,
                enableInteractiveSelection: false,
                showCursor: false,
                // A click on the picture must not take the keyboard away.
                onTapOutside: (_) {},
                style: const TextStyle(fontSize: 1, color: Colors.transparent),
                decoration: const InputDecoration.collapsed(hintText: null),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverlay(SurfaceVisual value, AppLocalizations l10n) {
    final (text, busy, action) = switch (value) {
      SurfaceVisual.live => ('', false, false),
      // The loading stage shows connecting (a spinner, words only late).
      SurfaceVisual.connecting => ('', false, false),
      SurfaceVisual.reconnecting => (
        l10n.windowStreamReconnecting,
        true,
        false,
      ),
      SurfaceVisual.paused => (l10n.windowStreamPaused, false, true),
      SurfaceVisual.displaced => (l10n.windowStreamDisplaced, false, true),
      SurfaceVisual.secure => (l10n.windowStreamSecureBlocked, false, false),
      SurfaceVisual.exited => (l10n.windowStreamAppExited, false, false),
      SurfaceVisual.error => (l10n.windowStreamDisconnected, false, false),
    };
    final live =
        value == SurfaceVisual.live || value == SurfaceVisual.connecting;
    return IgnorePointer(
      ignoring: live,
      child: AnimatedOpacity(
        duration: FlowSpaceTokens.quickDuration,
        opacity: live ? 0 : 1,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: action ? () => unawaited(_coordinator.resume(_session)) : null,
          child: FlowGlass(
            radius: 0,
            tint: Colors.black.withValues(alpha: 0.45),
            child: Center(
              child: Semantics(
                liveRegion: true,
                button: action,
                label: text,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy)
                      const CupertinoActivityIndicator(
                        color: Colors.white,
                        radius: 13,
                      ),
                    if (action)
                      const Icon(
                        CupertinoIcons.play_circle_fill,
                        color: Colors.white,
                        size: 52,
                      ),
                    const SizedBox(height: 12),
                    Text(
                      text,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChrome(AppLocalizations l10n, double bottom) {
    final paused = _session.state.status == StreamStatus.suspended;
    final canPause = _session.source.info.capabilities.suspend;
    final reduceMotion = flowReduceMotion(context);
    final visible = _chromeVisible;
    final capsule = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: reduceMotion
              ? Duration.zero
              : FlowSpaceTokens.quickDuration,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SizeTransition(
              sizeFactor: animation,
              axisAlignment: 1,
              child: child,
            ),
          ),
          child: _scaleOpen && visible
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ViewerTextScaleRuler(
                    value: RemoteViewport.scale,
                    onChanged: _setTextScale,
                  ),
                )
              : const SizedBox.shrink(),
        ),
        Center(
          child: ViewerChromeCapsule(
            children: [
              ViewerChromeButton(
                icon: CupertinoIcons.square_grid_2x2,
                label: l10n.windowStreamBackToSpace,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              if (canPause)
                ViewerChromeButton(
                  icon: paused
                      ? CupertinoIcons.play_fill
                      : CupertinoIcons.pause_fill,
                  label: paused
                      ? l10n.windowStreamResume
                      : l10n.windowStreamPause,
                  onPressed: () {
                    unawaited(
                      paused
                          ? _coordinator.resume(_session)
                          : _coordinator.pause(_session),
                    );
                    _flashChrome();
                  },
                ),
              if (_hasAudio)
                ViewerChromeButton(
                  icon: _session.muted
                      ? CupertinoIcons.speaker_slash_fill
                      : CupertinoIcons.speaker_2_fill,
                  label: _session.muted ? l10n.castUnmute : l10n.castMute,
                  active: _session.muted,
                  onPressed: _toggleMute,
                ),
              if (_remote != null)
                ViewerChromeButton(
                  icon: CupertinoIcons.textformat_size,
                  label: l10n.windowStreamTextSize,
                  active: _scaleOpen,
                  onPressed: () {
                    setState(() => _scaleOpen = !_scaleOpen);
                    _flashChrome();
                  },
                ),
              ViewerChromeButton(
                icon: CupertinoIcons.keyboard,
                label: l10n.windowStreamKeyboard,
                onPressed: _toggleKeyboard,
                active: _keyboardOnScreen || _userKeyboard,
              ),
              if (_phone)
                ViewerChromeButton(
                  icon: CupertinoIcons.rotate_right,
                  label: l10n.windowStreamSwitcherRotate,
                  onPressed: () => unawaited(_rotate()),
                ),
              ViewerChromeButton(
                icon: CupertinoIcons.xmark,
                label: l10n.windowStreamClose,
                onPressed: () {
                  unawaited(_coordinator.close(_session));
                  Navigator.of(context).maybePop();
                },
              ),
            ],
          ),
        ),
      ],
    );
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottom + 14,
      child: IgnorePointer(
        ignoring: !visible,
        child: reduceMotion
            ? AnimatedOpacity(
                duration: FlowSpaceTokens.quickDuration,
                opacity: visible ? 1 : 0,
                child: capsule,
              )
            : AnimatedSlide(
                duration: FlowSpaceTokens.springDuration,
                curve: const SpringCurve(),
                offset: visible ? Offset.zero : const Offset(0, 1.6),
                child: AnimatedOpacity(
                  duration: FlowSpaceTokens.quickDuration,
                  opacity: visible ? 1 : 0,
                  child: capsule,
                ),
              ),
      ),
    );
  }
}

/// Takes the system's undo and redo while the hidden text field has focus,
/// and does nothing with them.
class _NoUndo implements UndoManagerClient {
  const _NoUndo();

  static const instance = _NoUndo();

  @override
  void handlePlatformUndo(UndoDirection direction) {}

  @override
  void undo() {}

  @override
  void redo() {}

  @override
  bool get canUndo => false;

  @override
  bool get canRedo => false;
}
