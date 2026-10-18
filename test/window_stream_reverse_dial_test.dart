import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/media_upgrade_proof.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/window_stream/core/media_packet.dart';
import 'package:whisper/window_stream/core/window_input_event.dart';
import 'package:whisper/window_stream/core/window_source.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';
import 'package:whisper/window_stream/pipeline/media_sink.dart';
import 'package:whisper/window_stream/remote/remote_peer_source.dart';
import 'package:whisper/window_stream/remote/remote_window_worker.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';
import 'package:whisper/window_stream/remote/window_stream_host.dart';

/// `/window` between two in-process peers, both ways round: the viewer
/// dialling the host (desktops), and a phone host that opened the Whisper
/// session dialling the viewer back (a phone behind a VPN or AP isolation).
/// Real host, viewer, worker, proof handshake and packet envelope; only the
/// Whisper servers' `/window` route is a stand-in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const viewerId = 'viewer-peer';
  const hostId = 'host-peer';
  // The session's media keys: the viewer's send key is the host's receive
  // key and the other way round.
  final viewerSend = Uint8List.fromList(List.filled(32, 1));
  final hostSend = Uint8List.fromList(List.filled(32, 2));

  late _Peers peers;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Real sockets on loopback: the binding's mock client answers 400.
    HttpOverrides.global = null;
  });

  tearDown(() async {
    await peers.dispose();
    WindowStreamHost.debugIsPhone = null;
  });

  Future<_Peers> connect({
    required bool hostIsPhone,
    required bool hostDialledSession,
    bool viewerOffersDialBack = true,
  }) async {
    WindowStreamHost.debugIsPhone = hostIsPhone;
    final p = _Peers(
      viewerId: viewerId,
      hostId: hostId,
      viewerSend: viewerSend,
      hostSend: hostSend,
    );
    await p.start(
      hostDialledSession: hostDialledSession,
      viewerOffersDialBack: viewerOffersDialBack,
    );
    return p;
  }

  Future<void> streamAndCheck(_Peers p, {required bool expectHostDials}) async {
    final source = WindowStreamViewer.shared.sourceFor(hostId)!;
    final handle =
        await source.open(
              OpenTask(const TaskEntry(id: 7, appId: 'app', label: 'App')),
              const StreamOptions(),
            )
            as RemoteStreamHandle;
    final accept = p.toViewer.firstWhere(
      (m) => m.action == WindowStreamControlAction.accept,
    );
    expect(
      accept.payload[WindowStreamMediaDial.hostDialsKey] == true,
      expectHostDials,
    );
    expect(handle.transport, isA<WhisperWindowSpec>());
    expect(
      handle.transport is InboundWhisperWindowSpec,
      expectHostDials,
      reason: 'the viewer follows the host',
    );
    expect(
      p.toHost.any((m) => m.action == WindowStreamControlAction.dial),
      expectHostDials,
    );

    final sink = _Sink();
    final events = <StreamTransportEvent>[];
    final worker = RemoteWindowWorker(
      surface: 1,
      spec: handle.transport as WhisperWindowSpec,
      sink: sink,
      emit: events.add,
    );
    p.worker = worker;
    await worker.start();
    expect(
      events.whereType<TransportEnded>(),
      isEmpty,
      reason: '${events.whereType<TransportEnded>().firstOrNull?.failure}',
    );
    expect(events.whereType<TransportConnected>(), hasLength(1));
    expect(p.dialledByHost, expectHostDials ? 1 : 0);
    expect(p.dialledByViewer, expectHostDials ? 0 : 1);

    // The host starts capturing once its media is up.
    await _until(() => p.backend.started != null);
    final capture = p.backend.started!;
    p.backend.emit(
      CaptureVideo(
        capture,
        Uint8List.fromList([0, 0, 0, 1, 0x67, 9]),
        ptsUs: 10,
        config: true,
        key: false,
      ),
    );
    p.backend.emit(
      CaptureVideo(
        capture,
        Uint8List.fromList([0, 0, 0, 1, 0x65, 1, 2, 3]),
        ptsUs: 20,
        config: false,
        key: true,
      ),
    );
    // 50 ms of 48 kHz stereo: the viewer asked for sound in its `open`.
    // Frames before the codec is ready are dropped; the format goes first.
    CaptureAudio sound(int ptsUs) => CaptureAudio(
      capture,
      Uint8List(4800 * 2),
      ptsUs: ptsUs,
      rate: 48000,
      channels: 2,
    );
    p.backend.emit(sound(1000000));
    await _until(() => sink.audioFormat != null);
    p.backend.emit(sound(1050000));
    await _until(() => sink.video.length == 2 && sink.audio.length >= 2);
    expect(sink.video[0].bytes, [0, 0, 0, 1, 0x67, 9]);
    expect(sink.video[0].config, isTrue);
    expect(sink.video[1].bytes, [0, 0, 0, 1, 0x65, 1, 2, 3]);
    expect(sink.video[1].key, isTrue);
    expect(sink.audioFormat, (48000, 2));

    // Input goes the other way, under the viewer's own key.
    worker.input(
      const PointerInput(action: PointerAction.down, x: 0.25, y: 0.75),
    );
    worker.input(const TextInput('你好'));
    await _until(() => p.backend.inputs.length == 2);
    expect(p.backend.inputs[0].x, 0.25);
    expect(p.backend.inputs[0].y, 0.75);
    expect(p.backend.inputs[1].text, '你好');

    // Ending on the viewer ends the media on the host.
    await worker.close();
    await _until(() => p.host.streamCount == 0);
  }

  test('desktop host: the viewer dials, as before', () async {
    peers = await connect(hostIsPhone: false, hostDialledSession: true);
    await streamAndCheck(peers, expectHostDials: false);
  });

  test('phone host the viewer dialled: the viewer still dials', () async {
    peers = await connect(hostIsPhone: true, hostDialledSession: false);
    await streamAndCheck(peers, expectHostDials: false);
  });

  test('phone host that opened the session dials the viewer back', () async {
    peers = await connect(hostIsPhone: true, hostDialledSession: true);
    await streamAndCheck(peers, expectHostDials: true);
  });

  test('a viewer that does not offer dialBack is dialled never', () async {
    peers = await connect(
      hostIsPhone: true,
      hostDialledSession: true,
      viewerOffersDialBack: false,
    );
    await streamAndCheck(peers, expectHostDials: false);
  });

  test('the inbound slot only takes its own token, from its host', () async {
    peers = await connect(hostIsPhone: true, hostDialledSession: true);
    // Hold the host's dial back so the slot stays open.
    peers.holdDial = true;
    final source = WindowStreamViewer.shared.sourceFor(hostId)!;
    final handle =
        await source.open(
              OpenTask(const TaskEntry(id: 7, appId: 'app', label: 'App')),
              const StreamOptions(),
            )
            as RemoteStreamHandle;
    final spec = handle.transport as InboundWhisperWindowSpec;
    final sessionId = spec.sessionId;
    final token = spec.uri.queryParameters['token']!;
    final claim = peers.viewerTokens.lookup(
      route: '/window',
      sessionId: sessionId,
      token: token,
      now: DateTime.now(),
    )!;
    expect(WindowStreamViewer.shared.canAttachInbound(claim), isTrue);
    // The host's own token (from its accept) is no way into the viewer.
    final hostToken = peers.toViewer
        .firstWhere((m) => m.action == WindowStreamControlAction.accept)
        .transportToken;
    final other = peers.viewerTokens.issue(
      route: '/window',
      sessionId: sessionId,
      peerId: hostId,
      mediaMacKey: hostSend,
      now: DateTime.now(),
    );
    final wrongBinding = peers.viewerTokens.lookup(
      route: '/window',
      sessionId: sessionId,
      token: other,
      now: DateTime.now(),
    )!;
    expect(WindowStreamViewer.shared.canAttachInbound(wrongBinding), isFalse);
    expect(hostToken, isNot(token));
    // Another peer with this token is not the host.
    final wrongPeer = SessionUpgradeClaim(
      route: '/window',
      namespace: 'window-stream',
      sessionId: sessionId,
      peerId: 'someone-else',
      mediaMacKey: hostSend,
      channelBinding: base64Url.decode('$token='),
    );
    expect(WindowStreamViewer.shared.canAttachInbound(wrongPeer), isFalse);

    // A dialler without the host's send key fails the proof.
    final uri = Uri(
      scheme: 'ws',
      host: '127.0.0.1',
      port: peers.viewerServer.port,
      path: 'window',
      queryParameters: {'session': sessionId, 'token': token},
    );
    final socket = await WebSocket.connect(uri.toString());
    await expectLater(
      authenticateMediaWebSocketClient(
        IOWebSocketChannel(socket),
        uri: uri,
        route: '/window',
        namespace: 'window-stream',
        sessionId: sessionId,
        peerId: hostId,
        mediaMacKey: viewerSend,
      ),
      throwsA(anything),
    );
    // Nothing got in, and the token is not spent: the real host still can.
    expect(WindowStreamViewer.shared.canAttachInbound(claim), isTrue);
    await handle.close();
    expect(WindowStreamViewer.shared.canAttachInbound(claim), isFalse);
  });

  test('dial carries a token; other viewer messages still may not', () {
    final dial = WindowStreamControlMessage.fromJson({
      'action': 'dial',
      'sessionId': 's',
      'sourcePeerId': viewerId,
      'sinkPeerId': hostId,
      'transportToken': 'abc',
    });
    expect(dial.transportToken, 'abc');
    expect(dial.toJson()['transportToken'], 'abc');
    expect(
      () => WindowStreamControlMessage.fromJson({
        'action': 'dial',
        'sessionId': 's',
        'sourcePeerId': viewerId,
        'sinkPeerId': hostId,
      }),
      throwsFormatException,
    );
    expect(
      () => WindowStreamControlMessage.fromJson({
        'action': 'pause',
        'sessionId': 's',
        'sourcePeerId': viewerId,
        'sinkPeerId': hostId,
        'transportToken': 'abc',
      }),
      throwsFormatException,
    );
    expect(WindowStreamControlMessage.allActions, contains('dial'));
  });
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Two Whisper peers in one process: the viewer (WindowStreamViewer) and the
/// host (WindowStreamHost over a fake capture), with each one's `/window`
/// route and token registry as the socket layer runs them.
class _Peers {
  _Peers({
    required this.viewerId,
    required this.hostId,
    required this.viewerSend,
    required this.hostSend,
  });

  final String viewerId;
  final String hostId;
  final Uint8List viewerSend;
  final Uint8List hostSend;
  final backend = _FakeBackend();
  late final host = WindowStreamHost.withBackend(backend);
  final viewerTokens = SessionUpgradeTokenRegistry();
  final hostTokens = SessionUpgradeTokenRegistry();
  late HttpServer viewerServer;
  late HttpServer hostServer;
  final toHost = <WindowStreamControlMessage>[];
  final toViewer = <WindowStreamControlMessage>[];
  RemoteWindowWorker? worker;
  int dialledByHost = 0;
  int dialledByViewer = 0;
  bool holdDial = false;

  /// JSON both ways, as on the wire.
  static WindowStreamControlMessage _wire(WindowStreamControlMessage m) =>
      WindowStreamControlMessage.fromJson(
        jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>,
      );

  Future<void> start({
    required bool hostDialledSession,
    required bool viewerOffersDialBack,
  }) async {
    viewerServer = await _mediaServer(
      tokens: viewerTokens,
      canAttach: WindowStreamViewer.shared.canAttachInbound,
      attach: (channel, claim) {
        dialledByHost++;
        return WindowStreamViewer.shared.attachInbound(channel, claim);
      },
    );
    hostServer = await _mediaServer(
      tokens: hostTokens,
      canAttach: host.canAttachClaim,
      attach: (channel, claim) {
        dialledByViewer++;
        return host.attachChannel(
          channel,
          claim: claim,
          sendKeyScope: <T>(peerId, action) =>
              peerId == viewerId ? action(Uint8List.fromList(hostSend)) : null,
        );
      },
    );

    T? dialScope<T>(
      String peerId,
      T Function(Uri base, Uint8List sendKey, Uint8List receiveKey) action,
    ) {
      if (!hostDialledSession || peerId != viewerId) {
        return null;
      }
      return action(
        Uri(scheme: 'ws', host: '127.0.0.1', port: viewerServer.port),
        Uint8List.fromList(hostSend),
        Uint8List.fromList(viewerSend),
      );
    }

    host.dialScope = dialScope;

    // The host's replies; an accept gets the host's token, as the socket
    // layer issues it.
    Future<bool> hostSendToViewer(WindowStreamControlMessage message) async {
      var outgoing = message;
      if (message.action == WindowStreamControlAction.accept) {
        final token = hostTokens.issue(
          route: '/window',
          namespace: 'window-stream',
          sessionId: message.sessionId,
          peerId: viewerId,
          mediaMacKey: viewerSend,
          now: DateTime.now(),
        );
        outgoing = message.withTransport(token, port: hostServer.port);
      }
      final wire = _wire(outgoing);
      toViewer.add(wire);
      scheduleMicrotask(
        () => WindowStreamViewer.shared.handleControl(
          wire,
          remotePeerId: hostId,
          remoteHost: '127.0.0.1',
          sendKey: viewerSend,
          receiveKey: hostSend,
        ),
      );
      return true;
    }

    WindowStreamViewer.shared
      ..sender = (peerId, message) async {
        final wire = _wire(message);
        toHost.add(wire);
        if (wire.action == WindowStreamControlAction.dial && holdDial) {
          return true;
        }
        unawaited(
          Future(
            () => host.handleControl(
              wire,
              remotePeerId: viewerId,
              send: hostSendToViewer,
            ),
          ),
        );
        return true;
      }
      ..localPeerId = ((_) => viewerId)
      ..issueInboundToken = viewerOffersDialBack
          ? (peerId, sessionId) => viewerTokens.issue(
              route: '/window',
              namespace: 'window-stream',
              sessionId: sessionId,
              peerId: peerId,
              mediaMacKey: hostSend,
              now: DateTime.now(),
            )
          : null
      ..peerAvailable(
        peerId: hostId,
        name: 'Host',
        platform: WindowStreamPlatform.android,
        host: '127.0.0.1',
        port: hostServer.port,
      );
    host.start();
  }

  Future<void> dispose() async {
    await worker?.close();
    await host.closeAll();
    WindowStreamViewer.shared
      ..peerGone(hostId)
      ..sender = null
      ..localPeerId = null
      ..issueInboundToken = null;
    await viewerServer.close(force: true);
    await hostServer.close(force: true);
  }
}

/// A Whisper server's `/window` route: token lookup, challenge, proof
/// check, then the token is spent and the socket handed over.
Future<HttpServer> _mediaServer({
  required SessionUpgradeTokenRegistry tokens,
  required bool Function(SessionUpgradeClaim claim) canAttach,
  required bool Function(WebSocketChannel channel, SessionUpgradeClaim claim)
  attach,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final session = request.uri.queryParameters['session'] ?? '';
    final token = request.uri.queryParameters['token'] ?? '';
    final claim = tokens.lookup(
      route: '/window',
      sessionId: session,
      token: token,
      now: DateTime.now(),
    );
    if (claim == null || !canAttach(claim)) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(
      request,
      compression: CompressionOptions.compressionOff,
    );
    final random = Random.secure();
    final nonce = base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final challenge = MediaUpgradeChallenge(
      route: claim.route,
      namespace: claim.namespace,
      sessionId: session,
      tokenHash: mediaUpgradeTokenHash(token),
      nonce: nonce,
      peerId: claim.peerId,
      connectionGeneration: claim.connectionGeneration,
    );
    claim.withMediaMacKey(
      (key) => MediaUpgradeServerSession(
        channel: IOWebSocketChannel(socket),
        challenge: challenge,
        mediaMacKey: key,
        timeout: const Duration(seconds: 3),
        onAuthenticated: (channel) {
          final consumed = tokens.consume(
            route: '/window',
            sessionId: session,
            token: token,
            now: DateTime.now(),
            expected: claim,
          );
          return consumed != null && attach(channel, consumed);
        },
        onProvisionalFinished: () {},
      ),
    );
  });
  return server;
}

class _FakeBackend implements WindowCaptureBackend {
  void Function(CaptureEvent event)? _onEvent;
  int? started;
  final inputs = <({double x, double y, String? text})>[];

  void emit(CaptureEvent event) => _onEvent?.call(event);

  @override
  bool get supported => true;
  @override
  bool get inputPermitted => true;
  @override
  bool get opensApps => true;
  @override
  bool get audioSupported => true;

  @override
  void attach(void Function(CaptureEvent event) onEvent) => _onEvent = onEvent;

  @override
  Future<WindowStreamFailureReason?> unavailableReason() async => null;

  @override
  Future<CaptureResult> requestCatalog() async => CaptureResult(
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'windows': [
            {
              'id': 7,
              'appId': 'app',
              'appName': 'App',
              'title': 'App',
              'width': 1080,
              'height': 2400,
            },
          ],
          'apps': const [],
          'locked': false,
        }),
      ),
    ),
  );

  @override
  Future<CaptureResult> requestIcon(String appId, {int size = 128}) async =>
      CaptureResult.failed(1);
  @override
  Future<CaptureResult> requestThumbnail(int windowId, int maxEdge) async =>
      CaptureResult.failed(1);
  @override
  Future<CaptureResult> launchApp(String appId) async =>
      CaptureResult.failed(1);
  @override
  RemoteWindowInfo? appWindow(String appId) => null;
  @override
  void captureCloseWindow(int windowId, int pid) {}

  @override
  int captureStart(CaptureRequest request) {
    expect(request.audio, isTrue);
    return started = 41;
  }

  @override
  void captureStop(int capture) => started = null;
  @override
  void captureSetPaused(int capture, bool paused) {}
  @override
  void captureRequestKeyframe(int capture) {}
  @override
  void captureSetBusy(int capture, bool busy) {}
  @override
  void captureSetScreen(int capture, int screenKey) {}
  @override
  void captureSetViewport(
    int capture,
    double width,
    double height,
    double scale,
  ) {}
  @override
  void captureSetInset(int capture, double fraction) {}
  @override
  void captureSetPixelRatio(int capture, double ratio) {}
  @override
  void captureSetAudio(int capture, int mode) {}

  @override
  void captureInput(
    int capture, {
    required int kind,
    int code = 0,
    int modifiers = 0,
    double x = 0,
    double y = 0,
    double dx = 0,
    double dy = 0,
    int phase = 0,
    String? text,
  }) {
    inputs.add((x: x, y: y, text: text));
  }
}

class _Packet {
  _Packet(this.bytes, {required this.config, required this.key});

  final List<int> bytes;
  final bool config;
  final bool key;
}

class _Sink implements MediaSink {
  final video = <_Packet>[];
  final audio = <_Packet>[];
  (int, int)? audioFormat;

  @override
  MediaPacketWriter beginVideo(int surface, int length) => _Writer(video);

  @override
  MediaPacketWriter beginAudio(int surface, int length) => _Writer(audio);

  @override
  void configureAudio(
    int surface, {
    required int sampleRate,
    required int channels,
  }) {
    audioFormat = (sampleRate, channels);
  }
}

class _Writer implements MediaPacketWriter {
  _Writer(this._into);

  final List<_Packet> _into;
  final _bytes = BytesBuilder();

  @override
  void write(Uint8List chunk) => _bytes.add(chunk);

  @override
  void commit({required int ptsUs, required bool config, required bool key}) {
    _into.add(_Packet(_bytes.takeBytes(), config: config, key: key));
  }

  @override
  void discard() {}
}
