import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

class RemoteInputPlatform {
  RemoteInputPlatform({
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(handleNativeMethodCall);
  }

  static const String channelName = 'com.vireen.whisper/remote_input';

  final MethodChannel _channel;
  final StreamController<RemoteInputPacketFrame> _inputEvents =
      StreamController<RemoteInputPacketFrame>.broadcast();
  final StreamController<PlatformRemoteInputRelease> _releases =
      StreamController<PlatformRemoteInputRelease>.broadcast();
  final StreamController<PlatformRemoteInputError> _errors =
      StreamController<PlatformRemoteInputError>.broadcast();

  Stream<RemoteInputPacketFrame> get inputEvents => _inputEvents.stream;
  Stream<PlatformRemoteInputRelease> get releases => _releases.stream;
  Stream<PlatformRemoteInputError> get errors => _errors.stream;

  Future<void> startCapture({
    required String sessionId,
    required RemoteInputEdge edge,
    required String releaseHotkey,
  }) {
    return _channel.invokeMethod<void>('startCapture', <String, dynamic>{
      'sessionId': sessionId,
      'edge': edge.name,
      'releaseHotkey': releaseHotkey,
    });
  }

  Future<void> stopCapture({
    required String sessionId,
  }) {
    return _channel.invokeMethod<void>('stopCapture', <String, dynamic>{
      'sessionId': sessionId,
    });
  }

  Future<void> pauseCapture({
    required String sessionId,
  }) {
    return _channel.invokeMethod<void>('pauseCapture', <String, dynamic>{
      'sessionId': sessionId,
    });
  }

  Future<void> startInjection({
    required String sessionId,
  }) {
    return _channel.invokeMethod<void>('startInjection', <String, dynamic>{
      'sessionId': sessionId,
    });
  }

  Future<void> injectEvent(RemoteInputPacketFrame event) {
    return _channel.invokeMethod<void>('injectEvent', <String, dynamic>{
      'sessionId': event.sessionId,
      'sequence': event.sequence,
      'timestampMicros': event.timestampMicros,
      'eventType': event.eventType.name,
      'payload': event.payload,
    });
  }

  Future<void> stopInjection({
    required String sessionId,
  }) {
    return _channel.invokeMethod<void>('stopInjection', <String, dynamic>{
      'sessionId': sessionId,
    });
  }

  Future<dynamic> handleNativeMethodCall(MethodCall call) async {
    if (call.method == 'onInputEvent') {
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      final payload = arguments['payload'];
      if (payload is! Uint8List) {
        throw const FormatException('onInputEvent missing payload bytes');
      }
      _inputEvents.add(
        RemoteInputPacketFrame(
          sessionId: arguments['sessionId'] as String? ?? '',
          sequence: arguments['sequence'] as int? ?? 0,
          timestampMicros: arguments['timestampMicros'] as int? ?? 0,
          eventType: _eventTypeArgument(arguments['eventType']),
          payload: payload,
        ),
      );
      return null;
    }

    if (call.method == 'onRelease') {
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      _releases.add(
        PlatformRemoteInputRelease(
          sessionId: arguments['sessionId'] as String? ?? '',
          reason: arguments['reason'] as String? ?? 'release',
        ),
      );
      return null;
    }

    if (call.method == 'onError') {
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      _errors.add(
        PlatformRemoteInputError(
          sessionId: arguments['sessionId'] as String? ?? '',
          message: arguments['message'] as String? ?? 'Remote input failed',
        ),
      );
      return null;
    }

    throw MissingPluginException(
      'No remote input platform handler for ${call.method}',
    );
  }

  RemoteInputEventType _eventTypeArgument(Object? value) {
    final name = value as String?;
    for (final eventType in RemoteInputEventType.values) {
      if (eventType.name == name) {
        return eventType;
      }
    }
    return RemoteInputEventType.release;
  }
}

class PlatformRemoteInputRelease {
  const PlatformRemoteInputRelease({
    required this.sessionId,
    required this.reason,
  });

  final String sessionId;
  final String reason;
}

class PlatformRemoteInputError {
  const PlatformRemoteInputError({
    required this.sessionId,
    required this.message,
  });

  final String sessionId;
  final String message;
}
