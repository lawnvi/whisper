import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_fanout_transport.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/media_channel_dial.dart';
import 'package:whisper/socket/media_dial_back.dart';
import 'package:whisper/socket/media_upgrade_proof.dart';
import 'package:whisper/socket/media_upgrade_server.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/socket/svrmanager.dart';

const _audioSessionId = '11111111-1111-4111-8111-111111111111';
const _inputSessionId = '22222222-2222-4222-8222-222222222222';
const _otherInputSessionId = '44444444-4444-4444-8444-444444444444';
const _audioGroupSessionId = '55555555-5555-4555-8555-555555555555';
const _otherAudioSessionId = '33333333-3333-4333-8333-333333333333';
const _sourcePeerId = 'source-peer';
const _sinkPeerId = 'sink-peer';

final _mediaKey = Uint8List.fromList(
  List<int>.generate(32, (index) => index + 1),
);

Future<int> _upgradeStatus(Uri uri, {String? origin}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri.replace(scheme: 'http'));
    request.headers
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('Sec-WebSocket-Version', '13')
      ..set(
        'Sec-WebSocket-Key',
        base64.encode(Uint8List.fromList(List<int>.filled(16, 7))),
      );
    if (origin != null) {
      request.headers.set('Origin', origin);
    }
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Uri _mediaUri(int port, String route, {String? sessionId, String? token}) {
  return buildPeerPacketUri(
    host: '127.0.0.1',
    port: port,
    path: route,
    queryParameters: <String, String>{
      if (sessionId != null) 'session': sessionId,
      if (token != null) 'token': token,
    },
  );
}

Uint8List _mediaChannelBinding(String token) =>
    Uint8List.fromList(base64Url.decode('$token='));

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A packet of the group the test's validators accept, from its source.
AudioGroupPacketFrame _groupPacket(List<int> payload) => AudioGroupPacketFrame(
  groupId: 'group-a',
  streamId: 'stream-a',
  sessionId: _audioSessionId,
  sourcePeerId: _sourcePeerId,
  sequence: 1,
  captureTimeMicros: 10,
  targetPlaybackTimeMicros: 20,
  durationMicros: 20000,
  channelMask: AudioChannelMask.stereo,
  payload: Uint8List.fromList(payload),
);

Future<WebSocketChannel> _connectMediaChannel(
  Uri uri, {
  required String namespace,
  Uint8List? mediaMacKey,
  String peerId = _sourcePeerId,
}) async {
  WebSocketChannel channel = IOWebSocketChannel.connect(uri);
  await channel.ready;
  return authenticateMediaWebSocketClient(
    channel,
    uri: uri,
    route: uri.path,
    namespace: namespace,
    sessionId: uri.queryParameters['session']!,
    peerId: peerId,
    mediaMacKey: mediaMacKey ?? _mediaKey,
  );
}

Future<
  ({
    WebSocket socket,
    StreamIterator<dynamic> events,
    MediaUpgradeChallenge challenge,
  })
>
_openProvisionalMediaSocket(Uri uri) async {
  final socket = await WebSocket.connect(uri.toString());
  final events = StreamIterator<dynamic>(socket);
  if (!await events.moveNext().timeout(const Duration(seconds: 1))) {
    throw StateError('media challenge socket closed early');
  }
  return (
    socket: socket,
    events: events,
    challenge: MediaUpgradeChallenge.fromWire(events.current),
  );
}

Future<String> _nextProvisionalOutcome(StreamIterator<dynamic> events) async {
  final hasMessage = await events.moveNext().timeout(
    const Duration(seconds: 1),
  );
  if (!hasMessage) {
    return 'closed';
  }
  return isMediaUpgradeReady(events.current) ? 'ready' : 'unexpected';
}

void main() {
  // The controlled side cannot be reached (its firewall, a VPN, AP
  // isolation): the controller issues a token for its own /input, the
  // controlled side dials it with that, and input flows as before. Real
  // dial, proof, packet keys and input manager; only the controller's
  // Whisper route is a stand-in.
  test(
    'input the sink could not be reached for arrives over its dial back',
    () async {
      final controllerSend = Uint8List.fromList(List<int>.filled(32, 7));
      final sinkSend = Uint8List.fromList(List<int>.filled(32, 9));
      final controllerTokens = SessionUpgradeTokenRegistry();
      final waits = MediaDialBackWaits(timeout: const Duration(seconds: 3));
      final upgrades = MediaUpgradeServer(
        maxProvisional: 2,
        proofTimeout: const Duration(seconds: 2),
      );
      final controllerServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      controllerServer.listen((request) async {
        final credentials = mediaUpgradeCredentials(request.uri)!;
        final claim = controllerTokens.lookup(
          route: '/input',
          sessionId: credentials.sessionId,
          token: credentials.token,
          now: DateTime.now(),
        );
        if (claim == null || !waits.canAttach(claim)) {
          request.response.statusCode = HttpStatus.unauthorized;
          await request.response.close();
          return;
        }
        final slot = upgrades.reserve()!;
        final socket = await WebSocketTransformer.upgrade(request);
        slot.prove(
          IOWebSocketChannel(socket),
          MediaUpgradeOffer.forClaim(claim, credentials.token),
          mediaMacKey: sinkSend,
          onProven: (channel) {
            final consumed = controllerTokens.consume(
              route: '/input',
              sessionId: credentials.sessionId,
              token: credentials.token,
              now: DateTime.now(),
              expected: claim,
            );
            return consumed != null &&
                waits.attach(
                  channel,
                  consumed,
                  encoder: () => consumed.withMediaPacketContext(
                    (_, binding) => AuthenticatedMediaPacketEncoder(
                      route: '/input',
                      namespace: 'remote-input',
                      sessionId: consumed.sessionId,
                      mediaMacKey: controllerSend,
                      channelBinding: binding,
                      maxPayloadBytes: RemoteInputManager.maxPacketPayloadBytes,
                    ),
                  ),
                );
          },
        );
      });
      final received = <RemoteInputPacketFrame>[];
      final sink = RemoteInputManager(onPacket: received.add);
      sink.acceptOffer(
        const RemoteInputControlMessage(
          action: RemoteInputControlAction.offer,
          sessionId: _inputSessionId,
          sourcePeerId: _sourcePeerId,
          sinkPeerId: _sinkPeerId,
          layoutEdge: RemoteInputEdge.right,
        ),
      );
      RemoteInputWebSocketPacketTransport.dialBack = (accept) => waits.wait(
        MediaRoute.input,
        peerId: _sinkPeerId,
        sessionId: accept.sessionId,
        ask: () {
          final token = controllerTokens.issue(
            route: '/input',
            sessionId: accept.sessionId,
            peerId: _sinkPeerId,
            mediaMacKey: sinkSend,
            reverse: true,
            now: DateTime.now(),
          );
          // The sink, on the dialBack message: dials the controller's /chat
          // address with the token, as its server would.
          unawaited(() async {
            final dialed = await dialBackMediaChannel(
              MediaRoute.input,
              host: '127.0.0.1',
              port: controllerServer.port,
              sessionId: accept.sessionId,
              token: token,
              localPeerId: _sinkPeerId,
              peerId: _sourcePeerId,
              connectionGeneration: 0,
              sendKey: sinkSend,
              receiveKey: controllerSend,
            );
            sink.attachChannel(dialed.channel, claim: dialed.claim);
          }());
          return true;
        },
      );
      addTearDown(() async {
        RemoteInputWebSocketPacketTransport.dialBack = null;
        await sink.closeChannels();
        await controllerServer.close(force: true);
      });
      // Where the accept said to dial: nothing listens there any more.
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final unreachable = closed.port;
      await closed.close();

      final transport = await RemoteInputWebSocketPacketTransport.connect(
        _mediaUri(
          unreachable,
          '/input',
          sessionId: _inputSessionId,
          token: base64Url.encode(Uint8List(32)).replaceAll('=', ''),
        ),
        mediaMacKey: controllerSend,
        accept: const RemoteInputControlMessage(
          action: RemoteInputControlAction.accept,
          sessionId: _inputSessionId,
          sourcePeerId: _sourcePeerId,
          sinkPeerId: _sinkPeerId,
        ),
      );
      transport.send(
        RemoteInputPacketFrame(
          sessionId: _inputSessionId,
          sequence: 1,
          timestampMicros: 1,
          eventType: RemoteInputEventType.key,
          payload: Uint8List.fromList(utf8.encode('{}')),
        ),
      );
      await _waitFor(() => received.isNotEmpty);
      expect(received.single.sequence, 1);
      expect(sink.activeChannelCount, 1);
      await transport.close();
    },
  );

  // The audio isolate's own port checks the token in the main isolate, so it
  // learns the token is used up only after the proof passed. It must not
  // play from the channel before that, nor lose what came meanwhile.
  test(
    'a proof checked across isolates admits the channel once its token is spent',
    () async {
      for (final spent in <bool>[true, false]) {
        final upgrades = MediaUpgradeServer(
          maxProvisional: 1,
          proofTimeout: const Duration(seconds: 2),
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final tokenSpent = Completer<bool>();
        final received = Completer<List<int>>();
        var admitted = false;
        server.listen((request) async {
          final slot = upgrades.reserve()!;
          final socket = await WebSocketTransformer.upgrade(request);
          slot.prove(
            IOWebSocketChannel(socket),
            const MediaUpgradeOffer(
              route: '/audio',
              namespace: 'audio-group',
              sessionId: _audioSessionId,
              peerId: _sourcePeerId,
              connectionGeneration: 1,
              token: 'token-a',
            ),
            mediaMacKey: _mediaKey,
            onProven: (channel) async {
              if (!await tokenSpent.future) return false;
              admitted = true;
              channel.stream.listen((message) {
                if (!received.isCompleted) {
                  received.complete(message as List<int>);
                }
              });
              return true;
            },
          );
        });
        final client = await dialMediaChannel(
          Uri.parse(
            'ws://127.0.0.1:${server.port}/audio'
            '?session=$_audioSessionId&token=token-a',
          ),
          MediaRoute.audio,
          sessionId: _audioSessionId,
          proverPeerId: _sourcePeerId,
          proofKey: _mediaKey,
        );
        final closed = client.stream.drain<void>();
        // Sent before the main isolate answered about the token.
        client.sink.add(<int>[1, 2, 3]);
        expect(upgrades.provisionalCount, 0, reason: 'spent=$spent');
        tokenSpent.complete(spent);
        if (spent) {
          expect(await received.future, <int>[1, 2, 3]);
          await client.sink.close();
        } else {
          await closed.timeout(const Duration(seconds: 2));
          expect(admitted, isFalse);
        }
        await server.close(force: true);
      }
    },
  );

  late SessionUpgradeTokenRegistry tokens;
  late AudioShareManager audioManager;
  late RemoteInputManager inputManager;
  late WsSvrManager server;
  late int port;
  late bool allowAudioGroupClaim;
  int? expectedMediaGeneration;

  setUp(() async {
    tokens = SessionUpgradeTokenRegistry();
    allowAudioGroupClaim = false;
    expectedMediaGeneration = null;
    audioManager = AudioShareManager();
    inputManager = RemoteInputManager();
    inputManager.acceptOffer(
      const RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: _inputSessionId,
        sourcePeerId: _sourcePeerId,
        sinkPeerId: _sinkPeerId,
        layoutEdge: RemoteInputEdge.right,
      ),
    );
    server = WsSvrManager.forTesting(
      audioManager: audioManager,
      remoteInputManager: inputManager,
      sessionUpgradeTokens: tokens,
      // [_audioSessionId] stands for a sink of a live group; the other group
      // session only while a test allows it.
      audioGroupClaimValidator: (claim) =>
          claim.peerId == _sourcePeerId &&
          (claim.sessionId == _audioSessionId ||
              (allowAudioGroupClaim &&
                  claim.sessionId == _audioGroupSessionId)),
      audioGroupPacketValidator: (claim, packet) =>
          (claim.sessionId == _audioSessionId ||
              (allowAudioGroupClaim &&
                  claim.sessionId == _audioGroupSessionId)) &&
          packet.groupId == 'group-a' &&
          packet.streamId == 'stream-a',
      mediaPeerClaimValidator: (claim) =>
          expectedMediaGeneration == null ||
          claim.connectionGeneration == expectedMediaGeneration,
    );
    final result = await server.startServer(0);
    expect(result.isSuccess, isTrue);
    port = result.port;
  });

  tearDown(() async {
    await server.closeGracefully(closeServer: true, forceServerClose: true);
  });

  // A token issued for a dial back must only reach the wait for that dial:
  // never a session this device accepted the forward way, on any route.
  test(
    'a dial-back token nothing waits for is refused on every route',
    () async {
      for (final route in <String>['/input', '/audio']) {
        final sessionId = route == '/input' ? _inputSessionId : _audioSessionId;
        final token = tokens.issue(
          route: route,
          sessionId: sessionId,
          peerId: _sourcePeerId,
          mediaMacKey: _mediaKey,
          reverse: true,
          now: DateTime.now(),
        );
        expect(
          await _upgradeStatus(
            _mediaUri(port, route, sessionId: sessionId, token: token),
          ),
          HttpStatus.unauthorized,
          reason: route,
        );
      }
      expect(inputManager.activeChannelCount, 0);
      expect(audioManager.activeChannelCount, 0);
    },
  );

  test('rejects non-positive media proof resource limits', () {
    expect(
      () => WsSvrManager.forTesting(mediaProofTimeout: Duration.zero),
      throwsArgumentError,
    );
    expect(
      () => WsSvrManager.forTesting(maxProvisionalMediaSockets: 0),
      throwsArgumentError,
    );
  });

  test(
    'missing token is 401 and a non-empty Origin is 403 before consume',
    () async {
      expect(
        await _upgradeStatus(_mediaUri(port, '/audio')),
        HttpStatus.unauthorized,
      );
      final token = tokens.issue(
        route: '/audio',
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now(),
      );
      final uri = _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: token,
      );

      expect(
        await _upgradeStatus(uri, origin: 'https://attacker.invalid'),
        HttpStatus.forbidden,
      );
      final socket = await _connectMediaChannel(uri, namespace: 'audio-group');
      await socket.sink.close();
    },
  );

  test(
    'invalid media proof closes provisionally without consuming the token',
    () async {
      final token = tokens.issue(
        route: '/audio',
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now(),
      );
      final uri = _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: token,
      );
      final attacker = await WebSocket.connect(uri.toString());
      final events = StreamIterator<dynamic>(attacker);

      expect(
        await events.moveNext().timeout(const Duration(milliseconds: 500)),
        isTrue,
      );
      expect(
        jsonDecode(events.current as String),
        containsPair('type', 'whisper-media-challenge-v1'),
      );
      attacker.add(
        jsonEncode(<String, Object>{
          'type': 'whisper-media-proof-v1',
          'proof': base64Url.encode(Uint8List(32)).replaceAll('=', ''),
        }),
      );

      expect(
        await events.moveNext().timeout(const Duration(seconds: 1)),
        isFalse,
      );
      expect(tokens.length, 1);
      expect(audioManager.activeChannelCount, 0);
    },
  );

  test(
    'proof replay against a fresh nonce does not consume the token',
    () async {
      final token = tokens.issue(
        route: '/audio',
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now(),
      );
      final uri = _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: token,
      );
      final first = await _openProvisionalMediaSocket(uri);
      final replayedProof = createMediaUpgradeProof(
        challenge: first.challenge,
        mediaMacKey: _mediaKey,
      );
      await first.socket.close();
      await _waitFor(() => server.debugProvisionalMediaSocketCount == 0);

      final second = await _openProvisionalMediaSocket(uri);
      expect(second.challenge.nonce, isNot(first.challenge.nonce));
      second.socket.add(encodeMediaUpgradeProof(replayedProof));

      expect(await _nextProvisionalOutcome(second.events), 'closed');
      expect(tokens.length, 1);
      expect(audioManager.activeChannelCount, 0);

      final valid = await _connectMediaChannel(uri, namespace: 'audio-group');
      expect(tokens.length, 0);
      await valid.sink.close();
    },
  );

  test(
    'proof from a superseded connection generation cannot claim the token',
    () async {
      expectedMediaGeneration = 7;
      final token = tokens.issue(
        route: '/audio',
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        connectionGeneration: 7,
        now: DateTime.now(),
      );
      final uri = _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: token,
      );
      final provisional = await _openProvisionalMediaSocket(uri);
      final proof = createMediaUpgradeProof(
        challenge: provisional.challenge,
        mediaMacKey: _mediaKey,
      );

      expectedMediaGeneration = 8;
      provisional.socket.add(encodeMediaUpgradeProof(proof));

      expect(await _nextProvisionalOutcome(provisional.events), 'closed');
      expect(tokens.length, 1);
      expect(audioManager.activeChannelCount, 0);

      expectedMediaGeneration = 7;
      final valid = await _connectMediaChannel(uri, namespace: 'audio-group');
      expect(tokens.length, 0);
      await valid.sink.close();
    },
  );

  test(
    'concurrent valid proofs atomically select exactly one winner',
    () async {
      final token = tokens.issue(
        route: '/audio',
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now(),
      );
      final uri = _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: token,
      );
      final first = await _openProvisionalMediaSocket(uri);
      final second = await _openProvisionalMediaSocket(uri);

      first.socket.add(
        encodeMediaUpgradeProof(
          createMediaUpgradeProof(
            challenge: first.challenge,
            mediaMacKey: _mediaKey,
          ),
        ),
      );
      second.socket.add(
        encodeMediaUpgradeProof(
          createMediaUpgradeProof(
            challenge: second.challenge,
            mediaMacKey: _mediaKey,
          ),
        ),
      );

      final outcomes = await Future.wait(<Future<String>>[
        _nextProvisionalOutcome(first.events),
        _nextProvisionalOutcome(second.events),
      ]);
      expect(outcomes.where((outcome) => outcome == 'ready'), hasLength(1));
      expect(outcomes.where((outcome) => outcome == 'closed'), hasLength(1));
      expect(tokens.length, 0);
      expect(audioManager.activeChannelCount, 1);

      await Future.wait(<Future<void>>[
        first.socket.close(),
        second.socket.close(),
      ]);
    },
  );

  test(
    'proof timeout releases bounded quota without consuming either token',
    () async {
      await server.closeGracefully(closeServer: true, forceServerClose: true);
      server = WsSvrManager.forTesting(
        audioManager: audioManager,
        remoteInputManager: inputManager,
        sessionUpgradeTokens: tokens,
        audioGroupClaimValidator: (claim) => claim.sessionId == _audioSessionId,
        mediaPeerClaimValidator: (_) => true,
        mediaProofTimeout: const Duration(milliseconds: 100),
        maxProvisionalMediaSockets: 1,
      );
      final result = await server.startServer(0);
      expect(result.isSuccess, isTrue);
      port = result.port;
      String issueToken() => tokens.issue(
        route: '/audio',
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now(),
      );
      final firstUri = _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: issueToken(),
      );
      final secondUri = _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: issueToken(),
      );
      final first = await _openProvisionalMediaSocket(firstUri);

      expect(server.debugProvisionalMediaSocketCount, 1);
      expect(audioManager.activeChannelCount, 0);
      expect(await _upgradeStatus(secondUri), HttpStatus.tooManyRequests);
      expect(tokens.length, 2);

      expect(await _nextProvisionalOutcome(first.events), 'closed');
      expect(server.debugProvisionalMediaSocketCount, 0);
      expect(audioManager.activeChannelCount, 0);
      expect(tokens.length, 2);

      final valid = await _connectMediaChannel(
        secondUri,
        namespace: 'audio-group',
      );
      expect(server.debugProvisionalMediaSocketCount, 0);
      expect(audioManager.activeChannelCount, 1);
      expect(tokens.length, 1);
      await valid.sink.close();
    },
  );

  test(
    'random generation failure releases quota and pending attachment',
    () async {
      await server.closeGracefully(closeServer: true, forceServerClose: true);
      server = WsSvrManager.forTesting(
        audioManager: audioManager,
        remoteInputManager: inputManager,
        sessionUpgradeTokens: tokens,
        mediaPeerClaimValidator: (_) => true,
        maxProvisionalMediaSockets: 1,
        mediaProofRandomBytes: (_) => throw StateError('entropy unavailable'),
      );
      final result = await server.startServer(0);
      expect(result.isSuccess, isTrue);
      port = result.port;
      final token = tokens.issue(
        route: '/audio',
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now(),
      );
      final uri = _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: token,
      );

      expect(await _upgradeStatus(uri), HttpStatus.internalServerError);
      expect(server.debugProvisionalMediaSocketCount, 0);
      expect(tokens.length, 1);
      await server
          .closeGracefully(closeServer: true, forceServerClose: true)
          .timeout(const Duration(seconds: 1));
    },
  );

  test(
    'malformed expired and mismatched claims return 401 without reuse',
    () async {
      expect(
        await _upgradeStatus(
          _mediaUri(
            port,
            '/audio',
            sessionId: _audioSessionId,
            token: 'not-a-canonical-token',
          ),
        ),
        HttpStatus.unauthorized,
      );
      final expired = tokens.issue(
        route: '/audio',
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now().subtract(const Duration(seconds: 31)),
      );
      expect(
        await _upgradeStatus(
          _mediaUri(port, '/audio', sessionId: _audioSessionId, token: expired),
        ),
        HttpStatus.unauthorized,
      );

      final token = tokens.issue(
        route: '/audio',
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now(),
      );
      expect(
        await _upgradeStatus(
          _mediaUri(port, '/input', sessionId: _audioSessionId, token: token),
        ),
        HttpStatus.unauthorized,
      );
      expect(
        await _upgradeStatus(
          _mediaUri(
            port,
            '/audio',
            sessionId: _otherAudioSessionId,
            token: token,
          ),
        ),
        HttpStatus.unauthorized,
      );
      final validUri = _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: token,
      );
      final duplicatedTokenUri = Uri.parse(
        '${validUri.toString()}&token=$token',
      );
      expect(await _upgradeStatus(duplicatedTokenUri), HttpStatus.unauthorized);

      final socket = await _connectMediaChannel(
        validUri,
        namespace: 'audio-group',
      );
      await socket.sink.close();
      expect(await _upgradeStatus(validUri), HttpStatus.unauthorized);
    },
  );

  test(
    'audio claim attaches once and authenticates before packet decode',
    () async {
      final delivered = Completer<AudioGroupPacketFrame>();
      audioManager.onGroupPacket = delivered.complete;
      final token = tokens.issue(
        route: '/audio',
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now(),
      );
      final uri = _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: token,
      );
      final transport = await AudioGroupWebSocketPacketTransport.connect(
        uri,
        mediaMacKey: _mediaKey,
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
      );
      await transport.send(_groupPacket(<int>[1, 2, 3]));

      expect(
        (await delivered.future.timeout(const Duration(seconds: 2))).payload,
        <int>[1, 2, 3],
      );
      expect(await _upgradeStatus(uri), HttpStatus.unauthorized);
      await transport.close();
    },
  );

  test(
    'input claim attaches once and decrypts the route-specific packet',
    () async {
      final delivered = Completer<RemoteInputPacketFrame>();
      inputManager.onPacket = delivered.complete;
      final token = tokens.issue(
        route: '/input',
        sessionId: _inputSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now(),
      );
      final uri = _mediaUri(
        port,
        '/input',
        sessionId: _inputSessionId,
        token: token,
      );
      final transport = await RemoteInputWebSocketPacketTransport.connect(
        uri,
        mediaMacKey: _mediaKey,
        accept: const RemoteInputControlMessage(
          action: RemoteInputControlAction.accept,
          sessionId: _inputSessionId,
          sourcePeerId: _sourcePeerId,
          sinkPeerId: _sinkPeerId,
        ),
      );
      transport.send(
        RemoteInputPacketFrame(
          sessionId: _inputSessionId,
          sequence: 1,
          timestampMicros: 10,
          eventType: RemoteInputEventType.key,
          payload: Uint8List.fromList(<int>[4, 5]),
        ),
      );

      expect(
        (await delivered.future.timeout(const Duration(seconds: 2))).payload,
        <int>[4, 5],
      );
      await transport.close();
    },
  );

  test('claim whose peer or session is not active never attaches', () async {
    final token = tokens.issue(
      route: '/audio',
      sessionId: '33333333-3333-4333-8333-333333333333',
      peerId: 'other-peer',
      mediaMacKey: _mediaKey,
      now: DateTime.now(),
    );
    final uri = _mediaUri(
      port,
      '/audio',
      sessionId: '33333333-3333-4333-8333-333333333333',
      token: token,
    );

    expect(await _upgradeStatus(uri), HttpStatus.unauthorized);
    expect(audioManager.activeChannelCount, 0);
  });

  test('audio group claim binds the inner session and source peer', () async {
    allowAudioGroupClaim = true;
    final delivered = Completer<AudioGroupPacketFrame>();
    audioManager.onGroupPacket = delivered.complete;
    final token = tokens.issue(
      route: '/audio',
      namespace: 'audio-group',
      sessionId: _audioGroupSessionId,
      peerId: _sourcePeerId,
      mediaMacKey: _mediaKey,
      now: DateTime.now(),
    );
    final transport = await AudioGroupWebSocketPacketTransport.connect(
      _mediaUri(port, '/audio', sessionId: _audioGroupSessionId, token: token),
      mediaMacKey: _mediaKey,
      sessionId: _audioGroupSessionId,
      peerId: _sourcePeerId,
    );
    await transport.send(
      AudioGroupPacketFrame(
        groupId: 'group-a',
        streamId: 'stream-a',
        sessionId: _audioGroupSessionId,
        sourcePeerId: _sourcePeerId,
        sequence: 1,
        captureTimeMicros: 10,
        targetPlaybackTimeMicros: 20,
        durationMicros: 20000,
        channelMask: AudioChannelMask.stereo,
        payload: Uint8List.fromList(<int>[6, 7]),
      ),
    );

    final packet = await delivered.future.timeout(const Duration(seconds: 2));
    expect(packet.sessionId, _audioGroupSessionId);
    expect(packet.sourcePeerId, _sourcePeerId);
    await transport.close();
  });

  for (final mismatch
      in const <({String name, String groupId, String streamId})>[
        (name: 'group id', groupId: 'wrong-group', streamId: 'stream-a'),
        (name: 'stream id', groupId: 'group-a', streamId: 'wrong-stream'),
      ]) {
    test('audio group claim rejects a mismatched ${mismatch.name}', () async {
      allowAudioGroupClaim = true;
      final outcome = Completer<String>();
      audioManager.onGroupPacket = (_) {
        if (!outcome.isCompleted) {
          outcome.complete('delivered');
        }
      };
      final token = tokens.issue(
        route: '/audio',
        namespace: 'audio-group',
        sessionId: _audioGroupSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now(),
      );
      final socket = await _connectMediaChannel(
        _mediaUri(
          port,
          '/audio',
          sessionId: _audioGroupSessionId,
          token: token,
        ),
        namespace: 'audio-group',
      );
      socket.stream.listen((_) {}).asFuture<void>().then((_) {
        if (!outcome.isCompleted) {
          outcome.complete('closed');
        }
      });
      socket.sink.add(
        AuthenticatedMediaPacketEncoder(
          route: '/audio',
          sessionId: _audioGroupSessionId,
          mediaMacKey: _mediaKey,
          channelBinding: _mediaChannelBinding(token),
          maxPayloadBytes: AudioShareManager.maxPacketPayloadBytes,
        ).encode(
          AudioGroupPacketFrame(
            groupId: mismatch.groupId,
            streamId: mismatch.streamId,
            sessionId: _audioGroupSessionId,
            sourcePeerId: _sourcePeerId,
            sequence: 1,
            captureTimeMicros: 10,
            targetPlaybackTimeMicros: 20,
            durationMicros: 20000,
            channelMask: AudioChannelMask.stereo,
            payload: Uint8List.fromList(<int>[1]),
          ).encode(),
        ),
      );

      expect(
        await outcome.future.timeout(const Duration(seconds: 2)),
        'closed',
      );
    });
  }

  test('terminal audio session closes its already upgraded channel', () async {
    final token = tokens.issue(
      route: '/audio',
      sessionId: _audioSessionId,
      peerId: _sourcePeerId,
      mediaMacKey: _mediaKey,
      now: DateTime.now(),
    );
    final socket = await _connectMediaChannel(
      _mediaUri(port, '/audio', sessionId: _audioSessionId, token: token),
      namespace: 'audio-group',
    );
    final closed = socket.stream.listen((_) {}).asFuture<void>();
    await _waitFor(() => audioManager.activeChannelCount == 1);

    await audioManager.closeSessionChannels(
      _audioSessionId,
      namespace: 'audio-group',
    );

    await closed.timeout(const Duration(seconds: 2));
    expect(audioManager.activeChannelCount, 0);
  });

  test('terminal input session closes its already upgraded channel', () async {
    final token = tokens.issue(
      route: '/input',
      sessionId: _inputSessionId,
      peerId: _sourcePeerId,
      mediaMacKey: _mediaKey,
      now: DateTime.now(),
    );
    final socket = await _connectMediaChannel(
      _mediaUri(port, '/input', sessionId: _inputSessionId, token: token),
      namespace: 'remote-input',
    );
    final closed = socket.stream.listen((_) {}).asFuture<void>();
    await _waitFor(() => inputManager.activeChannelCount == 1);

    inputManager.stopSession(_inputSessionId);

    await closed.timeout(const Duration(seconds: 2));
    expect(inputManager.activeChannelCount, 0);
  });

  test('one active claim tuple cannot accumulate duplicate channels', () async {
    Uri issueUri() {
      final token = tokens.issue(
        route: '/audio',
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now(),
      );
      return _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: token,
      );
    }

    final first = await _connectMediaChannel(
      issueUri(),
      namespace: 'audio-group',
    );
    await _waitFor(() => audioManager.activeChannelCount == 1);
    final duplicate = await WebSocket.connect(issueUri().toString())
        .then<Object>((socket) async {
          await socket.close();
          return socket;
        })
        .catchError((Object error) => error);

    expect(duplicate, isA<WebSocketException>());
    expect(audioManager.activeChannelCount, 1);
    await first.sink.close();
  });

  test('peer disconnect closes every claimed media channel', () async {
    String issue(String route, String sessionId) {
      return tokens.issue(
        route: route,
        sessionId: sessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now(),
      );
    }

    final audio = await _connectMediaChannel(
      _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: issue('/audio', _audioSessionId),
      ),
      namespace: 'audio-group',
    );
    final input = await _connectMediaChannel(
      _mediaUri(
        port,
        '/input',
        sessionId: _inputSessionId,
        token: issue('/input', _inputSessionId),
      ),
      namespace: 'remote-input',
    );
    final audioClosed = audio.stream.listen((_) {}).asFuture<void>();
    final inputClosed = input.stream.listen((_) {}).asFuture<void>();
    await _waitFor(
      () =>
          audioManager.activeChannelCount == 1 &&
          inputManager.activeChannelCount == 1,
    );

    await Future.wait(<Future<void>>[
      audioManager.closePeerChannels(_sourcePeerId),
      inputManager.closePeerChannels(_sourcePeerId),
    ]);

    await Future.wait(<Future<void>>[
      audioClosed,
      inputClosed,
    ]).timeout(const Duration(seconds: 2));
    expect(audioManager.activeChannelCount, 0);
    expect(inputManager.activeChannelCount, 0);
  });

  test(
    'tampered authenticated packet closes without protocol side effects',
    () async {
      final delivered = <AudioGroupPacketFrame>[];
      audioManager.onGroupPacket = delivered.add;
      final token = tokens.issue(
        route: '/audio',
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
        mediaMacKey: _mediaKey,
        now: DateTime.now(),
      );
      final uri = _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: token,
      );
      final socket = await _connectMediaChannel(uri, namespace: 'audio-group');
      final closed = socket.stream.listen((_) {}).asFuture<void>();
      final encoded = AuthenticatedMediaPacketEncoder(
        route: '/audio',
        namespace: 'audio-group',
        sessionId: _audioSessionId,
        mediaMacKey: _mediaKey,
        channelBinding: _mediaChannelBinding(token),
        maxPayloadBytes: AudioShareManager.maxPacketPayloadBytes,
      ).encode(_groupPacket(<int>[1]).encode());
      encoded.last ^= 0xff;
      socket.sink.add(encoded);

      await closed.timeout(const Duration(seconds: 2));
      expect(delivered, isEmpty);
      expect(audioManager.activeChannelCount, 0);
    },
  );

  test('input envelope cannot target another active inner session', () async {
    inputManager.acceptOffer(
      const RemoteInputControlMessage(
        action: RemoteInputControlAction.offer,
        sessionId: _otherInputSessionId,
        sourcePeerId: 'other-peer',
        sinkPeerId: _sinkPeerId,
        layoutEdge: RemoteInputEdge.left,
      ),
    );
    final outcome = Completer<String>();
    inputManager.onPacket = (_) {
      if (!outcome.isCompleted) {
        outcome.complete('delivered');
      }
    };
    final token = tokens.issue(
      route: '/input',
      sessionId: _inputSessionId,
      peerId: _sourcePeerId,
      mediaMacKey: _mediaKey,
      now: DateTime.now(),
    );
    final socket = await _connectMediaChannel(
      _mediaUri(port, '/input', sessionId: _inputSessionId, token: token),
      namespace: 'remote-input',
    );
    socket.stream.listen((_) {}).asFuture<void>().then((_) {
      if (!outcome.isCompleted) {
        outcome.complete('closed');
      }
    });
    socket.sink.add(
      AuthenticatedMediaPacketEncoder(
        route: '/input',
        sessionId: _inputSessionId,
        mediaMacKey: _mediaKey,
        channelBinding: _mediaChannelBinding(token),
        maxPayloadBytes: RemoteInputManager.maxPacketPayloadBytes,
      ).encode(
        RemoteInputPacketFrame(
          sessionId: _otherInputSessionId,
          sequence: 1,
          timestampMicros: 10,
          eventType: RemoteInputEventType.key,
          payload: Uint8List.fromList(<int>[1]),
        ).encode(),
      ),
    );

    expect(await outcome.future.timeout(const Duration(seconds: 2)), 'closed');
  });
}
