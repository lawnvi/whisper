import 'dart:convert';
import 'dart:typed_data';

enum RemoteInputControlAction {
  offer,
  accept,
  release,
  reject,
  stop,
  error,
}

enum RemoteInputTransport {
  websocket,
}

enum RemoteInputEdge {
  left,
  right,
  top,
  bottom,
}

enum RemoteInputEventType {
  mouseMove,
  mouseButton,
  mouseWheel,
  key,
  modifiers,
  release,
}

class RemoteInputEdgeMapping {
  const RemoteInputEdgeMapping({
    this.routeId = '',
    required this.sourceDisplayId,
    required this.sourceEdge,
    required this.sourceSegmentStart,
    required this.sourceSegmentEnd,
    required this.sinkDisplayId,
    required this.sinkEdge,
    required this.sinkSegmentStart,
    required this.sinkSegmentEnd,
  });

  final String routeId;
  final String sourceDisplayId;
  final RemoteInputEdge sourceEdge;
  final int sourceSegmentStart;
  final int sourceSegmentEnd;
  final String sinkDisplayId;
  final RemoteInputEdge sinkEdge;
  final int sinkSegmentStart;
  final int sinkSegmentEnd;

  int get sourceLength => sourceSegmentEnd - sourceSegmentStart;
  int get sinkLength => sinkSegmentEnd - sinkSegmentStart;
  String get effectiveRouteId => routeId.isNotEmpty
      ? routeId
      : [
          sourceDisplayId,
          sourceEdge.name,
          sourceSegmentStart,
          sourceSegmentEnd,
          sinkDisplayId,
          sinkEdge.name,
          sinkSegmentStart,
          sinkSegmentEnd,
        ].join('|');

  bool containsSourceCoordinate(double coordinate, {double tolerance = 0}) {
    return coordinate >= sourceSegmentStart - tolerance &&
        coordinate <= sourceSegmentEnd + tolerance;
  }

  double edgeUnitForSourceCoordinate(double coordinate) {
    if (sourceLength <= 0) {
      return 0;
    }
    final unit = (coordinate - sourceSegmentStart) / sourceLength;
    return unit.clamp(0, 1).toDouble();
  }

  double sourceCoordinateForEdgeUnit(double edgeUnit) {
    final clamped = edgeUnit.clamp(0, 1).toDouble();
    return sourceSegmentStart + sourceLength * clamped;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'routeId': effectiveRouteId,
        'sourceDisplayId': sourceDisplayId,
        'sourceEdge': sourceEdge.name,
        'sourceSegmentStart': sourceSegmentStart,
        'sourceSegmentEnd': sourceSegmentEnd,
        'sinkDisplayId': sinkDisplayId,
        'sinkEdge': sinkEdge.name,
        'sinkSegmentStart': sinkSegmentStart,
        'sinkSegmentEnd': sinkSegmentEnd,
      };

  factory RemoteInputEdgeMapping.fromJson(Map<String, dynamic> json) {
    return RemoteInputEdgeMapping(
      routeId: json['routeId'] as String? ?? '',
      sourceDisplayId: json['sourceDisplayId'] as String? ?? '',
      sourceEdge: _enumByName(
        RemoteInputEdge.values,
        json['sourceEdge'] as String?,
        RemoteInputEdge.right,
      ),
      sourceSegmentStart: _intJson(json['sourceSegmentStart']),
      sourceSegmentEnd: _intJson(json['sourceSegmentEnd']),
      sinkDisplayId: json['sinkDisplayId'] as String? ?? '',
      sinkEdge: _enumByName(
        RemoteInputEdge.values,
        json['sinkEdge'] as String?,
        RemoteInputEdge.left,
      ),
      sinkSegmentStart: _intJson(json['sinkSegmentStart']),
      sinkSegmentEnd: _intJson(json['sinkSegmentEnd']),
    );
  }
}

class RemoteInputControlMessage {
  const RemoteInputControlMessage({
    required this.action,
    required this.sessionId,
    required this.sourcePeerId,
    required this.sinkPeerId,
    this.transport = RemoteInputTransport.websocket,
    this.path = '/input',
    this.layoutEdge,
    this.sourceDisplayId = '',
    this.sourceEdge,
    this.sourceSegmentStart = 0,
    this.sourceSegmentEnd = 0,
    this.sinkDisplayId = '',
    this.sinkEdge,
    this.sinkSegmentStart = 0,
    this.sinkSegmentEnd = 0,
    this.edgeMappings = const <RemoteInputEdgeMapping>[],
    this.routeId = '',
    this.releaseHotkey = '',
    this.releaseReason = '',
    this.releaseSequence = 0,
    this.releaseActivationSequence = 0,
    this.releaseEdgeUnit = 0,
    this.errorMessage = '',
    this.sourcePlatform = '',
    this.sinkPlatform = '',
  });

  final RemoteInputControlAction action;
  final String sessionId;
  final String sourcePeerId;
  final String sinkPeerId;
  final RemoteInputTransport transport;
  final String path;
  final RemoteInputEdge? layoutEdge;
  final String sourceDisplayId;
  final RemoteInputEdge? sourceEdge;
  final int sourceSegmentStart;
  final int sourceSegmentEnd;
  final String sinkDisplayId;
  final RemoteInputEdge? sinkEdge;
  final int sinkSegmentStart;
  final int sinkSegmentEnd;
  final List<RemoteInputEdgeMapping> edgeMappings;
  final String routeId;
  final String releaseHotkey;
  final String releaseReason;
  final int releaseSequence;
  final int releaseActivationSequence;
  final double releaseEdgeUnit;
  final String errorMessage;
  final String sourcePlatform;
  final String sinkPlatform;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'action': action.name,
        'sessionId': sessionId,
        'sourcePeerId': sourcePeerId,
        'sinkPeerId': sinkPeerId,
        'transport': transport.name,
        'path': path,
        if (layoutEdge != null) 'layoutEdge': layoutEdge!.name,
        if (sourceDisplayId.isNotEmpty) 'sourceDisplayId': sourceDisplayId,
        if (sourceEdge != null) 'sourceEdge': sourceEdge!.name,
        if (sourceSegmentStart != 0) 'sourceSegmentStart': sourceSegmentStart,
        if (sourceSegmentEnd != 0) 'sourceSegmentEnd': sourceSegmentEnd,
        if (sinkDisplayId.isNotEmpty) 'sinkDisplayId': sinkDisplayId,
        if (sinkEdge != null) 'sinkEdge': sinkEdge!.name,
        if (sinkSegmentStart != 0) 'sinkSegmentStart': sinkSegmentStart,
        if (sinkSegmentEnd != 0) 'sinkSegmentEnd': sinkSegmentEnd,
        if (edgeMappings.isNotEmpty)
          'edgeMappings':
              edgeMappings.map((mapping) => mapping.toJson()).toList(),
        if (routeId.isNotEmpty) 'routeId': routeId,
        'releaseHotkey': releaseHotkey,
        'releaseReason': releaseReason,
        'releaseSequence': releaseSequence,
        'releaseActivationSequence': releaseActivationSequence,
        if (releaseEdgeUnit != 0 || action == RemoteInputControlAction.release)
          'releaseEdgeUnit': releaseEdgeUnit,
        'errorMessage': errorMessage,
        if (sourcePlatform.isNotEmpty) 'sourcePlatform': sourcePlatform,
        if (sinkPlatform.isNotEmpty) 'sinkPlatform': sinkPlatform,
      };

  factory RemoteInputControlMessage.fromJson(Map<String, dynamic> json) {
    return RemoteInputControlMessage(
      action: _enumByName(
        RemoteInputControlAction.values,
        json['action'] as String?,
        RemoteInputControlAction.error,
      ),
      sessionId: json['sessionId'] as String? ?? '',
      sourcePeerId: json['sourcePeerId'] as String? ?? '',
      sinkPeerId: json['sinkPeerId'] as String? ?? '',
      transport: _enumByName(
        RemoteInputTransport.values,
        json['transport'] as String?,
        RemoteInputTransport.websocket,
      ),
      path: json['path'] as String? ?? '/input',
      layoutEdge: _nullableEnumByName(
        RemoteInputEdge.values,
        json['layoutEdge'] as String?,
      ),
      sourceDisplayId: json['sourceDisplayId'] as String? ?? '',
      sourceEdge: _nullableEnumByName(
        RemoteInputEdge.values,
        json['sourceEdge'] as String?,
      ),
      sourceSegmentStart: _intJson(json['sourceSegmentStart']),
      sourceSegmentEnd: _intJson(json['sourceSegmentEnd']),
      sinkDisplayId: json['sinkDisplayId'] as String? ?? '',
      sinkEdge: _nullableEnumByName(
        RemoteInputEdge.values,
        json['sinkEdge'] as String?,
      ),
      sinkSegmentStart: _intJson(json['sinkSegmentStart']),
      sinkSegmentEnd: _intJson(json['sinkSegmentEnd']),
      edgeMappings: (json['edgeMappings'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) =>
              RemoteInputEdgeMapping.fromJson(Map<String, dynamic>.from(item)))
          .where((mapping) =>
              mapping.sourceDisplayId.isNotEmpty &&
              mapping.sinkDisplayId.isNotEmpty &&
              mapping.sourceSegmentEnd > mapping.sourceSegmentStart &&
              mapping.sinkSegmentEnd > mapping.sinkSegmentStart)
          .toList(growable: false),
      routeId: json['routeId'] as String? ?? '',
      releaseHotkey: json['releaseHotkey'] as String? ?? '',
      releaseReason: json['releaseReason'] as String? ?? '',
      releaseSequence: _intJson(json['releaseSequence']),
      releaseActivationSequence: _intJson(json['releaseActivationSequence']),
      releaseEdgeUnit: _doubleJson(json['releaseEdgeUnit']),
      errorMessage: json['errorMessage'] as String? ?? '',
      sourcePlatform: json['sourcePlatform'] as String? ?? '',
      sinkPlatform: json['sinkPlatform'] as String? ?? '',
    );
  }
}

class RemoteInputPacketFrame {
  RemoteInputPacketFrame({
    required this.sessionId,
    required this.sequence,
    required this.timestampMicros,
    required this.eventType,
    required this.payload,
  });

  static const String magic = 'WRI1';

  final String sessionId;
  final int sequence;
  final int timestampMicros;
  final RemoteInputEventType eventType;
  final Uint8List payload;

  Uint8List encode() {
    final header = utf8.encode(jsonEncode(<String, dynamic>{
      'sessionId': sessionId,
      'sequence': sequence,
      'timestampMicros': timestampMicros,
      'eventType': eventType.name,
      'payloadLength': payload.length,
    }));
    final headerLength = ByteData(4)..setUint32(0, header.length);
    final bytes = BytesBuilder(copy: false)
      ..add(ascii.encode(magic))
      ..add(headerLength.buffer.asUint8List())
      ..add(header)
      ..add(payload);
    return bytes.takeBytes();
  }

  factory RemoteInputPacketFrame.decode(Uint8List bytes) {
    if (bytes.length < 8) {
      throw const FormatException('remote input packet frame too short');
    }
    final actualMagic = ascii.decode(bytes.sublist(0, 4), allowInvalid: false);
    if (actualMagic != magic) {
      throw const FormatException('invalid remote input packet magic');
    }
    final headerLength = ByteData.sublistView(bytes, 4, 8).getUint32(0);
    final headerEnd = 8 + headerLength;
    if (bytes.length < headerEnd) {
      throw const FormatException('remote input packet header truncated');
    }
    final header = jsonDecode(
      utf8.decode(bytes.sublist(8, headerEnd)),
    ) as Map<String, dynamic>;
    final payload = Uint8List.sublistView(bytes, headerEnd);
    final expectedLength = header['payloadLength'] as int? ?? -1;
    if (payload.length != expectedLength) {
      throw const FormatException(
          'remote input packet payload length mismatch');
    }
    return RemoteInputPacketFrame(
      sessionId: header['sessionId'] as String? ?? '',
      sequence: header['sequence'] as int? ?? 0,
      timestampMicros: header['timestampMicros'] as int? ?? 0,
      eventType: _enumByName(
        RemoteInputEventType.values,
        header['eventType'] as String?,
        RemoteInputEventType.release,
      ),
      payload: payload,
    );
  }
}

T _enumByName<T extends Enum>(
  List<T> values,
  String? name,
  T fallback,
) {
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  return fallback;
}

T? _nullableEnumByName<T extends Enum>(
  List<T> values,
  String? name,
) {
  if (name == null) {
    return null;
  }
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  return null;
}

int _intJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return 0;
}

double _doubleJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return 0;
}
