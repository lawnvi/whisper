import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

void main() {
  group('RemoteInputControlMessage', () {
    test('round-trips offer fields', () {
      const message = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-1',
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        transport: RemoteInputTransport.websocket,
        path: '/input',
        layoutEdge: RemoteInputEdge.right,
        sourceDisplayId: 'source-main',
        sourceEdge: RemoteInputEdge.right,
        sourceSegmentStart: 260,
        sourceSegmentEnd: 900,
        sinkDisplayId: 'sink-main',
        sinkEdge: RemoteInputEdge.left,
        sinkSegmentStart: 0,
        sinkSegmentEnd: 640,
        edgeMappings: [
          RemoteInputEdgeMapping(
            routeId: 'route-left',
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.right,
            sourceSegmentStart: 260,
            sourceSegmentEnd: 580,
            sinkDisplayId: 'sink-left',
            sinkEdge: RemoteInputEdge.left,
            sinkSegmentStart: 0,
            sinkSegmentEnd: 320,
          ),
          RemoteInputEdgeMapping(
            routeId: 'route-right',
            sourceDisplayId: 'source-main',
            sourceEdge: RemoteInputEdge.right,
            sourceSegmentStart: 580,
            sourceSegmentEnd: 900,
            sinkDisplayId: 'sink-right',
            sinkEdge: RemoteInputEdge.left,
            sinkSegmentStart: 0,
            sinkSegmentEnd: 320,
          ),
        ],
        releaseHotkey: 'ctrl+alt+esc',
        sourcePlatform: 'macos',
        sinkPlatform: 'windows',
        remoteClipboardV1: true,
      );

      final decoded = RemoteInputControlMessage.fromJson(message.toJson());

      expect(decoded.action, RemoteInputControlAction.offer);
      expect(decoded.sessionId, 'input-1');
      expect(decoded.sourcePeerId, 'mac');
      expect(decoded.sinkPeerId, 'win');
      expect(decoded.transport, RemoteInputTransport.websocket);
      expect(decoded.path, '/input');
      expect(decoded.layoutEdge, RemoteInputEdge.right);
      expect(decoded.sourceDisplayId, 'source-main');
      expect(decoded.sourceEdge, RemoteInputEdge.right);
      expect(decoded.sourceSegmentStart, 260);
      expect(decoded.sourceSegmentEnd, 900);
      expect(decoded.sinkDisplayId, 'sink-main');
      expect(decoded.sinkEdge, RemoteInputEdge.left);
      expect(decoded.sinkSegmentStart, 0);
      expect(decoded.sinkSegmentEnd, 640);
      expect(decoded.edgeMappings, hasLength(2));
      expect(decoded.edgeMappings.first.routeId, 'route-left');
      expect(decoded.edgeMappings.first.sinkDisplayId, 'sink-left');
      expect(decoded.edgeMappings.last.routeId, 'route-right');
      expect(decoded.edgeMappings.last.sourceSegmentStart, 580);
      expect(decoded.releaseHotkey, 'ctrl+alt+esc');
      expect(decoded.sourcePlatform, 'macos');
      expect(decoded.sinkPlatform, 'windows');
      expect(decoded.remoteClipboardV1, isTrue);
    });

    test('round-trips error messages without an edge', () {
      const message = RemoteInputControlMessage(
        action: RemoteInputControlAction.error,
        sessionId: 'input-1',
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        errorMessage: 'Accessibility permission denied',
      );

      final decoded = RemoteInputControlMessage.fromJson(message.toJson());

      expect(decoded.action, RemoteInputControlAction.error);
      expect(decoded.layoutEdge, isNull);
      expect(decoded.errorMessage, 'Accessibility permission denied');
    });

    test('round-trips edge release controls', () {
      const message = RemoteInputControlMessage(
        action: RemoteInputControlAction.release,
        sessionId: 'input-1',
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        releaseReason: 'edge',
        releaseSequence: 7,
        releaseActivationSequence: 3,
        releaseEdgeUnit: 0.625,
        routeId: 'route-left',
        sourceDisplayId: 'source-left',
        sourceEdge: RemoteInputEdge.left,
        sourceSegmentStart: 200,
        sourceSegmentEnd: 800,
      );

      final decoded = RemoteInputControlMessage.fromJson(message.toJson());

      expect(decoded.action, RemoteInputControlAction.release);
      expect(decoded.releaseReason, 'edge');
      expect(decoded.releaseSequence, 7);
      expect(decoded.releaseActivationSequence, 3);
      expect(decoded.releaseEdgeUnit, 0.625);
      expect(decoded.routeId, 'route-left');
      expect(decoded.sourceDisplayId, 'source-left');
      expect(decoded.sourceEdge, RemoteInputEdge.left);
      expect(decoded.sourceSegmentStart, 200);
      expect(decoded.sourceSegmentEnd, 800);
      expect(decoded.sessionId, 'input-1');
    });

    test('keeps zero edge unit on release messages', () {
      const message = RemoteInputControlMessage(
        action: RemoteInputControlAction.release,
        sessionId: 'input-1',
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        releaseReason: 'edge',
        releaseEdgeUnit: 0,
      );

      final json = message.toJson();
      final decoded = RemoteInputControlMessage.fromJson(json);

      expect(json['releaseEdgeUnit'], 0);
      expect(decoded.releaseEdgeUnit, 0);
    });

    test('serializes a transport token only for a successful accept', () {
      const accept = RemoteInputControlMessage(
        action: RemoteInputControlAction.accept,
        sessionId: 'input-1',
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        transportToken: 'input-token',
      );

      expect(accept.toJson()['transportToken'], 'input-token');
      expect(
        RemoteInputControlMessage.fromJson(accept.toJson()).transportToken,
        'input-token',
      );
      for (final action in RemoteInputControlAction.values.where(
        (action) => action != RemoteInputControlAction.accept,
      )) {
        final control = RemoteInputControlMessage(
          action: action,
          sessionId: 'input-1',
          sourcePeerId: 'mac',
          sinkPeerId: 'win',
          transportToken: 'must-not-leak',
        );
        expect(control.toJson(), isNot(contains('transportToken')));
        expect(
          () => RemoteInputControlMessage.fromJson(<String, dynamic>{
            ...control.toJson(),
            'transportToken': 'unexpected',
          }),
          throwsFormatException,
        );
      }
    });
  });

  group('RemoteInputPacketFrame', () {
    test('encodes and decodes mouse movement metadata and payload', () {
      final frame = RemoteInputPacketFrame(
        sessionId: 'input-1',
        sequence: 7,
        timestampMicros: 42,
        eventType: RemoteInputEventType.mouseMove,
        payload: Uint8List.fromList(<int>[1, 2, 3]),
      );

      final decoded = RemoteInputPacketFrame.decode(frame.encode());

      expect(decoded.sessionId, 'input-1');
      expect(decoded.sequence, 7);
      expect(decoded.timestampMicros, 42);
      expect(decoded.eventType, RemoteInputEventType.mouseMove);
      expect(decoded.payload, <int>[1, 2, 3]);
    });

    test('rejects frames without the remote input magic header', () {
      final badPacket = Uint8List.fromList(<int>[0, 1, 2, 3, 4]);

      expect(
        () => RemoteInputPacketFrame.decode(badPacket),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('MessageEnum', () {
    test('appends remote input control for backward compatibility', () {
      expect(
        MessageEnum.RemoteInputControl.index,
        MessageEnum.AudioControl.index + 1,
      );
    });
  });
}
