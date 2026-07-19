import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_fanout_transport.dart';
import 'package:whisper/audio/audio_packet_transport.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/media_upgrade_proof.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/socket/svrmanager.dart';

const _audioSessionId = '11111111-1111-4111-8111-111111111111';
const _inputSessionId = '22222222-2222-4222-8222-222222222222';
const _otherAudioSessionId = '33333333-3333-4333-8333-333333333333';
const _otherInputSessionId = '44444444-4444-4444-8444-444444444444';
const _audioGroupSessionId = '55555555-5555-4555-8555-555555555555';
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
  test('destroyed media upgrade context cannot expose a zeroed key', () {
    final context = MediaUpgradeClientContext(
      namespace: 'audio',
      sessionId: _audioSessionId,
      peerId: _sourcePeerId,
      mediaMacKey: _mediaKey,
    );

    context.destroy();

    expect(() => context.withMediaMacKey<void>((_) {}), throwsStateError);
  });

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
    audioManager.acceptOffer(
      const AudioControlMessage(
        action: AudioControlAction.offer,
        sessionId: _audioSessionId,
        sourcePeerId: _sourcePeerId,
        sinkPeerId: _sinkPeerId,
        format: AudioStreamFormat(
          codec: AudioCodecKind.opus,
          sampleRate: 48000,
          channels: 2,
          frameDurationMs: 20,
          bitRate: 128000,
        ),
        path: '/audio',
      ),
    );
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
      audioGroupClaimValidator: (claim) =>
          allowAudioGroupClaim &&
          claim.sessionId == _audioGroupSessionId &&
          claim.peerId == _sourcePeerId,
      audioGroupPacketValidator: (claim, packet) =>
          allowAudioGroupClaim &&
          claim.sessionId == _audioGroupSessionId &&
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
      final socket = await _connectMediaChannel(uri, namespace: 'audio');
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

      final valid = await _connectMediaChannel(uri, namespace: 'audio');
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
      final valid = await _connectMediaChannel(uri, namespace: 'audio');
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

      final valid = await _connectMediaChannel(secondUri, namespace: 'audio');
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

      final socket = await _connectMediaChannel(validUri, namespace: 'audio');
      await socket.sink.close();
      expect(await _upgradeStatus(validUri), HttpStatus.unauthorized);
    },
  );

  test(
    'audio claim attaches once and authenticates before packet decode',
    () async {
      final delivered = Completer<AudioPacketFrame>();
      audioManager.onPacket = delivered.complete;
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
      final transport = await AudioWebSocketPacketTransport.connect(
        uri,
        mediaMacKey: _mediaKey,
        sessionId: _audioSessionId,
        peerId: _sourcePeerId,
      );
      transport.send(
        AudioPacketFrame(
          sessionId: _audioSessionId,
          sequence: 1,
          captureTimeMicros: 10,
          payload: Uint8List.fromList(<int>[1, 2, 3]),
        ),
      );

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
        sessionId: _inputSessionId,
        peerId: _sourcePeerId,
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
      namespace: 'audio',
    );
    final closed = socket.stream.listen((_) {}).asFuture<void>();
    await _waitFor(() => audioManager.activeChannelCount == 1);

    audioManager.stopSession(_audioSessionId);

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

    final first = await _connectMediaChannel(issueUri(), namespace: 'audio');
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
      namespace: 'audio',
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
      final delivered = <AudioPacketFrame>[];
      audioManager.onPacket = delivered.add;
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
      final socket = await _connectMediaChannel(uri, namespace: 'audio');
      final closed = socket.stream.listen((_) {}).asFuture<void>();
      final encoded =
          AuthenticatedMediaPacketEncoder(
            route: '/audio',
            sessionId: _audioSessionId,
            mediaMacKey: _mediaKey,
            channelBinding: _mediaChannelBinding(token),
            maxPayloadBytes: AudioShareManager.maxPacketPayloadBytes,
          ).encode(
            AudioPacketFrame(
              sessionId: _audioSessionId,
              sequence: 1,
              captureTimeMicros: 10,
              payload: Uint8List.fromList(<int>[1]),
            ).encode(),
          );
      encoded.last ^= 0xff;
      socket.sink.add(encoded);

      await closed.timeout(const Duration(seconds: 2));
      expect(delivered, isEmpty);
      expect(audioManager.activeChannelCount, 0);
    },
  );

  test('audio envelope cannot target another active inner session', () async {
    audioManager.acceptOffer(
      const AudioControlMessage(
        action: AudioControlAction.offer,
        sessionId: _otherAudioSessionId,
        sourcePeerId: 'other-peer',
        sinkPeerId: _sinkPeerId,
        format: AudioStreamFormat(
          codec: AudioCodecKind.opus,
          sampleRate: 48000,
          channels: 2,
          frameDurationMs: 20,
          bitRate: 128000,
        ),
      ),
    );
    final outcome = Completer<String>();
    audioManager.onPacket = (_) {
      if (!outcome.isCompleted) {
        outcome.complete('delivered');
      }
    };
    final token = tokens.issue(
      route: '/audio',
      sessionId: _audioSessionId,
      peerId: _sourcePeerId,
      mediaMacKey: _mediaKey,
      now: DateTime.now(),
    );
    final socket = await _connectMediaChannel(
      _mediaUri(port, '/audio', sessionId: _audioSessionId, token: token),
      namespace: 'audio',
    );
    socket.stream.listen((_) {}).asFuture<void>().then((_) {
      if (!outcome.isCompleted) {
        outcome.complete('closed');
      }
    });
    socket.sink.add(
      AuthenticatedMediaPacketEncoder(
        route: '/audio',
        sessionId: _audioSessionId,
        mediaMacKey: _mediaKey,
        channelBinding: _mediaChannelBinding(token),
        maxPayloadBytes: AudioShareManager.maxPacketPayloadBytes,
      ).encode(
        AudioPacketFrame(
          sessionId: _otherAudioSessionId,
          sequence: 1,
          captureTimeMicros: 10,
          payload: Uint8List.fromList(<int>[1]),
        ).encode(),
      ),
    );

    expect(await outcome.future.timeout(const Duration(seconds: 2)), 'closed');
  });

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
