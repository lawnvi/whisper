import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
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
  final StreamController<PlatformRemoteInputDiagnostic> _diagnostics =
      StreamController<PlatformRemoteInputDiagnostic>.broadcast();

  Stream<RemoteInputPacketFrame> get inputEvents => _inputEvents.stream;
  Stream<PlatformRemoteInputRelease> get releases => _releases.stream;
  Stream<PlatformRemoteInputError> get errors => _errors.stream;
  Stream<PlatformRemoteInputDiagnostic> get diagnostics => _diagnostics.stream;

  Future<void> startCapture({
    required String sessionId,
    required RemoteInputEdge edge,
    required String releaseHotkey,
    String displayId = '',
    int segmentStart = 0,
    int segmentEnd = 0,
  }) {
    return _channel.invokeMethod<void>('startCapture', <String, dynamic>{
      'sessionId': sessionId,
      'edge': edge.name,
      'releaseHotkey': releaseHotkey,
      if (displayId.isNotEmpty) 'displayId': displayId,
      'segmentStart': segmentStart,
      'segmentEnd': segmentEnd,
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
    int releaseSequence = 0,
    int releaseActivationSequence = 0,
    double releaseEdgeUnit = 0,
  }) {
    return _channel.invokeMethod<void>('pauseCapture', <String, dynamic>{
      'sessionId': sessionId,
      'releaseSequence': releaseSequence,
      'releaseActivationSequence': releaseActivationSequence,
      'releaseEdgeUnit': releaseEdgeUnit,
    });
  }

  Future<void> startInjection({
    required String sessionId,
    String displayId = '',
    RemoteInputEdge? edge,
    int segmentStart = 0,
    int segmentEnd = 0,
  }) {
    return _channel.invokeMethod<void>('startInjection', <String, dynamic>{
      'sessionId': sessionId,
      if (displayId.isNotEmpty) 'displayId': displayId,
      if (edge != null) 'edge': edge.name,
      'segmentStart': segmentStart,
      'segmentEnd': segmentEnd,
    });
  }

  Future<RemoteInputTopology> displayTopology() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getDisplayTopology',
    );
    if (result == null) {
      return RemoteInputTopology.fallback();
    }
    return RemoteInputTopology.fromJson(result);
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
          sequence: arguments['sequence'] as int? ?? 0,
          activationSequence: arguments['activationSequence'] as int? ?? 0,
          edgeUnit: _doubleArgument(arguments['edgeUnit']),
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

    if (call.method == 'onDiagnostic') {
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      _diagnostics.add(
        PlatformRemoteInputDiagnostic(
          sessionId: arguments['sessionId'] as String? ?? '',
          message: arguments['message'] as String? ?? '',
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

  double _doubleArgument(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return 0;
  }
}

class PlatformRemoteInputRelease {
  const PlatformRemoteInputRelease({
    required this.sessionId,
    required this.reason,
    this.sequence = 0,
    this.activationSequence = 0,
    this.edgeUnit = 0,
  });

  final String sessionId;
  final String reason;
  final int sequence;
  final int activationSequence;
  final double edgeUnit;
}

class PlatformRemoteInputError {
  const PlatformRemoteInputError({
    required this.sessionId,
    required this.message,
  });

  final String sessionId;
  final String message;
}

class PlatformRemoteInputDiagnostic {
  const PlatformRemoteInputDiagnostic({
    required this.sessionId,
    required this.message,
  });

  final String sessionId;
  final String message;
}
