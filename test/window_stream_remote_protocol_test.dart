import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/bounded_outbound_queue.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/socket/wire_input_policy.dart';
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

  test('a host offers a window in the one session it starts', () {
    const offer = WindowStreamControlMessage(
      action: WindowStreamControlAction.offer,
      sessionId: '5a4f1f0e-1c2b-4d3e-8f9a-0b1c2d3e4f50',
      viewerPeerId: 'viewer',
      hostPeerId: 'host',
      payload: {
        'window': {'id': 7, 'appId': 'com.x', 'appName': 'X', 'title': 'Doc'},
      },
    );
    expect(offer.isInitial, isTrue);
    expect(offer.isHostInitiated, isTrue);
    expect(offer.isTerminal, isTrue);
    expect(WindowStreamControlMessage.allActions, contains('offer'));
    final back = WindowStreamControlMessage.fromJson(
      Map<String, dynamic>.from(offer.toJson()),
    );
    expect(back.action, WindowStreamControlAction.offer);
    expect(back.viewerPeerId, 'viewer');

    // The host sends it reversed from the usual viewer-first sessions...
    final host = WireControlSessionRegistry();
    expect(
      host
          .validateAndRemember(
            namespace: 'window-stream',
            sessionId: offer.sessionId,
            sourcePeerId: 'viewer',
            sinkPeerId: 'host',
            authenticatedPeerId: 'viewer',
            localPeerId: 'host',
            isInitialOffer: true,
            isIncoming: false,
            reverseInitialDirection: true,
          )
          .isAccepted,
      isTrue,
    );
    // ...and the viewer takes it in its natural direction.
    final viewer = WireControlSessionRegistry();
    expect(
      viewer
          .validateAndRemember(
            namespace: 'window-stream',
            sessionId: offer.sessionId,
            sourcePeerId: 'viewer',
            sinkPeerId: 'host',
            authenticatedPeerId: 'host',
            localPeerId: 'viewer',
            isInitialOffer: true,
            isIncoming: false,
          )
          .isAccepted,
      isTrue,
    );
    final svr = File('lib/socket/svrmanager.dart').readAsStringSync();
    expect(
      svr,
      contains(
        'reverseInitialDirection: !weAreHost && !control.isHostInitiated',
      ),
    );
    expect(svr, contains('reverseInitialDirection: control.isHostInitiated'));
    // Offers go only to peers that announced they accept them.
    expect(svr, contains('capabilities.windowStreamOfferV1 == true'));
    const caps = PeerCapabilities(windowStreamOfferV1: true);
    expect(
      PeerCapabilities.fromWireJson(
        caps.toWireJson(12),
        protocolVersion: 12,
      ).windowStreamOfferV1,
      isTrue,
    );
    expect(caps.toWireJson(11).containsKey('windowStreamOfferV1'), isFalse);
  });

  test('socket server wires /window like the other media routes', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    expect(source, contains("path != 'window'"));
    expect(source, contains('WindowStreamHost.shared.canAttachClaim(claim)'));
    expect(source, contains('sendKeyScope: _withMediaSendKeyFor'));
    expect(source, contains('case MessageEnum.WindowStreamControl:'));
    expect(source, contains('WindowStreamHost.shared.closePeer(peerId)'));
    expect(source, contains('await WindowStreamHost.shared.closeAll();'));
    // Hosting is for mutually trusted peers only.
    final handler = RegExp(
      r'case MessageEnum\.WindowStreamControl:[\s\S]*?case MessageEnum\.AudioGroupControl:',
    ).firstMatch(source)!.group(0)!;
    expect(handler, contains('storedRemote?.auth == true'));
    expect(handler, contains("'untrusted'"));
    // Manual input must keep working on protocol 12.
    expect(source, contains('(profile?.protocolVersion ?? 0) >= 11'));
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

  test(
    'the viewer sizes the Mac window and the host keeps its radio awake',
    () {
      const message = WindowStreamControlMessage(
        action: WindowStreamControlAction.viewport,
        sessionId: 'session',
        viewerPeerId: 'viewer',
        hostPeerId: 'host',
        payload: {
          'viewportWidth': 390,
          'viewportHeight': 800,
          'viewportScale': 0.75,
        },
      );
      final copy = WindowStreamControlMessage.fromJson(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
      );
      expect(copy.action, WindowStreamControlAction.viewport);
      expect(copy.payload['viewportScale'], 0.75);
      expect(copy.isInitial, isFalse);
      expect(copy.isTerminal, isFalse);
      expect(WindowStreamControlMessage.allActions, contains('viewport'));
      expect(
        WindowStreamPacket.decode(WindowStreamPacket.tick()),
        isA<WindowStreamTick>(),
      );

      final host = File(
        'lib/window_stream/remote/window_stream_host.dart',
      ).readAsStringSync();
      expect(host, contains('_bindings?.captureSetViewport('));
      expect(host, contains('WindowStreamPacket.tick()'));
      final viewer = File(
        'lib/page/window_stream/flow_window_viewer_page.dart',
      ).readAsStringSync();
      expect(viewer, contains('handle.setViewport('));
      expect(viewer, contains('ViewerTextScaleRuler('));
    },
  );

  test('a text field taking focus on the Mac brings up the phone keyboard', () {
    for (final typing in [true, false]) {
      final packet = WindowStreamPacket.decode(
        WindowStreamPacket.textFocus(typing: typing),
      );
      expect(packet, isA<WindowStreamTextFocus>());
      expect((packet as WindowStreamTextFocus).typing, typing);
    }
    final watcher = File(
      'packages/window_stream_native/macos/Classes/TextFocusWatcher.swift',
    ).readAsStringSync();
    expect(watcher, contains('kAXFocusedUIElementChangedNotification'));
    // Not switching on web content's tree: it slows those apps' typing.
    expect(
      watcher,
      isNot(
        contains('AXUIElementSetAttributeValue(app, "AXManualAccessibility"'),
      ),
    );
    final host = File(
      'lib/window_stream/remote/window_stream_host.dart',
    ).readAsStringSync();
    expect(host, contains('WindowStreamPacket.textFocus(typing: flags == 1)'));
    final activity = File(
      'android/app/src/main/kotlin/com/vireen/whisper/WindowStreamActivity.kt',
    ).readAsStringSync();
    // Put away again only if it came up by itself; a focus known before
    // the window opened is applied once it is up.
    expect(activity, contains('keyboardShown && keyboardFollowsFocus'));
    expect(
      activity,
      contains('if (textFocusOf[id] == true) followTextFocus(true)'),
    );
    expect(activity, contains('insets.show(WindowInsetsCompat.Type.ime())'));
    // The keyboard covers the picture; the window over there stops above
    // it, its text field just over the keys.
    expect(activity, contains('emit("keyboard", mapOf("inset" to'));
    final stage = File(
      'packages/window_stream_native/macos/Classes/VirtualStage.swift',
    ).readAsStringSync();
    expect(stage, contains('Self.shortened(usable, by: bottomInset)'));
    expect(host, contains('captureSetInset(capture, stream.keyboardInset)'));
  });
}
