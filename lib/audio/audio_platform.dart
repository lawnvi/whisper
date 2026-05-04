import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:whisper/audio/audio_protocol.dart';

class AudioPlatform {
  AudioPlatform({
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(handleNativeMethodCall);
  }

  static const String channelName = 'com.vireen.whisper/audio_share';

  final MethodChannel _channel;
  final StreamController<PlatformPcmFrame> _captureFrames =
      StreamController<PlatformPcmFrame>.broadcast();
  final StreamController<PlatformAudioError> _captureErrors =
      StreamController<PlatformAudioError>.broadcast();

  Stream<PlatformPcmFrame> get captureFrames => _captureFrames.stream;
  Stream<PlatformAudioError> get captureErrors => _captureErrors.stream;

  Future<void> startPlayback({
    required String sessionId,
    required AudioStreamFormat format,
  }) {
    return _channel.invokeMethod<void>('startPlayback', <String, dynamic>{
      'sessionId': sessionId,
      'format': format.toJson(),
    });
  }

  Future<void> writePcm({
    required String sessionId,
    required Int16List pcm,
  }) {
    return _channel.invokeMethod<void>('writePcm', <String, dynamic>{
      'sessionId': sessionId,
      'pcm': _pcmBytes(pcm),
    });
  }

  Future<void> stopPlayback({
    required String sessionId,
  }) {
    return _channel.invokeMethod<void>('stopPlayback', <String, dynamic>{
      'sessionId': sessionId,
    });
  }

  Future<void> startCapture({
    required String sessionId,
    required AudioStreamFormat format,
  }) {
    return _channel.invokeMethod<void>('startCapture', <String, dynamic>{
      'sessionId': sessionId,
      'format': format.toJson(),
    });
  }

  Future<void> stopCapture({
    required String sessionId,
  }) {
    return _channel.invokeMethod<void>('stopCapture', <String, dynamic>{
      'sessionId': sessionId,
    });
  }

  Future<dynamic> handleNativeMethodCall(MethodCall call) async {
    if (call.method == 'onCapturePcm') {
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      final pcmBytes = arguments['pcm'];
      if (pcmBytes is! Uint8List) {
        throw const FormatException('onCapturePcm missing pcm bytes');
      }
      _captureFrames.add(
        PlatformPcmFrame(
          sessionId: arguments['sessionId'] as String? ?? '',
          sequence: arguments['sequence'] as int? ?? 0,
          captureTimeMicros: arguments['captureTimeMicros'] as int? ?? 0,
          sampleRate: _intArgument(arguments['sampleRate'], 48000),
          channels: _intArgument(arguments['channels'], 2).clamp(1, 64),
          pcm: _pcmFromBytes(pcmBytes),
        ),
      );
      return null;
    }

    if (call.method == 'onCaptureError') {
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      _captureErrors.add(
        PlatformAudioError(
          sessionId: arguments['sessionId'] as String? ?? '',
          message: arguments['message'] as String? ?? 'Audio capture failed',
        ),
      );
      return null;
    }

    throw MissingPluginException(
      'No audio platform handler for ${call.method}',
    );
  }

  Uint8List _pcmBytes(Int16List pcm) {
    final bytes = Uint8List(pcm.length * 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < pcm.length; i++) {
      data.setInt16(i * 2, pcm[i], Endian.little);
    }
    return bytes;
  }

  Int16List _pcmFromBytes(Uint8List bytes) {
    if (bytes.length.isOdd) {
      throw const FormatException('PCM byte length must be even');
    }
    final data = ByteData.sublistView(bytes);
    final pcm = Int16List(bytes.length ~/ 2);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = data.getInt16(i * 2, Endian.little);
    }
    return pcm;
  }

  int _intArgument(Object? value, int fallback) {
    if (value is int) {
      return value;
    }
    if (value is double) {
      return value.round();
    }
    return fallback;
  }
}

class PlatformPcmFrame {
  const PlatformPcmFrame({
    required this.sessionId,
    required this.sequence,
    required this.captureTimeMicros,
    required this.sampleRate,
    required this.channels,
    required this.pcm,
  });

  final String sessionId;
  final int sequence;
  final int captureTimeMicros;
  final int sampleRate;
  final int channels;
  final Int16List pcm;
}

class PlatformAudioError {
  const PlatformAudioError({
    required this.sessionId,
    required this.message,
  });

  final String sessionId;
  final String message;
}
