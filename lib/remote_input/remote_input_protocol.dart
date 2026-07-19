import 'dart:typed_data';

import 'package:whisper/socket/framed_packet_codec.dart';

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
      sourceEdge: enumByName(
        RemoteInputEdge.values,
        json['sourceEdge'] as String?,
        RemoteInputEdge.right,
      ),
      sourceSegmentStart: intJson(json['sourceSegmentStart']),
      sourceSegmentEnd: intJson(json['sourceSegmentEnd']),
      sinkDisplayId: json['sinkDisplayId'] as String? ?? '',
      sinkEdge: enumByName(
        RemoteInputEdge.values,
        json['sinkEdge'] as String?,
        RemoteInputEdge.left,
      ),
      sinkSegmentStart: intJson(json['sinkSegmentStart']),
      sinkSegmentEnd: intJson(json['sinkSegmentEnd']),
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
    this.transportToken = '',
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
  final String transportToken;
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

  RemoteInputControlMessage withTransportToken(String token) {
    return RemoteInputControlMessage(
      action: action,
      sessionId: sessionId,
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      transport: transport,
      path: path,
      transportToken: token,
      layoutEdge: layoutEdge,
      sourceDisplayId: sourceDisplayId,
      sourceEdge: sourceEdge,
      sourceSegmentStart: sourceSegmentStart,
      sourceSegmentEnd: sourceSegmentEnd,
      sinkDisplayId: sinkDisplayId,
      sinkEdge: sinkEdge,
      sinkSegmentStart: sinkSegmentStart,
      sinkSegmentEnd: sinkSegmentEnd,
      edgeMappings: edgeMappings,
      routeId: routeId,
      releaseHotkey: releaseHotkey,
      releaseReason: releaseReason,
      releaseSequence: releaseSequence,
      releaseActivationSequence: releaseActivationSequence,
      releaseEdgeUnit: releaseEdgeUnit,
      errorMessage: errorMessage,
      sourcePlatform: sourcePlatform,
      sinkPlatform: sinkPlatform,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'action': action.name,
        'sessionId': sessionId,
        'sourcePeerId': sourcePeerId,
        'sinkPeerId': sinkPeerId,
        'transport': transport.name,
        'path': path,
        if (action == RemoteInputControlAction.accept &&
            transportToken.isNotEmpty)
          'transportToken': transportToken,
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
      action: enumByName(
        RemoteInputControlAction.values,
        json['action'] as String?,
        RemoteInputControlAction.error,
      ),
      sessionId: json['sessionId'] as String? ?? '',
      sourcePeerId: json['sourcePeerId'] as String? ?? '',
      sinkPeerId: json['sinkPeerId'] as String? ?? '',
      transport: enumByName(
        RemoteInputTransport.values,
        json['transport'] as String?,
        RemoteInputTransport.websocket,
      ),
      path: json['path'] as String? ?? '/input',
      transportToken: _transportTokenFromJson(
        json,
        allowed: json['action'] == RemoteInputControlAction.accept.name,
      ),
      layoutEdge: nullableEnumByName(
        RemoteInputEdge.values,
        json['layoutEdge'] as String?,
      ),
      sourceDisplayId: json['sourceDisplayId'] as String? ?? '',
      sourceEdge: nullableEnumByName(
        RemoteInputEdge.values,
        json['sourceEdge'] as String?,
      ),
      sourceSegmentStart: intJson(json['sourceSegmentStart']),
      sourceSegmentEnd: intJson(json['sourceSegmentEnd']),
      sinkDisplayId: json['sinkDisplayId'] as String? ?? '',
      sinkEdge: nullableEnumByName(
        RemoteInputEdge.values,
        json['sinkEdge'] as String?,
      ),
      sinkSegmentStart: intJson(json['sinkSegmentStart']),
      sinkSegmentEnd: intJson(json['sinkSegmentEnd']),
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
      releaseSequence: intJson(json['releaseSequence']),
      releaseActivationSequence: intJson(json['releaseActivationSequence']),
      releaseEdgeUnit: doubleJson(json['releaseEdgeUnit']),
      errorMessage: json['errorMessage'] as String? ?? '',
      sourcePlatform: json['sourcePlatform'] as String? ?? '',
      sinkPlatform: json['sinkPlatform'] as String? ?? '',
    );
  }
}

String _transportTokenFromJson(
  Map<String, dynamic> json, {
  required bool allowed,
}) {
  final present = json.containsKey('transportToken');
  if (!allowed) {
    if (present) {
      throw const FormatException('unexpected transport token');
    }
    return '';
  }
  final token = json['transportToken'];
  if (token is! String || token.isEmpty) {
    throw const FormatException('missing transport token');
  }
  return token;
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
    return encodeFramedPacket(
      magic: magic,
      header: <String, dynamic>{
        'sessionId': sessionId,
        'sequence': sequence,
        'timestampMicros': timestampMicros,
        'eventType': eventType.name,
        'payloadLength': payload.length,
      },
      payload: payload,
    );
  }

  factory RemoteInputPacketFrame.decode(Uint8List bytes) {
    final decoded = decodeFramedPacket(
      magic: magic,
      label: 'remote input packet',
      bytes: bytes,
    );
    final header = decoded.header;
    return RemoteInputPacketFrame(
      sessionId: header['sessionId'] as String? ?? '',
      sequence: header['sequence'] as int? ?? 0,
      timestampMicros: header['timestampMicros'] as int? ?? 0,
      eventType: enumByName(
        RemoteInputEventType.values,
        header['eventType'] as String?,
        RemoteInputEventType.release,
      ),
      payload: decoded.payload,
    );
  }
}
