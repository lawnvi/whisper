import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/bounded_outbound_queue.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:whisper/window_stream/core/window_input_event.dart';
import 'package:whisper/window_stream/pipeline/native_input_decoder.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';

void main() {
  group('WindowStreamControlMessage', () {
    const base = WindowStreamControlMessage(
      action: WindowStreamControlAction.open,
      sessionId: '6f1c1b5e-0c5a-4b6e-9d7a-0d3d6b2b9a11',
      viewerPeerId: 'phone',
      hostPeerId: 'mac',
      payload: {'windowId': 42},
    );

    test('maps viewer and host onto the wire source and sink', () {
      final json = base.toJson();
      expect(json['sourcePeerId'], 'phone');
      expect(json['sinkPeerId'], 'mac');
      final decoded = WindowStreamControlMessage.fromJson(
        json.cast<String, dynamic>(),
      );
      expect(decoded.viewerPeerId, 'phone');
      expect(decoded.hostPeerId, 'mac');
      expect(decoded.payload['windowId'], 42);
      expect(decoded.isInitial, isTrue);
    });

    test('only accept carries a transport token, and must', () {
      final accept = base
          .reply(WindowStreamControlAction.accept)
          .withTransport('t' * 43, port: 10002);
      final json = accept.toJson().cast<String, dynamic>();
      expect(
        WindowStreamControlMessage.fromJson(json).transportToken,
        't' * 43,
      );
      expect(WindowStreamControlMessage.fromJson(json).transportPort, 10002);
      expect(
        () => WindowStreamControlMessage.fromJson({
          ...json,
          'transportToken': '',
        }),
        throwsFormatException,
      );
      expect(
        () => WindowStreamControlMessage.fromJson({
          ...base.toJson(),
          'transportToken': 'x',
        }),
        throwsFormatException,
      );
    });

    test('rejects unknown actions and bad ports', () {
      expect(
        () => WindowStreamControlMessage.fromJson({
          ...base.toJson(),
          'action': 'hack',
        }),
        throwsFormatException,
      );
      expect(
        () => WindowStreamControlMessage.fromJson({
          ...base.toJson(),
          'transportPort': 70000,
        }),
        throwsFormatException,
      );
    });

    test('the action allowlist matches the enum', () {
      expect(
        WindowStreamControlMessage.allActions,
        WindowStreamControlAction.values.map((action) => action.name).toSet(),
      );
    });
  });

  group('WindowStreamPacket', () {
    test('video round trip keeps flags, pts and payload', () {
      final payload = Uint8List.fromList(List.generate(1000, (i) => i & 0xff));
      final packet = WindowStreamPacket.decode(
        WindowStreamPacket.video(
          payload,
          ptsUs: 123456789,
          flags: WindowStreamPacket.flagKey,
        ),
      );
      expect(packet, isA<WindowStreamVideo>());
      packet as WindowStreamVideo;
      expect(packet.isKey, isTrue);
      expect(packet.isConfig, isFalse);
      expect(packet.ptsUs, 123456789);
      expect(packet.payload, payload);
    });

    test('size and input round trip', () {
      final size =
          WindowStreamPacket.decode(WindowStreamPacket.size(1280, 800))
              as WindowStreamSize;
      expect([size.width, size.height], [1280, 800]);
      final input =
          WindowStreamPacket.decode(
                WindowStreamPacket.input(
                  kind: 7,
                  code: 1,
                  x: 0.25,
                  y: 0.75,
                  dx: -0.1,
                  dy: 0.2,
                  phase: 4,
                  modifiers: 8,
                  text: '你好',
                ),
              )
              as WindowStreamInput;
      expect(input.kind, 7);
      expect(input.code, 1);
      expect(input.x, 0.25);
      expect(input.dy, 0.2);
      expect(input.text, '你好');
    });

    test('rejects foreign magic, truncation and oversized text', () {
      expect(
        () => WindowStreamPacket.decode(Uint8List.fromList([1, 2, 3, 4, 5])),
        throwsFormatException,
      );
      final input = WindowStreamPacket.input(kind: 1);
      expect(
        () => WindowStreamPacket.decode(Uint8List.sublistView(input, 0, 30)),
        throwsFormatException,
      );
      expect(
        () => WindowStreamPacket.input(kind: 7, text: 'x' * 5000),
        throwsArgumentError,
      );
      // A viewer's key code or wheel delta that didn't fit made the Mac host
      // trap in Swift (CGKeyCode, Int32) and quit.
      for (final bad in [
        WindowStreamPacket.input(kind: 1, code: 70000),
        WindowStreamPacket.input(kind: 1, code: -1),
        WindowStreamPacket.input(kind: 3, dx: double.nan),
        WindowStreamPacket.input(kind: 3, dy: 1e300),
        WindowStreamPacket.input(kind: 0, x: double.infinity),
      ]) {
        expect(() => WindowStreamPacket.decode(bad), throwsFormatException);
      }
    });

    test('encoded input matches the native decoder', () {
      const event = ScrollInput(
        x: 0.5,
        y: 0.5,
        dx: 0.01,
        dy: -0.02,
        phase: ScrollPhase.changed,
        momentumPhase: ScrollPhase.none,
        precise: true,
      );
      final encoded = EncodedInput.of(event)!;
      final decoded =
          NativeInputDecoder.decode(
                kind: encoded.kind,
                code: encoded.code,
                modifiers: encoded.modifiers,
                x: encoded.x,
                y: encoded.y,
                dx: encoded.dx,
                dy: encoded.dy,
                phase: encoded.phase,
              )
              as ScrollInput;
      expect(decoded.phase, ScrollPhase.changed);
      expect(decoded.precise, isTrue);
      expect(decoded.dy, -0.02);
    });
  });

  group('video outbound queue', () {
    late List<Object> written;
    late Completer<void> gate;

    BoundedOutboundQueue queue({
      void Function()? onKeyframeNeeded,
      int maxItems = 4,
    }) {
      written = [];
      gate = Completer<void>();
      return BoundedOutboundQueue.video(
        addStream: (stream) async {
          await for (final item in stream) {
            written.add(item);
          }
          await gate.future;
        },
        maxItems: maxItems,
        maxBytes: 1 << 20,
        onKeyframeNeeded: onKeyframeNeeded,
      );
    }

    test('drops deltas until the next keyframe and asks for one', () async {
      var asks = 0;
      final q = queue(onKeyframeNeeded: () => asks++, maxItems: 3);
      // First item blocks the writer; the rest wait.
      unawaited(
        q.addWithResult(
          'key0',
          byteLength: 10,
          kind: OutboundPacketKind.videoKey,
        ),
      );
      final d1 = q.addWithResult(
        'd1',
        byteLength: 10,
        kind: OutboundPacketKind.videoDelta,
      );
      final d2 = q.addWithResult(
        'd2',
        byteLength: 10,
        kind: OutboundPacketKind.videoDelta,
      );
      // Queue is full (3 items): the next delta overflows and is dropped.
      final d3 = await q.addWithResult(
        'd3',
        byteLength: 10,
        kind: OutboundPacketKind.videoDelta,
      );
      expect(d3, OutboundQueueResult.dropped);
      expect(q.videoNeedsKeyframe, isTrue);
      expect(asks, greaterThan(0));
      // Waiting deltas were dropped too: they depend on the dropped frame's chain.
      expect(await d1, OutboundQueueResult.dropped);
      expect(await d2, OutboundQueueResult.dropped);
      // Further deltas are refused until a keyframe.
      expect(
        await q.addWithResult(
          'd4',
          byteLength: 10,
          kind: OutboundPacketKind.videoDelta,
        ),
        OutboundQueueResult.dropped,
      );
      final key = q.addWithResult(
        'key1',
        byteLength: 10,
        kind: OutboundPacketKind.videoKey,
      );
      expect(q.videoNeedsKeyframe, isFalse);
      gate.complete();
      expect(await key, OutboundQueueResult.sent);
      expect(written, ['key0', 'key1']);
    });

    test(
      'a newer keyframe replaces queued frames; config is never dropped silently',
      () async {
        final q = queue(maxItems: 8);
        unawaited(
          q.addWithResult(
            'key0',
            byteLength: 10,
            kind: OutboundPacketKind.videoKey,
          ),
        );
        final config = q.addWithResult(
          'cfg',
          byteLength: 10,
          kind: OutboundPacketKind.videoConfig,
        );
        final staleKey = q.addWithResult(
          'key1',
          byteLength: 10,
          kind: OutboundPacketKind.videoKey,
        );
        final delta = q.addWithResult(
          'd',
          byteLength: 10,
          kind: OutboundPacketKind.videoDelta,
        );
        final freshKey = q.addWithResult(
          'key2',
          byteLength: 10,
          kind: OutboundPacketKind.videoKey,
        );
        gate.complete();
        expect(await config, OutboundQueueResult.sent);
        expect(await staleKey, OutboundQueueResult.dropped);
        expect(await delta, OutboundQueueResult.dropped);
        expect(await freshKey, OutboundQueueResult.sent);
        expect(written, ['key0', 'cfg', 'key2']);
      },
    );
  });

  test('token registry accepts /window with its own namespace only', () {
    expect(normalizeMediaRoute('/window'), '/window');
    expect(normalizeMediaNamespace('', route: '/window'), 'window-stream');
    expect(
      normalizeMediaNamespace('window-stream', route: '/window'),
      'window-stream',
    );
    expect(
      () => normalizeMediaNamespace('audio', route: '/window'),
      throwsArgumentError,
    );
    expect(
      () => normalizeMediaNamespace('window-stream', route: '/input'),
      throwsArgumentError,
    );
  });

  test('window capabilities only travel on protocol 12', () {
    const capabilities = PeerCapabilities(
      windowStreamSourceV1: true,
      windowStreamSinkV1: true,
    );
    expect(
      capabilities.toWireJson(11).containsKey('windowStreamSourceV1'),
      isFalse,
    );
    final wire = capabilities.toWireJson(12);
    expect(wire['windowStreamSourceV1'], isTrue);
    expect(
      PeerCapabilities.fromWireJson(
        wire,
        protocolVersion: 12,
      ).windowStreamSinkV1,
      isTrue,
    );
    expect(
      () => PeerCapabilities.fromWireJson(wire, protocolVersion: 11),
      throwsFormatException,
    );
  });

  test('host encrypts video with its own send key, not the claim key', () {
    final host = File(
      'lib/window_stream/remote/window_stream_host.dart',
    ).readAsStringSync();
    final encoder = RegExp(
      r'final encoder = claim\.withMediaPacketContext\([\s\S]*?\);\n',
    ).firstMatch(host)!.group(0)!;
    expect(encoder, contains('(_, channelBinding) => sendKeyScope('));
    expect(encoder, contains('mediaMacKey: sendKey'));
    // Capture starts after the upgrade's ready frame.
    expect(host, contains('scheduleMicrotask(() {'));
  });
}
