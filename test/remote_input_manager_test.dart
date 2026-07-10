import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

void main() {
  group('RemoteInputManager', () {
    test('creates an offer with input websocket path', () {
      final manager = RemoteInputManager();

      final offer = manager.createOffer(
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
      );

      expect(offer.action, RemoteInputControlAction.offer);
      expect(offer.path, '/input');
      expect(offer.layoutEdge, RemoteInputEdge.right);
      expect(manager.session(offer.sessionId)?.state,
          RemoteInputSessionState.offering);
    });

    test('accepts offers and dispatches packets only for connected sessions',
        () {
      final received = <RemoteInputPacketFrame>[];
      final manager = RemoteInputManager(onPacket: received.add);
      const offer = RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: 'input-1',
        sourcePeerId: 'mac',
        sinkPeerId: 'win',
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: 'ctrl+alt+esc',
      );

      final accept = manager.acceptOffer(offer);
      manager.handlePacketBytes(
        RemoteInputPacketFrame(
          sessionId: 'input-1',
          sequence: 1,
          timestampMicros: 2,
          eventType: RemoteInputEventType.mouseMove,
          payload: Uint8List.fromList(<int>[1]),
        ).encode(),
      );

      expect(accept.action, RemoteInputControlAction.accept);
      expect(received, hasLength(1));
      expect(received.single.sessionId, 'input-1');
    });

    test('propagates asynchronous packet handling to websocket backpressure',
        () async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) {
          gate.complete();
        }
      });
      final manager = RemoteInputManager(onPacket: (_) => gate.future);
      manager.acceptOffer(
        const RemoteInputControlMessage(
          action: RemoteInputControlAction.offer,
          sessionId: 'input-async-1',
          sourcePeerId: 'mac',
          sinkPeerId: 'win',
          layoutEdge: RemoteInputEdge.right,
        ),
      );
      final dynamic handlePacket = manager.handlePacketBytes;

      final dynamic result = handlePacket(
        RemoteInputPacketFrame(
          sessionId: 'input-async-1',
          sequence: 1,
          timestampMicros: 2,
          eventType: RemoteInputEventType.release,
          payload: Uint8List(0),
        ).encode(),
      );

      expect(result, isA<Future<void>>());
      var completed = false;
      unawaited((result as Future<void>).then((_) => completed = true));
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      gate.complete();
      await result;
      expect(completed, isTrue);
    });
  });
}
