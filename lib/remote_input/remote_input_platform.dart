import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

typedef RemoteInputTextShortcutHandler =
    FutureOr<bool> Function(RemoteInputTextShortcut shortcut);
typedef RemoteInputLocalPasteHandler = FutureOr<bool> Function();

enum RemoteInputTextShortcut { selectAll, copy, cut, paste, undo, redo }

bool handleRemoteInputTextShortcut(RemoteInputTextShortcut shortcut) {
  final context = primaryFocus?.context;
  if (context == null || !context.mounted) {
    return false;
  }

  switch (shortcut) {
    case RemoteInputTextShortcut.selectAll:
      return _invokeRemoteInputTextIntent(
        context,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
    case RemoteInputTextShortcut.copy:
      return _invokeRemoteInputTextIntent(
        context,
        CopySelectionTextIntent.copy,
      );
    case RemoteInputTextShortcut.cut:
      return _invokeRemoteInputTextIntent(
        context,
        const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
      );
    case RemoteInputTextShortcut.paste:
      return _invokeRemoteInputTextIntent(
        context,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      );
    case RemoteInputTextShortcut.undo:
      return _invokeRemoteInputTextIntent(
        context,
        const UndoTextIntent(SelectionChangedCause.keyboard),
      );
    case RemoteInputTextShortcut.redo:
      return _invokeRemoteInputTextIntent(
        context,
        const RedoTextIntent(SelectionChangedCause.keyboard),
      );
  }
}

bool _invokeRemoteInputTextIntent<T extends Intent>(
  BuildContext context,
  T intent,
) {
  // Actions.handler lost the concrete intent lookup in newer Flutter versions.
  // Supplying the runtime intent keeps this compatible across toolchains.
  final action = Actions.maybeFind<Intent>(context, intent: intent);
  if (action == null) {
    return false;
  }
  Actions.maybeInvoke<Intent>(context, intent);
  return true;
}

class RemoteInputPlatform {
  RemoteInputPlatform({
    MethodChannel? channel,
    RemoteInputTextShortcutHandler? textShortcutHandler,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _textShortcutHandler =
           textShortcutHandler ?? handleRemoteInputTextShortcut {
    _channel.setMethodCallHandler(handleNativeMethodCall);
  }

  static const String channelName = 'com.vireen.whisper/remote_input';

  final MethodChannel _channel;
  final RemoteInputTextShortcutHandler _textShortcutHandler;
  RemoteInputLocalPasteHandler? _localPasteHandler;
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

  void configureLocalPasteHandler(RemoteInputLocalPasteHandler? handler) {
    _localPasteHandler = handler;
  }

  Future<void> startCapture({
    required String sessionId,
    required RemoteInputEdge edge,
    required String releaseHotkey,
    String displayId = '',
    int segmentStart = 0,
    int segmentEnd = 0,
    List<RemoteInputEdgeMapping> edgeMappings =
        const <RemoteInputEdgeMapping>[],
  }) {
    return _channel.invokeMethod<void>('startCapture', <String, dynamic>{
      'sessionId': sessionId,
      'edge': edge.name,
      'releaseHotkey': releaseHotkey,
      if (displayId.isNotEmpty) 'displayId': displayId,
      'segmentStart': segmentStart,
      'segmentEnd': segmentEnd,
      if (edgeMappings.isNotEmpty)
        'segments': edgeMappings
            .map(
              (mapping) => <String, dynamic>{
                'displayId': mapping.sourceDisplayId,
                'edge': mapping.sourceEdge.name,
                'start': mapping.sourceSegmentStart,
                'end': mapping.sourceSegmentEnd,
                'routeId': mapping.effectiveRouteId,
              },
            )
            .toList(),
    });
  }

  Future<void> stopCapture({required String sessionId}) {
    return _channel.invokeMethod<void>('stopCapture', <String, dynamic>{
      'sessionId': sessionId,
    });
  }

  Future<void> pauseCapture({
    required String sessionId,
    int releaseSequence = 0,
    int releaseActivationSequence = 0,
    double releaseEdgeUnit = 0,
    String displayId = '',
    RemoteInputEdge? edge,
    int segmentStart = 0,
    int segmentEnd = 0,
    String routeId = '',
  }) {
    return _channel.invokeMethod<void>('pauseCapture', <String, dynamic>{
      'sessionId': sessionId,
      'releaseSequence': releaseSequence,
      'releaseActivationSequence': releaseActivationSequence,
      'releaseEdgeUnit': releaseEdgeUnit,
      if (displayId.isNotEmpty) 'displayId': displayId,
      if (edge != null) 'edge': edge.name,
      if (segmentStart != 0 || segmentEnd != 0) ...{
        'segmentStart': segmentStart,
        'segmentEnd': segmentEnd,
      },
      if (routeId.isNotEmpty) 'routeId': routeId,
    });
  }

  Future<void> startInjection({
    required String sessionId,
    String displayId = '',
    RemoteInputEdge? edge,
    int segmentStart = 0,
    int segmentEnd = 0,
    List<RemoteInputEdgeMapping> edgeMappings =
        const <RemoteInputEdgeMapping>[],
  }) {
    return _channel.invokeMethod<void>('startInjection', <String, dynamic>{
      'sessionId': sessionId,
      if (displayId.isNotEmpty) 'displayId': displayId,
      if (edge != null) 'edge': edge.name,
      'segmentStart': segmentStart,
      'segmentEnd': segmentEnd,
      if (edgeMappings.isNotEmpty)
        'mappings': edgeMappings.map((mapping) => mapping.toJson()).toList(),
    });
  }

  Future<void> updateInjectionRoutes({
    required String sessionId,
    required List<RemoteInputEdgeMapping> edgeMappings,
  }) {
    return _channel
        .invokeMethod<void>('updateInjectionRoutes', <String, dynamic>{
          'sessionId': sessionId,
          'mappings': edgeMappings.map((mapping) => mapping.toJson()).toList(),
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

  Future<void> stopInjection({required String sessionId}) {
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
          sourceEdgeUnit: arguments['sourceEdgeUnit'] as bool? ?? false,
          sourceDisplayId: arguments['sourceDisplayId'] as String? ?? '',
          sourceEdge: _nullableEdgeArgument(arguments['sourceEdge']),
          sourceSegmentStart: _intArgument(arguments['sourceSegmentStart']),
          sourceSegmentEnd: _intArgument(arguments['sourceSegmentEnd']),
          routeId: arguments['routeId'] as String? ?? '',
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

    if (call.method == 'onTextShortcut') {
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      final shortcut = _textShortcutArgument(arguments['shortcut']);
      if (shortcut == null) {
        return false;
      }
      return Future<bool>.value(_textShortcutHandler(shortcut));
    }

    if (call.method == 'onLocalPasteShortcut') {
      final handler = _localPasteHandler;
      if (handler == null) {
        return true;
      }
      return Future<bool>.value(handler());
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

  RemoteInputTextShortcut? _textShortcutArgument(Object? value) {
    final name = value as String?;
    for (final shortcut in RemoteInputTextShortcut.values) {
      if (shortcut.name == name) {
        return shortcut;
      }
    }
    return null;
  }

  double _doubleArgument(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return 0;
  }

  int _intArgument(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    return 0;
  }

  RemoteInputEdge? _nullableEdgeArgument(Object? value) {
    final name = value as String?;
    for (final edge in RemoteInputEdge.values) {
      if (edge.name == name) {
        return edge;
      }
    }
    return null;
  }
}

class PlatformRemoteInputRelease {
  const PlatformRemoteInputRelease({
    required this.sessionId,
    required this.reason,
    this.sequence = 0,
    this.activationSequence = 0,
    this.edgeUnit = 0,
    this.sourceEdgeUnit = false,
    this.sourceDisplayId = '',
    this.sourceEdge,
    this.sourceSegmentStart = 0,
    this.sourceSegmentEnd = 0,
    this.routeId = '',
  });

  final String sessionId;
  final String reason;
  final int sequence;
  final int activationSequence;
  final double edgeUnit;
  final bool sourceEdgeUnit;
  final String sourceDisplayId;
  final RemoteInputEdge? sourceEdge;
  final int sourceSegmentStart;
  final int sourceSegmentEnd;
  final String routeId;
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
