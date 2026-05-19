import 'package:flutter/foundation.dart';

typedef AudioShareDiagnosticsSink = void Function(String message);

class AudioShareDiagnostics {
  AudioShareDiagnostics({
    AudioShareDiagnosticsSink? sink,
  }) : _sink = sink ?? debugPrint;

  static final AudioShareDiagnostics shared = AudioShareDiagnostics();
  static const bool traceEnabled = bool.fromEnvironment('WHISPER_AUDIO_TRACE');

  final AudioShareDiagnosticsSink _sink;

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

  void transportConnecting(Uri uri) {
    _emit('audio transport connecting uri=$uri');
  }

  void transportConnected(Uri uri) {
    _emit('audio transport connected uri=$uri');
  }

  void transportConnectFailed(Uri uri, Object error) {
    _emit('audio transport connect failed uri=$uri error=$error');
  }

  void audioPacketSent({
    required String sessionId,
    required int sequence,
    required int payloadBytes,
  }) {
    _sentAudioPacketCount++;
    _emitSampled(
      'audio packet sent session=$sessionId seq=$sequence '
      'payload=$payloadBytes count=$_sentAudioPacketCount',
      _sentAudioPacketCount,
    );
  }

  void audioPacketSendDropped({
    required String sessionId,
    required int sequence,
    required String reason,
  }) {
    _droppedSendCount++;
    _emitSampled(
      'audio packet send dropped session=$sessionId seq=$sequence '
      'reason=$reason count=$_droppedSendCount',
      _droppedSendCount,
    );
  }

  void captureStarted({
    required String sessionId,
    required int sampleRate,
    required int channels,
  }) {
    _emit(
      'audio capture started session=$sessionId sampleRate=$sampleRate '
      'channels=$channels',
    );
  }

  void captureFrame({
    required String sessionId,
    required int nativeSequence,
    required int samples,
    required int sampleRate,
    required int channels,
  }) {
    _captureFrameCount++;
    _emitSampled(
      'audio capture frame session=$sessionId nativeSeq=$nativeSequence '
      'samples=$samples sampleRate=$sampleRate channels=$channels '
      'count=$_captureFrameCount',
      _captureFrameCount,
    );
  }

  void capturePacket({
    required String sessionId,
    required int sequence,
    required int payloadBytes,
  }) {
    _capturePacketCount++;
    _emitSampled(
      'audio capture packet session=$sessionId seq=$sequence '
      'payload=$payloadBytes count=$_capturePacketCount',
      _capturePacketCount,
    );
  }

  void audioChannelAttached() {
    _attachedChannelCount++;
    _emit('audio websocket attached count=$_attachedChannelCount');
  }

  void audioChannelClosed() {
    _emit('audio websocket closed');
  }

  void audioChannelError(Object error) {
    _emit('audio websocket error=$error');
  }

  void audioChannelMessageBytes(int bytes) {
    _channelMessageCount++;
    _emitSampled(
      'audio websocket message bytes=$bytes count=$_channelMessageCount',
      _channelMessageCount,
    );
  }

  void audioPacketDelivered({
    required String sessionId,
    required int sequence,
    required int payloadBytes,
  }) {
    _deliveredAudioPacketCount++;
    _emitSampled(
      'audio packet delivered session=$sessionId seq=$sequence '
      'payload=$payloadBytes count=$_deliveredAudioPacketCount',
      _deliveredAudioPacketCount,
    );
  }

  void audioPacketDropped({
    required String sessionId,
    required int sequence,
    required int payloadBytes,
    required String state,
  }) {
    _droppedAudioPacketCount++;
    _emitSampled(
      'audio packet dropped session=$sessionId seq=$sequence '
      'payload=$payloadBytes state=$state count=$_droppedAudioPacketCount',
      _droppedAudioPacketCount,
    );
  }

  void groupPacketDelivered({
    required String groupId,
    required String streamId,
    required int sequence,
    required int payloadBytes,
  }) {
    _deliveredGroupPacketCount++;
    _emitSampled(
      'audio group packet delivered group=$groupId stream=$streamId '
      'seq=$sequence payload=$payloadBytes count=$_deliveredGroupPacketCount',
      _deliveredGroupPacketCount,
    );
  }

  void packetDecodeFailed({
    required int bytes,
    required Object legacyError,
    required Object groupError,
  }) {
    _decodeFailureCount++;
    _emitSampled(
      'audio packet decode failed bytes=$bytes legacy=$legacyError '
      'group=$groupError count=$_decodeFailureCount',
      _decodeFailureCount,
    );
  }

  void _emitSampled(String message, int count) {
    if (count <= 3 || count % 100 == 0) {
      _emit(message);
    }
  }

  void _emit(String message) {
    if (!kDebugMode && !traceEnabled) {
      return;
    }
    _sink('[WhisperAudio] $message');
  }
}
