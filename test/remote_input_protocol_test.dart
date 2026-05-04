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
        releaseHotkey: 'ctrl+alt+esc',
      );

      final decoded = RemoteInputControlMessage.fromJson(message.toJson());

      expect(decoded.action, RemoteInputControlAction.offer);
      expect(decoded.sessionId, 'input-1');
      expect(decoded.sourcePeerId, 'mac');
      expect(decoded.sinkPeerId, 'win');
      expect(decoded.transport, RemoteInputTransport.websocket);
      expect(decoded.path, '/input');
      expect(decoded.layoutEdge, RemoteInputEdge.right);
      expect(decoded.releaseHotkey, 'ctrl+alt+esc');
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
      );

      final decoded = RemoteInputControlMessage.fromJson(message.toJson());

      expect(decoded.action, RemoteInputControlAction.release);
      expect(decoded.releaseReason, 'edge');
      expect(decoded.releaseSequence, 7);
      expect(decoded.releaseActivationSequence, 3);
      expect(decoded.sessionId, 'input-1');
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
