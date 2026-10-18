import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'window_input_event.dart';
import 'window_stream_models.dart';

/// A device whose apps or windows can be streamed to this machine.
///
/// Implementations: the Android agent, the stock scrcpy-server fallback and,
/// later, desktop capture sources. Media never flows through this interface;
/// a stream only describes where the stream isolate finds it
/// ([StreamHandle.transport]).
abstract interface class WindowSource {
  SourceInfo get info;
  ValueListenable<SourceState> get state;

  Future<List<AppEntry>> apps({bool refresh = false});

  /// Running and recent tasks, newest first. Empty when unsupported.
  Future<List<TaskEntry>> tasks();

  Future<Uint8List?> icon(String appId);
  Future<Uint8List?> snapshot(TaskEntry task);

  Future<StreamHandle> open(OpenTarget target, StreamOptions options);

  Future<void> dispose();
}

/// A source whose windows or tasks can be closed from here, as if closed on
/// the device itself (a window's close button, swiping a task away).
abstract interface class ClosesTasks {
  Future<bool> closeTask(TaskEntry task);
}

/// How closing a window from here went.
enum TaskCloseOutcome {
  /// The window is gone on its device.
  closed,

  /// The window is still there, most likely asking whether to save.
  stillOpen,

  /// The request did not reach the device.
  failed,
}

/// A source whose device says how closing a window went, rather than only
/// that it was asked.
abstract interface class ConfirmsTaskClose {
  Future<TaskCloseOutcome> closeTaskAndWait(TaskEntry task);
}

/// One streamed window's session with its source.
abstract interface class StreamHandle {
  String get id;
  WindowSource get source;
  OpenTarget get target;
  String get title;
  ValueListenable<StreamState> get state;

  /// Where the stream isolate reads video and audio and writes input.
  StreamTransportSpec get transport;

  /// Called by the coordinator once the stream isolate reports the session
  /// details (video size, display id).
  void onTransportEvent(StreamTransportEvent event);

  void sendInput(WindowInputEvent event);
  void requestKeyframe();
  void setQuality(QualityTier tier);
  Future<void> setViewport({required int width, required int height});
  Future<void> suspend();
  Future<void> resume();
  Future<void> close({CloseMode mode = CloseMode.returnToSource});
}

/// Sendable description of a stream's media endpoints. The stream isolate
/// picks the reader for each concrete type.
sealed class StreamTransportSpec {
  const StreamTransportSpec();
}

/// scrcpy media and control sockets through an adb forward: the video, audio
/// and control sockets are opened in that order on the same local port.
///
/// Stock scrcpy-server serves one stream per port. whisper-agent serves all
/// of a phone's streams on one port; each socket then starts with a hello
/// naming [agentStream] and proving [agentToken].
class ScrcpySocketsSpec extends StreamTransportSpec {
  const ScrcpySocketsSpec({
    required this.port,
    required this.audio,
    this.host = '127.0.0.1',
    this.agentToken,
    this.agentStream = 0,
  });

  final String host;
  final int port;
  final bool audio;
  final Uint8List? agentToken;
  final int agentStream;
}

/// A desktop's window over Whisper's own `/window` media route. The keys are
/// copies made for the stream isolate and wiped once the connection is set up.
class WhisperWindowSpec extends StreamTransportSpec {
  WhisperWindowSpec({
    required this.uri,
    required this.sessionId,
    required this.viewerPeerId,
    required Uint8List sendKey,
    required Uint8List receiveKey,
  }) : sendKey = Uint8List.fromList(sendKey),
       receiveKey = Uint8List.fromList(receiveKey);

  static const String route = '/window';
  static const String namespace = 'window-stream';

  final Uri uri;
  final String sessionId;
  final String viewerPeerId;

  /// This device's media send key for the host (upgrade proof and input).
  final Uint8List sendKey;

  /// This device's media receive key for the host (video).
  final Uint8List receiveKey;

  void destroyKeys() {
    sendKey.fillRange(0, sendKey.length, 0);
    receiveKey.fillRange(0, receiveKey.length, 0);
  }
}

/// Events the stream isolate reports about a stream's transport.
sealed class StreamTransportEvent {
  const StreamTransportEvent();
}

class TransportConnected extends StreamTransportEvent {
  const TransportConnected();
}

class TransportVideoSize extends StreamTransportEvent {
  const TransportVideoSize(this.width, this.height);

  final int width;
  final int height;
}

class TransportAudioState extends StreamTransportEvent {
  const TransportAudioState({required this.enabled});

  final bool enabled;
}

class TransportClipboard extends StreamTransportEvent {
  const TransportClipboard(this.text);

  final String text;
}

/// The window's keyboard focus moved into ([typing]) or out of somewhere
/// to type: a phone brings its keyboard up or puts it away.
class TransportTextFocus extends StreamTransportEvent {
  const TransportTextFocus({required this.typing});

  final bool typing;
}

class TransportEnded extends StreamTransportEvent {
  const TransportEnded({this.failure});

  final WindowStreamFailure? failure;
}

class TransportStats extends StreamTransportEvent {
  const TransportStats({
    required this.videoKbps,
    required this.audioKbps,
    required this.videoFps,
    required this.droppedBeforeDecode,
    this.rttMs,
  });

  final double videoKbps;
  final double audioKbps;
  final double videoFps;
  final int droppedBeforeDecode;

  /// Round trip over the stream's own connection, where measured.
  final double? rttMs;
}
