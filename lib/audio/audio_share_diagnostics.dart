import 'package:flutter/foundation.dart';
import 'package:whisper/audio/audio_failure_reason.dart';
import 'package:whisper/helper/privacy_log.dart';

typedef AudioShareDiagnosticsSink = PrivacyLogSink;

enum AudioDiagnosticKind {
  transportConnecting,
  transportConnected,
  transportConnectFailed,
  packetSent,
  packetSendDropped,
  captureStarted,
  captureFrame,
  capturePacket,
  channelAttached,
  channelClosed,
  channelError,
  channelMessage,
  packetDelivered,
  packetDropped,
  groupPacketDelivered,
  decodeFailed,
}

enum AudioDiagnosticState {
  backpressure,
  closed,
  connected,
  connecting,
  failed,
  inactive,
  missing,
  transport,
  unknown,
}

class AudioShareDiagnostics {
  AudioShareDiagnostics({AudioShareDiagnosticsSink? sink})
    : _log = PrivacyLog(sink: sink);

  static final AudioShareDiagnostics shared = AudioShareDiagnostics();
  static const bool traceEnabled = bool.fromEnvironment('WHISPER_AUDIO_TRACE');

  final PrivacyLog _log;

  int _attachedChannelCount = 0;
  int _channelMessageCount = 0;
  int _deliveredAudioPacketCount = 0;
  int _droppedAudioPacketCount = 0;
  int _deliveredGroupPacketCount = 0;
  int _decodeFailureCount = 0;
  int _sentAudioPacketCount = 0;
  int _droppedSendCount = 0;
  int _captureFrameCount = 0;
  int _capturePacketCount = 0;

  bool get _enabled => kDebugMode || traceEnabled;

  void transportConnecting(Uri uri) {
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.transportConnecting,
      PrivacyField.route: _log.redactUri(uri),
    });
  }

  void transportConnected(Uri uri) {
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.transportConnected,
      PrivacyField.route: _log.redactUri(uri),
    });
  }

  void transportConnectFailed(Uri uri, Object error) {
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.transportConnectFailed,
      PrivacyField.route: _log.redactUri(uri),
      PrivacyField.errorType: _log.errorType(error),
    });
  }

  void audioPacketSent({
    required String sessionId,
    required int sequence,
    required int payloadBytes,
  }) {
    _sentAudioPacketCount++;
    if (!_shouldEmitSample(_sentAudioPacketCount)) {
      return;
    }
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.packetSent,
      PrivacyField.sequence: sequence,
      PrivacyField.bytes: payloadBytes,
      PrivacyField.count: _sentAudioPacketCount,
    });
  }

  void audioPacketSendDropped({
    required String sessionId,
    required int sequence,
    required String reason,
  }) {
    _droppedSendCount++;
    if (!_shouldEmitSample(_droppedSendCount)) {
      return;
    }
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.packetSendDropped,
      PrivacyField.sequence: sequence,
      PrivacyField.state: _safeState(reason),
      PrivacyField.count: _droppedSendCount,
    });
  }

  void captureStarted({
    required String sessionId,
    required int sampleRate,
    required int channels,
  }) {
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.captureStarted,
      PrivacyField.sampleRate: sampleRate,
      PrivacyField.channels: channels,
    });
  }

  void captureFrame({
    required String sessionId,
    required int nativeSequence,
    required int samples,
    required int sampleRate,
    required int channels,
  }) {
    _captureFrameCount++;
    if (!_shouldEmitSample(_captureFrameCount)) {
      return;
    }
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.captureFrame,
      PrivacyField.sequence: nativeSequence,
      PrivacyField.samples: samples,
      PrivacyField.sampleRate: sampleRate,
      PrivacyField.channels: channels,
      PrivacyField.count: _captureFrameCount,
    });
  }

  void capturePacket({
    required String sessionId,
    required int sequence,
    required int payloadBytes,
  }) {
    _capturePacketCount++;
    if (!_shouldEmitSample(_capturePacketCount)) {
      return;
    }
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.capturePacket,
      PrivacyField.sequence: sequence,
      PrivacyField.bytes: payloadBytes,
      PrivacyField.count: _capturePacketCount,
    });
  }

  void audioChannelAttached() {
    _attachedChannelCount++;
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.channelAttached,
      PrivacyField.count: _attachedChannelCount,
    });
  }

  void audioChannelClosed() {
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.channelClosed,
    });
  }

  void audioChannelError(Object error) {
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.channelError,
      PrivacyField.errorType: _log.errorType(error),
    });
  }

  void audioChannelMessageBytes(int bytes) {
    _channelMessageCount++;
    if (!_shouldEmitSample(_channelMessageCount)) {
      return;
    }
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.channelMessage,
      PrivacyField.bytes: bytes,
      PrivacyField.count: _channelMessageCount,
    });
  }

  void audioPacketDelivered({
    required String sessionId,
    required int sequence,
    required int payloadBytes,
  }) {
    _deliveredAudioPacketCount++;
    if (!_shouldEmitSample(_deliveredAudioPacketCount)) {
      return;
    }
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.packetDelivered,
      PrivacyField.sequence: sequence,
      PrivacyField.bytes: payloadBytes,
      PrivacyField.count: _deliveredAudioPacketCount,
    });
  }

  void audioPacketDropped({
    required String sessionId,
    required int sequence,
    required int payloadBytes,
    required String state,
  }) {
    _droppedAudioPacketCount++;
    if (!_shouldEmitSample(_droppedAudioPacketCount)) {
      return;
    }
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.packetDropped,
      PrivacyField.sequence: sequence,
      PrivacyField.bytes: payloadBytes,
      PrivacyField.state: _safeState(state),
      PrivacyField.count: _droppedAudioPacketCount,
    });
  }

  void groupPacketDelivered({
    required String groupId,
    required String streamId,
    required int sequence,
    required int payloadBytes,
  }) {
    _deliveredGroupPacketCount++;
    if (!_shouldEmitSample(_deliveredGroupPacketCount)) {
      return;
    }
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.groupPacketDelivered,
      PrivacyField.sequence: sequence,
      PrivacyField.bytes: payloadBytes,
      PrivacyField.count: _deliveredGroupPacketCount,
    });
  }

  void packetDecodeFailed({
    required int bytes,
    required Object legacyError,
    required Object groupError,
  }) {
    _decodeFailureCount++;
    if (!_shouldEmitSample(_decodeFailureCount)) {
      return;
    }
    _emit(<PrivacyField, Object>{
      PrivacyField.kind: AudioDiagnosticKind.decodeFailed,
      PrivacyField.bytes: bytes,
      PrivacyField.count: _decodeFailureCount,
      PrivacyField.reason: AudioFailureReason.protocol,
      PrivacyField.errorType: _log.errorType(legacyError),
    });
  }

  AudioDiagnosticState _safeState(String value) {
    return switch (value) {
      'backpressure' => AudioDiagnosticState.backpressure,
      'closed' => AudioDiagnosticState.closed,
      'connected' => AudioDiagnosticState.connected,
      'connecting' => AudioDiagnosticState.connecting,
      'failed' => AudioDiagnosticState.failed,
      'inactive' ||
      'idle' ||
      'offered' ||
      'stopped' => AudioDiagnosticState.inactive,
      'missing' => AudioDiagnosticState.missing,
      'transport' => AudioDiagnosticState.transport,
      _ => AudioDiagnosticState.unknown,
    };
  }

  bool _shouldEmitSample(int count) =>
      _enabled && (count <= 3 || count % 100 == 0);

  void _emit(Map<PrivacyField, Object> fields) {
    if (!_enabled) {
      return;
    }
    _log.event(PrivacyEvent.audioDiagnostic, fields);
  }
}
