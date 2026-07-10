import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
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

Future<int> _upgradeStatus(
  Uri uri, {
  String? origin,
}) async {
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

Uri _mediaUri(
  int port,
  String route, {
  String? sessionId,
  String? token,
}) {
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

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late SessionUpgradeTokenRegistry tokens;
  late AudioShareManager audioManager;
  late RemoteInputManager inputManager;
  late WsSvrManager server;
  late int port;
  late bool allowAudioGroupClaim;

  setUp(() async {
    tokens = SessionUpgradeTokenRegistry();
    allowAudioGroupClaim = false;
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
      mediaPeerClaimValidator: (_) => true,
    );
    final result = await server.startServer(0);
    expect(result.isSuccess, isTrue);
    port = result.port;
  });

  tearDown(() async {
    await server.closeGracefully(closeServer: true, forceServerClose: true);
  });

  test('missing token is 401 and a non-empty Origin is 403 before consume',
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
    final socket = await WebSocket.connect(uri.toString());
    await socket.close();
  });

  test('malformed expired and mismatched claims return 401 without reuse',
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
        _mediaUri(
          port,
          '/audio',
          sessionId: _audioSessionId,
          token: expired,
        ),
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
        _mediaUri(
          port,
          '/input',
          sessionId: _audioSessionId,
          token: token,
        ),
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
    expect(
      await _upgradeStatus(duplicatedTokenUri),
      HttpStatus.unauthorized,
    );

    final socket = await WebSocket.connect(validUri.toString());
    await socket.close();
    expect(await _upgradeStatus(validUri), HttpStatus.unauthorized);
  });

  test('audio claim attaches once and authenticates before packet decode',
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
    final socket = await WebSocket.connect(uri.toString());
    final encoder = AuthenticatedMediaPacketEncoder(
      route: '/audio',
      sessionId: _audioSessionId,
      mediaMacKey: _mediaKey,
      maxPayloadBytes: AudioShareManager.maxPacketPayloadBytes,
    );
    socket.add(
      encoder.encode(
        AudioPacketFrame(
          sessionId: _audioSessionId,
          sequence: 1,
          captureTimeMicros: 10,
          payload: Uint8List.fromList(<int>[1, 2, 3]),
        ).encode(),
      ),
    );

    expect(
      (await delivered.future.timeout(const Duration(seconds: 2))).payload,
      <int>[1, 2, 3],
    );
    expect(await _upgradeStatus(uri), HttpStatus.unauthorized);
    await socket.close();
  });

  test('input claim attaches once and verifies the route-specific packet MAC',
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
    final socket = await WebSocket.connect(uri.toString());
    final encoder = AuthenticatedMediaPacketEncoder(
      route: '/input',
      sessionId: _inputSessionId,
      mediaMacKey: _mediaKey,
      maxPayloadBytes: RemoteInputManager.maxPacketPayloadBytes,
    );
    socket.add(
      encoder.encode(
        RemoteInputPacketFrame(
          sessionId: _inputSessionId,
          sequence: 1,
          timestampMicros: 10,
          eventType: RemoteInputEventType.key,
          payload: Uint8List.fromList(<int>[4, 5]),
        ).encode(),
      ),
    );

    expect(
      (await delivered.future.timeout(const Duration(seconds: 2))).payload,
      <int>[4, 5],
    );
    await socket.close();
  });

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
    final socket = await WebSocket.connect(
      _mediaUri(
        port,
        '/audio',
        sessionId: _audioGroupSessionId,
        token: token,
      ).toString(),
    );
    socket.add(
      AuthenticatedMediaPacketEncoder(
        route: '/audio',
        sessionId: _audioGroupSessionId,
        mediaMacKey: _mediaKey,
        maxPayloadBytes: AudioShareManager.maxPacketPayloadBytes,
      ).encode(
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
        ).encode(),
      ),
    );

    final packet = await delivered.future.timeout(const Duration(seconds: 2));
    expect(packet.sessionId, _audioGroupSessionId);
    expect(packet.sourcePeerId, _sourcePeerId);
    await socket.close();
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
      final socket = await WebSocket.connect(
        _mediaUri(
          port,
          '/audio',
          sessionId: _audioGroupSessionId,
          token: token,
        ).toString(),
      );
      socket.listen((_) {}).asFuture<void>().then((_) {
        if (!outcome.isCompleted) {
          outcome.complete('closed');
        }
      });
      socket.add(
        AuthenticatedMediaPacketEncoder(
          route: '/audio',
          sessionId: _audioGroupSessionId,
          mediaMacKey: _mediaKey,
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
    final socket = await WebSocket.connect(
      _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: token,
      ).toString(),
    );
    final closed = socket.listen((_) {}).asFuture<void>();
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
    final socket = await WebSocket.connect(
      _mediaUri(
        port,
        '/input',
        sessionId: _inputSessionId,
        token: token,
      ).toString(),
    );
    final closed = socket.listen((_) {}).asFuture<void>();
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

    final first = await WebSocket.connect(issueUri().toString());
    await _waitFor(() => audioManager.activeChannelCount == 1);
    final duplicate = await WebSocket.connect(issueUri().toString())
        .then<Object>((socket) async {
      await socket.close();
      return socket;
    }).catchError((Object error) => error);

    expect(duplicate, isA<WebSocketException>());
    expect(audioManager.activeChannelCount, 1);
    await first.close();
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

    final audio = await WebSocket.connect(
      _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: issue('/audio', _audioSessionId),
      ).toString(),
    );
    final input = await WebSocket.connect(
      _mediaUri(
        port,
        '/input',
        sessionId: _inputSessionId,
        token: issue('/input', _inputSessionId),
      ).toString(),
    );
    final audioClosed = audio.listen((_) {}).asFuture<void>();
    final inputClosed = input.listen((_) {}).asFuture<void>();
    await _waitFor(() =>
        audioManager.activeChannelCount == 1 &&
        inputManager.activeChannelCount == 1);

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

  test('tampered authenticated packet closes without protocol side effects',
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
    final socket = await WebSocket.connect(uri.toString());
    final closed = socket.listen((_) {}).asFuture<void>();
    final encoded = AuthenticatedMediaPacketEncoder(
      route: '/audio',
      sessionId: _audioSessionId,
      mediaMacKey: _mediaKey,
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
    socket.add(encoded);

    await closed.timeout(const Duration(seconds: 2));
    expect(delivered, isEmpty);
    expect(audioManager.activeChannelCount, 0);
  });

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
    final socket = await WebSocket.connect(
      _mediaUri(
        port,
        '/audio',
        sessionId: _audioSessionId,
        token: token,
      ).toString(),
    );
    socket.listen((_) {}).asFuture<void>().then((_) {
      if (!outcome.isCompleted) {
        outcome.complete('closed');
      }
    });
    socket.add(
      AuthenticatedMediaPacketEncoder(
        route: '/audio',
        sessionId: _audioSessionId,
        mediaMacKey: _mediaKey,
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

    expect(
      await outcome.future.timeout(const Duration(seconds: 2)),
      'closed',
    );
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
    final socket = await WebSocket.connect(
      _mediaUri(
        port,
        '/input',
        sessionId: _inputSessionId,
        token: token,
      ).toString(),
    );
    socket.listen((_) {}).asFuture<void>().then((_) {
      if (!outcome.isCompleted) {
        outcome.complete('closed');
      }
    });
    socket.add(
      AuthenticatedMediaPacketEncoder(
        route: '/input',
        sessionId: _inputSessionId,
        mediaMacKey: _mediaKey,
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

    expect(
      await outcome.future.timeout(const Duration(seconds: 2)),
      'closed',
    );
  });
}
