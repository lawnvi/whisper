import 'dart:typed_data';

/// Platform of a device that offers or shows streamed windows.
enum WindowStreamPlatform { android, macos, windows, linux, ios }

/// What a source can do. The UI and coordinator branch on these flags instead
/// of on the source's type, so new sources only declare what they support.
class SourceCapabilities {
  const SourceCapabilities({
    this.appIcons = false,
    this.recents = false,
    this.taskSnapshots = false,
    this.moveTask = false,
    this.detachesFromSourceScreen = false,
    this.suspend = false,
    this.perAppAudio = false,
    this.audio = false,
    this.uiTree = false,
    this.resizeReflow = false,
    this.unicodeText = false,
  });

  /// Installed apps come with icons.
  final bool appIcons;

  /// Running and recent tasks (Android) or open windows (desktop) are listed.
  final bool recents;
  final bool taskSnapshots;

  /// An already running task can be moved into a stream without restarting.
  final bool moveTask;

  /// Streaming takes the app off the source's own screen (Android virtual
  /// displays) instead of mirroring a window that stays where it is.
  final bool detachesFromSourceScreen;

  /// Video can be paused while the app keeps running.
  final bool suspend;

  /// Each stream carries only its own app's audio.
  final bool perAppAudio;
  final bool audio;
  final bool uiTree;

  /// The source can re-layout the app for a new window size.
  final bool resizeReflow;

  /// Text outside ASCII can be typed directly.
  final bool unicodeText;
}

/// Static description of a source device.
class SourceInfo {
  const SourceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.capabilities,
    this.model = '',
    this.osVersion = '',
  });

  /// Stable id used for settings and for matching a Whisper peer.
  final String id;
  final String name;
  final String model;
  final String osVersion;
  final WindowStreamPlatform platform;
  final SourceCapabilities capabilities;
}

enum SourceStatus { connecting, ready, unavailable, failed }

class SourceState {
  const SourceState(this.status, {this.failure});

  final SourceStatus status;
  final WindowStreamFailure? failure;

  static const connecting = SourceState(SourceStatus.connecting);
  static const ready = SourceState(SourceStatus.ready);
}

/// An installed app (Android) or a running application (desktop).
class AppEntry {
  const AppEntry({
    required this.id,
    required this.label,
    this.system = false,
    this.running = false,
  });

  /// Package name on Android, bundle id or executable path on desktop.
  final String id;
  final String label;
  final bool system;
  final bool running;
}

/// A running or recent task (Android) or an open window (desktop).
class TaskEntry {
  const TaskEntry({
    required this.id,
    required this.appId,
    required this.label,
    this.displayId,
    this.visible = false,
    this.streamed = false,
    this.running = true,
    this.shownOn,
  });

  final int id;
  final String appId;
  final String label;
  final int? displayId;
  final bool visible;

  /// The task still has a live activity; recents restored after a reboot or
  /// a killed process do not, and reopen by starting the app.
  final bool running;

  /// Already shown in a streamed window on this desktop.
  final bool streamed;

  /// The name of another device showing it right now; opening it here
  /// moves it here.
  final String? shownOn;
}

/// What to open.
sealed class OpenTarget {
  const OpenTarget();

  String get appId;
}

class OpenApp extends OpenTarget {
  const OpenApp(this.appId, {this.label});

  @override
  final String appId;
  final String? label;
}

class OpenTask extends OpenTarget {
  const OpenTask(this.task);

  final TaskEntry task;

  @override
  String get appId => task.appId;
}

enum QualityTier { focused, background, minimal }

/// How much picture a streamed window gets, as its viewer chose: the
/// device sending it spends [bitRateScale] times its usual bit rate (text
/// stays sharp at the higher ones, a weak network keeps up at the lower).
enum WindowStreamQuality {
  smooth(0.5),
  standard(1),
  high(2),
  best(3.5);

  const WindowStreamQuality(this.bitRateScale);

  final double bitRateScale;

  /// What a viewer starts with.
  static const fallback = WindowStreamQuality.high;

  /// From the wire or settings; anything unknown is [fallback].
  static WindowStreamQuality fromName(Object? name) => values.firstWhere(
    (quality) => quality.name == name,
    orElse: () => fallback,
  );

  /// [bitRate] (the usual one) at this quality.
  int scale(int bitRate) => (bitRate * bitRateScale).round();
}

class StreamOptions {
  const StreamOptions({
    this.audio = true,
    this.maxFps = 60,
    this.videoBitRate = 8000000,
    this.displayWidth,
    this.displayHeight,
    this.displayDpi,
    this.quality = WindowStreamQuality.fallback,
  });

  final bool audio;
  final int maxFps;

  /// The usual bit rate; [quality] scales it.
  final int videoBitRate;
  final WindowStreamQuality quality;

  StreamOptions withQuality(WindowStreamQuality quality) => StreamOptions(
    audio: audio,
    maxFps: maxFps,
    videoBitRate: videoBitRate,
    displayWidth: displayWidth,
    displayHeight: displayHeight,
    displayDpi: displayDpi,
    quality: quality,
  );

  /// Virtual display size; null keeps the phone's own layout.
  final int? displayWidth;
  final int? displayHeight;
  final int? displayDpi;
}

enum CloseMode {
  /// Hand the app back to the source (Android: back to the phone's recents).
  returnToSource,

  /// Stop the app.
  terminate,
}

enum StreamStatus {
  opening,
  live,
  suspended,
  reconnecting,

  /// The source took the app back (e.g. opened again on the phone screen).
  displaced,

  /// The app protects its content; video is black.
  secureBlocked,
  appExited,
  closed,
}

class StreamState {
  const StreamState(
    this.status, {
    this.failure,
    this.videoWidth,
    this.videoHeight,
  });

  final StreamStatus status;
  final WindowStreamFailure? failure;
  final int? videoWidth;
  final int? videoHeight;

  bool get isTerminal => status == StreamStatus.closed;

  StreamState copyWith({
    StreamStatus? status,
    WindowStreamFailure? failure,
    int? videoWidth,
    int? videoHeight,
  }) {
    return StreamState(
      status ?? this.status,
      failure: failure ?? this.failure,
      videoWidth: videoWidth ?? this.videoWidth,
      videoHeight: videoHeight ?? this.videoHeight,
    );
  }
}

/// Why something failed. Each reason maps to a user-facing hint with a fix.
enum WindowStreamFailureReason {
  adbUnavailable,
  adbServerFailed,
  deviceUnauthorized,
  deviceOffline,
  deviceDisconnected,
  wirelessDebuggingOff,
  injectPermissionDenied,
  androidTooOld,
  audioUnsupported,
  serverStartFailed,
  connectionFailed,
  appNotFound,
  decoderFailed,
  nativeUnavailable,
  busyElsewhere,

  /// The source desktop is locked: macOS hands out no frames until unlock.
  sourceLocked,

  /// The source desktop has not allowed Whisper to record its screen.
  capturePermission,

  /// The phone's Whisper is not paired and trusted with this device.
  untrustedDevice,

  /// The phone has no (recent enough) Whisper to vouch for it.
  whisperMissing,

  /// The source desktop cannot share windows at all (Windows without
  /// Windows Graphics Capture, a capture backend that failed to load).
  hostUnsupported,

  /// Linux: Whisper's GNOME Shell helper is missing, disabled or not yet
  /// loaded; it starts working after logging out and in once.
  helperUnavailable,

  /// Linux: the session is not GNOME on Wayland (KDE, X11, …).
  desktopUnsupported,

  /// Windows: the window belongs to an app running as administrator, which
  /// Whisper (not elevated) may neither capture nor drive.
  elevatedWindow,

  /// The window keeps itself out of screen recordings (DRM video, password
  /// managers, WDA_EXCLUDEFROMCAPTURE).
  windowProtected,

  /// The source could not start encoding video.
  encoderFailed,

  /// An Android phone's window-flow service (its agent) is not running.
  agentNotRunning,

  /// The same window was opened on another device: a window is shown in
  /// one place at a time.
  movedAway,
  unknown,
}

/// The failure codes a window-stream native reports in the `flags` of
/// `WSN_CAPTURE_FAILED` (catalog, thumbnail, icon, launch and capture
/// requests alike), and what each means on the wire and to the user.
///
/// Codes 1–5 are in `window_stream_native.h`. 6–10 are agreed between the
/// natives and Dart for API version 1 (the header gains matching
/// `WSN_CAPTURE_ERROR_*` defines; no function changes):
///
/// | code | native constant                 | wire reason          | platforms |
/// |------|---------------------------------|----------------------|-----------|
/// | 1    | WSN_CAPTURE_ERROR_UNKNOWN       | `unavailable`        | all |
/// | 2    | WSN_CAPTURE_ERROR_UNSUPPORTED   | `unsupported`        | all: no capture backend (Windows < 10 1903 / WGC missing, macOS < 12.3) |
/// | 3    | WSN_CAPTURE_ERROR_PERMISSION    | `permission`         | macOS Screen Recording; Windows "Screen capture" privacy switch |
/// | 4    | WSN_CAPTURE_ERROR_NOT_FOUND     | `notFound`           | all: the window or app is gone |
/// | 5    | WSN_CAPTURE_ERROR_ENCODER       | `encoder`            | all: no H.264 encoder could be opened |
/// | 6    | WSN_CAPTURE_ERROR_HELPER        | `helper`             | Linux: GNOME Shell helper extension missing / disabled / needs re-login |
/// | 7    | WSN_CAPTURE_ERROR_DESKTOP       | `desktopUnsupported` | Linux: not a GNOME Wayland session |
/// | 8    | WSN_CAPTURE_ERROR_ELEVATED      | `elevated`           | Windows: the window's process is elevated (UIPI) |
/// | 9    | WSN_CAPTURE_ERROR_PROTECTED     | `protected`          | Windows display affinity, macOS sharingType none |
/// | 10   | WSN_CAPTURE_ERROR_LOCKED        | `locked`             | the desktop is locked or on the secure desktop |
///
/// A native whose `wsn_capture_supported()` returns 0 should still answer
/// `wsn_capture_request_catalog()` with `WSN_CAPTURE_FAILED` and the code
/// that explains why (6 or 7 on Linux, 2 elsewhere), so this device's own
/// UI can say what is missing.
abstract final class WindowStreamCaptureCode {
  static const int unknown = 1;
  static const int unsupported = 2;
  static const int permission = 3;
  static const int notFound = 4;
  static const int encoder = 5;
  static const int helper = 6;
  static const int desktop = 7;
  static const int elevated = 8;
  static const int protectedContent = 9;
  static const int locked = 10;

  /// The reason a host puts in `reject`, `error` and `stop` payloads.
  static String wireReason(int code) => switch (code) {
    unsupported => 'unsupported',
    permission => 'permission',
    notFound => 'notFound',
    encoder => 'encoder',
    helper => 'helper',
    desktop => 'desktopUnsupported',
    elevated => 'elevated',
    protectedContent => 'protected',
    locked => 'locked',
    _ => 'unavailable',
  };
}

/// What a viewer makes of a host's wire reason. Unknown reasons (newer
/// hosts) and `notFound` read as "could not open"; null means a normal end
/// that needs no explanation (the window closed, the viewer stopped).
WindowStreamFailureReason? windowStreamFailureForWire(
  Object? reason, {
  bool stopping = false,
}) {
  return switch (reason) {
    'locked' => WindowStreamFailureReason.sourceLocked,
    'permission' => WindowStreamFailureReason.capturePermission,
    'untrusted' => WindowStreamFailureReason.untrustedDevice,
    'unsupported' => WindowStreamFailureReason.hostUnsupported,
    'helper' => WindowStreamFailureReason.helperUnavailable,
    'desktopUnsupported' => WindowStreamFailureReason.desktopUnsupported,
    'elevated' => WindowStreamFailureReason.elevatedWindow,
    'protected' => WindowStreamFailureReason.windowProtected,
    'encoder' => WindowStreamFailureReason.encoderFailed,
    'agentNotRunning' => WindowStreamFailureReason.agentNotRunning,
    'movedAway' => WindowStreamFailureReason.movedAway,
    _ when stopping => null,
    _ => WindowStreamFailureReason.appNotFound,
  };
}

class WindowStreamFailure implements Exception {
  const WindowStreamFailure(this.reason, [this.detail]);

  final WindowStreamFailureReason reason;

  /// Diagnostic detail for logs; never shown verbatim.
  final String? detail;

  @override
  String toString() =>
      'WindowStreamFailure(${reason.name}${detail == null ? '' : ': $detail'})';
}

/// Icon or snapshot bytes with their encoding.
class ImageBytes {
  const ImageBytes(this.bytes, {this.mimeType = 'image/png'});

  final Uint8List bytes;
  final String mimeType;
}
