import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/media_upgrade_proof.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/socket/socket_admission.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/peer_endpoint.dart';

const _audioSessionId = '11111111-1111-4111-8111-111111111111';
const _inputSessionId = '22222222-2222-4222-8222-222222222222';
const _sourcePeerId = 'source-peer';
const _sinkPeerId = 'sink-peer';
final _mediaKey = Uint8List.fromList(
  List<int>.generate(32, (index) => index + 1),
);

ConnectionAttemptRequest _attemptRequest(String requestId, int port) =>
    ConnectionAttemptRequest(
      requestId: requestId,
      endpoint: PeerEndpoint.loopbackForTesting(port: port),
      mode: ConnectionAttemptMode.interactive,
    );

void _activateAudioSession(AudioShareManager manager) {
  manager.acceptOffer(
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
    ),
  );
}

void _activateInputSession(RemoteInputManager manager) {
  manager.acceptOffer(
    const RemoteInputControlMessage(
      action: RemoteInputControlAction.offer,
      sessionId: _inputSessionId,
      sourcePeerId: _sourcePeerId,
      sinkPeerId: _sinkPeerId,
      layoutEdge: RemoteInputEdge.right,
    ),
  );
}

Uri _authorizedMediaUri({
  required int port,
  required String route,
  required String sessionId,
  required SessionUpgradeTokenRegistry tokens,
}) {
  final token = tokens.issue(
    route: route,
    sessionId: sessionId,
    peerId: _sourcePeerId,
    mediaMacKey: _mediaKey,
    now: DateTime.now(),
  );
  return buildPeerPacketUri(
    host: '127.0.0.1',
    port: port,
    path: route,
    queryParameters: <String, String>{
      'session': sessionId,
      'token': token,
    },
  );
}

Future<WebSocketChannel> _connectAuthorizedMedia({
  required Uri uri,
  required String namespace,
}) async {
  WebSocketChannel channel = IOWebSocketChannel.connect(uri);
  await channel.ready;
  return authenticateMediaWebSocketClient(
    channel,
    uri: uri,
    route: uri.path,
    namespace: namespace,
    sessionId: uri.queryParameters['session']!,
    peerId: _sourcePeerId,
    mediaMacKey: _mediaKey,
  );
}

final class _BlockingAudioManager extends AudioShareManager {
  final Completer<void> closeStarted = Completer<void>();
  final Completer<void> releaseClose = Completer<void>();
  bool _shouldBlock = true;
  bool _armed = false;

  void arm() => _armed = true;

  @override
  Future<void> closeChannels() async {
    if (_armed && _shouldBlock) {
      _shouldBlock = false;
      closeStarted.complete();
      await releaseClose.future;
    }
    await super.closeChannels();
  }
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

Future<int> _upgradeStatus(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri.replace(scheme: 'http'));
    request.headers
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('Sec-WebSocket-Version', '13')
      ..set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==');
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<int> _rawUpgradeStatus({
  required int port,
  required String path,
  required String origin,
}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  try {
    socket.write(
      'GET $path HTTP/1.1\r\n'
      'Host: 127.0.0.1:$port\r\n'
      'Connection: Upgrade\r\n'
      'Upgrade: websocket\r\n'
      'Sec-WebSocket-Version: 13\r\n'
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
      'Origin: $origin\r\n'
      '\r\n',
    );
    await socket.flush();
    final statusLine = await utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 2));
    return int.parse(statusLine.split(' ')[1]);
  } finally {
    socket.destroy();
  }
}

void main() {
  final manager = WsSvrManager();

  tearDown(() async {
    await manager.closeGracefully(closeServer: true, forceServerClose: true);
  });

  test('routes only explicit websocket endpoints with strict HTTP policy',
      () async {
    final started = await manager.startServer(0);
    expect(started.isSuccess, isTrue);
    expect(started.port, greaterThan(0));

    final client = HttpClient();
    Future<HttpClientResponse> request(
      String method,
      String path, {
      Map<String, String> headers = const {},
    }) async {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${started.port}$path'),
      );
      headers.forEach(request.headers.set);
      return request.close();
    }

    expect((await request('GET', '/missing')).statusCode, 404);
    expect(
      (await request('GET', '/missing', headers: {
        'Connection': 'Upgrade',
        'Upgrade': 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==',
      }))
          .statusCode,
      404,
    );
    expect((await request('POST', '/chat')).statusCode, 400);
    expect((await request('GET', '/chat')).statusCode, 400);
    for (final path in const <String>['/chat', '/audio', '/input']) {
      expect(
        (await request('GET', path, headers: {
          'Connection': 'Upgrade',
          'Upgrade': 'websocket',
          'Sec-WebSocket-Version': '13',
          'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==',
          'Origin': 'https://example.invalid',
        }))
            .statusCode,
        403,
      );
      expect(
        await _rawUpgradeStatus(
          port: started.port,
          path: path,
          origin: '',
        ),
        path == '/chat' ? HttpStatus.forbidden : HttpStatus.unauthorized,
      );
      expect(
        await _rawUpgradeStatus(
          port: started.port,
          path: path,
          origin: '   ',
        ),
        path == '/chat' ? HttpStatus.forbidden : HttpStatus.unauthorized,
      );
    }
    expect(
      (await request('GET', '/chat', headers: {
        'Connection': 'Upgrade',
        'Upgrade': 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': 'malformed',
      }))
          .statusCode,
      400,
    );
    client.close(force: true);
  });

  test('starting again awaits old server and reports the actual port',
      () async {
    final first = await manager.startServer(0);
    final second = await manager.startServer(0);
    expect(first.port, greaterThan(0));
    expect(second.port, greaterThan(0));

    final oldSocket = await Socket.connect('127.0.0.1', first.port)
        .then<Object>((value) async {
      await value.close();
      return value;
    }).catchError((Object error) => error);
    expect(oldSocket, isA<SocketException>());
  });

  test('concurrent graceful closes share one completion', () async {
    await manager.startServer(0);
    final first = manager.closeGracefully(closeServer: true);
    final second = manager.closeGracefully(closeServer: true);

    expect(identical(first, second), isTrue);
    await first;
    expect(manager.started, isFalse);
  });

  test('a concurrent stronger close request also closes the server', () async {
    final started = await manager.startServer(0);
    final first = manager.closeGracefully();
    final upgraded = manager.closeGracefully(closeServer: true);

    expect(identical(first, upgraded), isTrue);
    await first;
    expect(manager.started, isFalse);

    final connection = await Socket.connect('127.0.0.1', started.port)
        .then<Object>((socket) async {
      await socket.close();
      return socket;
    }).catchError((Object error) => error);
    expect(connection, isA<SocketException>());
  });

  test('audio and input share rate limits without consuming chat slots',
      () async {
    final admission = SocketAdmissionController(
      maxChatConnections: 1,
      maxPreAuthConnections: 1,
      maxPreAuthConnectionsPerIp: 1,
      maxUpgradeAttemptsPerMinutePerIp: 2,
    );
    final audioManager = AudioShareManager();
    final inputManager = RemoteInputManager();
    final tokens = SessionUpgradeTokenRegistry();
    _activateAudioSession(audioManager);
    _activateInputSession(inputManager);
    final isolated = WsSvrManager.forTesting(
      admission: admission,
      audioManager: audioManager,
      remoteInputManager: inputManager,
      sessionUpgradeTokens: tokens,
      audioGroupClaimValidator: (_) => false,
      mediaPeerClaimValidator: (_) => true,
    );
    addTearDown(() => isolated.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    final started = await isolated.startServer(0);
    final audio = await _connectAuthorizedMedia(
      uri: _authorizedMediaUri(
        port: started.port,
        route: '/audio',
        sessionId: _audioSessionId,
        tokens: tokens,
      ),
      namespace: 'audio',
    );
    final input = await _connectAuthorizedMedia(
      uri: _authorizedMediaUri(
        port: started.port,
        route: '/input',
        sessionId: _inputSessionId,
        tokens: tokens,
      ),
      namespace: 'remote-input',
    );
    addTearDown(audio.sink.close);
    addTearDown(input.sink.close);
    await _waitFor(() =>
        audioManager.activeChannelCount == 1 &&
        inputManager.activeChannelCount == 1);

    expect(admission.chatConnectionCount, 0);
    expect(admission.preAuthConnectionCount, 0);
    final rejected = await _upgradeStatus(
      Uri.parse('ws://127.0.0.1:${started.port}/chat'),
    );
    expect(rejected, HttpStatus.tooManyRequests);
  });

  test('manager-only media channels are awaited by graceful close', () async {
    final audioManager = AudioShareManager();
    final tokens = SessionUpgradeTokenRegistry();
    _activateAudioSession(audioManager);
    final isolated = WsSvrManager.forTesting(
      audioManager: audioManager,
      sessionUpgradeTokens: tokens,
      audioGroupClaimValidator: (_) => false,
      mediaPeerClaimValidator: (_) => true,
    );
    addTearDown(() => isolated.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    final started = await isolated.startServer(0);
    final audio = await _connectAuthorizedMedia(
      uri: _authorizedMediaUri(
        port: started.port,
        route: '/audio',
        sessionId: _audioSessionId,
        tokens: tokens,
      ),
      namespace: 'audio',
    );
    final remoteClosed = audio.stream.listen((_) {}).asFuture<void>();
    await _waitFor(() => audioManager.activeChannelCount == 1);

    await isolated.closeGracefully();

    expect(audioManager.activeChannelCount, 0);
    await remoteClosed.timeout(const Duration(seconds: 2));
    expect(isolated.started, isTrue);
  });

  test('audio and input routes close oversized binary packets', () async {
    expect(AudioShareManager.maxPacketPayloadBytes, 256 * 1024);
    expect(RemoteInputManager.maxPacketPayloadBytes, 64 * 1024);
    expect(
      AudioShareManager.maxChannelMessageBytes,
      256 * 1024 + AuthenticatedMediaPacketEnvelope.overheadBytes,
    );
    expect(
      RemoteInputManager.maxChannelMessageBytes,
      64 * 1024 + AuthenticatedMediaPacketEnvelope.overheadBytes,
    );
    final audioManager = AudioShareManager();
    final inputManager = RemoteInputManager();
    final tokens = SessionUpgradeTokenRegistry();
    _activateAudioSession(audioManager);
    _activateInputSession(inputManager);
    final isolated = WsSvrManager.forTesting(
      audioManager: audioManager,
      remoteInputManager: inputManager,
      sessionUpgradeTokens: tokens,
      audioGroupClaimValidator: (_) => false,
      mediaPeerClaimValidator: (_) => true,
    );
    addTearDown(() => isolated.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    final started = await isolated.startServer(0);

    final audio = await _connectAuthorizedMedia(
      uri: _authorizedMediaUri(
        port: started.port,
        route: '/audio',
        sessionId: _audioSessionId,
        tokens: tokens,
      ),
      namespace: 'audio',
    );
    final audioClosed = audio.stream.listen((_) {}).asFuture<void>();
    audio.sink.add(
      List<int>.filled(AudioShareManager.maxChannelMessageBytes + 1, 0),
    );
    await audioClosed.timeout(const Duration(seconds: 2));
    await _waitFor(() => audioManager.activeChannelCount == 0);

    final input = await _connectAuthorizedMedia(
      uri: _authorizedMediaUri(
        port: started.port,
        route: '/input',
        sessionId: _inputSessionId,
        tokens: tokens,
      ),
      namespace: 'remote-input',
    );
    final inputClosed = input.stream.listen((_) {}).asFuture<void>();
    input.sink.add(
      List<int>.filled(RemoteInputManager.maxChannelMessageBytes + 1, 0),
    );
    await inputClosed.timeout(const Duration(seconds: 2));
    await _waitFor(() => inputManager.activeChannelCount == 0);
  });

  test('start followed immediately by close finishes stopped', () async {
    final isolated = WsSvrManager.forTesting();
    addTearDown(() => isolated.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));

    final starting = isolated.startServer(0);
    final closing = isolated.closeGracefully(closeServer: true);
    final started = await starting;
    await closing;

    expect(started.isSuccess, isTrue);
    expect(isolated.started, isFalse);
    final connection = await Socket.connect('127.0.0.1', started.port)
        .then<Object>((socket) async {
      await socket.close();
      return socket;
    }).catchError((Object error) => error);
    expect(connection, isA<SocketException>());
  });

  test('close followed immediately by start finishes started', () async {
    final isolated = WsSvrManager.forTesting();
    addTearDown(() => isolated.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    await isolated.startServer(0);

    final closing = isolated.closeGracefully(closeServer: true);
    final restarting = isolated.startServer(0);
    await closing;
    final restarted = await restarting;

    expect(restarted.isSuccess, isTrue);
    expect(isolated.started, isTrue);
    final socket = await Socket.connect('127.0.0.1', restarted.port);
    await socket.close();
  });

  test('server stops accepting before existing channel cleanup completes',
      () async {
    final audioManager = _BlockingAudioManager();
    final tokens = SessionUpgradeTokenRegistry();
    _activateAudioSession(audioManager);
    final isolated = WsSvrManager.forTesting(
      audioManager: audioManager,
      sessionUpgradeTokens: tokens,
      audioGroupClaimValidator: (_) => false,
      mediaPeerClaimValidator: (_) => true,
    );
    addTearDown(() {
      if (!audioManager.releaseClose.isCompleted) {
        audioManager.releaseClose.complete();
      }
      return isolated.closeGracefully(
        closeServer: true,
        forceServerClose: true,
      );
    });
    final started = await isolated.startServer(0);
    audioManager.arm();

    final closing = isolated.closeGracefully(closeServer: true);
    await audioManager.closeStarted.future;
    final connection = await Socket.connect('127.0.0.1', started.port)
        .then<Object>((socket) async {
      await socket.close();
      return socket;
    }).catchError((Object error) => error);

    expect(connection, isA<SocketException>());
    audioManager.releaseClose.complete();
    await closing;
  });

  test('retained server rejects upgrades while closing and reopens after',
      () async {
    final audioManager = _BlockingAudioManager();
    final tokens = SessionUpgradeTokenRegistry();
    _activateAudioSession(audioManager);
    final isolated = WsSvrManager.forTesting(
      audioManager: audioManager,
      sessionUpgradeTokens: tokens,
      audioGroupClaimValidator: (_) => false,
      mediaPeerClaimValidator: (_) => true,
    );
    addTearDown(() {
      if (!audioManager.releaseClose.isCompleted) {
        audioManager.releaseClose.complete();
      }
      return isolated.closeGracefully(
        closeServer: true,
        forceServerClose: true,
      );
    });
    final started = await isolated.startServer(0);
    final existing = await _connectAuthorizedMedia(
      uri: _authorizedMediaUri(
        port: started.port,
        route: '/audio',
        sessionId: _audioSessionId,
        tokens: tokens,
      ),
      namespace: 'audio',
    );
    final existingClosed = existing.stream.listen((_) {}).asFuture<void>();
    await _waitFor(() => audioManager.activeChannelCount == 1);
    audioManager.arm();

    final closing = isolated.closeGracefully();
    await audioManager.closeStarted.future;
    final rejected = await _upgradeStatus(
      Uri.parse('ws://127.0.0.1:${started.port}/audio'),
    );
    expect(rejected, HttpStatus.serviceUnavailable);

    audioManager.releaseClose.complete();
    await closing;
    await existingClosed.timeout(const Duration(seconds: 2));
    final reopened = await _connectAuthorizedMedia(
      uri: _authorizedMediaUri(
        port: started.port,
        route: '/audio',
        sessionId: _audioSessionId,
        tokens: tokens,
      ),
      namespace: 'audio',
    );
    await reopened.sink.close();
  });

  test('graceful close cancels and awaits an in-flight outgoing handshake',
      () async {
    final stalledServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => stalledServer.close(force: true));
    final requestReceived = Completer<void>();
    stalledServer.listen((request) {
      if (!requestReceived.isCompleted) {
        requestReceived.complete();
      }
    });
    final isolated = WsSvrManager.forTesting();
    addTearDown(() => isolated.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    final connecting = isolated.connectToServer(
      _attemptRequest('graceful-close', stalledServer.port),
    );
    await requestReceived.future;
    final closing = isolated.closeGracefully();

    final result = await connecting.timeout(const Duration(seconds: 2));
    await closing.timeout(const Duration(seconds: 2));
    expect(result.status, ConnectionAttemptStatus.cancelled);
  });

  test('failed listener bind leaves outgoing connector available', () async {
    final occupied = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    addTearDown(() => occupied.close(force: true));
    final peerServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => peerServer.close(force: true));
    final upgraded = Completer<void>();
    peerServer.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      upgraded.complete();
      await socket.close();
    });
    final isolated = WsSvrManager.forTesting();
    addTearDown(() => isolated.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    final failedStart = await isolated.startServer(occupied.port);
    expect(failedStart.isSuccess, isFalse);
    final connecting = isolated.connectToServer(
      _attemptRequest('failed-bind', peerServer.port),
    );

    await upgraded.future.timeout(const Duration(seconds: 2));
    final result = await connecting.timeout(const Duration(seconds: 2));
    expect(result.isAuthenticated, isFalse);
  });

  test('typed outgoing result remains tracked through shutdown', () async {
    final stalledServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => stalledServer.close(force: true));
    final requestReceived = Completer<void>();
    stalledServer.listen((request) {
      if (!requestReceived.isCompleted) {
        requestReceived.complete();
      }
    });
    final isolated = WsSvrManager.forTesting();
    addTearDown(() => isolated.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    final connecting = isolated.connectToServer(
      _attemptRequest('tracked-close', stalledServer.port),
    );
    await requestReceived.future;

    final closing = isolated.closeGracefully();

    final result = await connecting.timeout(const Duration(seconds: 2));
    await closing.timeout(const Duration(seconds: 2));
    expect(result.status, ConnectionAttemptStatus.cancelled);
  });

  test('outgoing websocket handshake does not follow redirects', () async {
    final targetServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => targetServer.close(force: true));
    var targetReached = false;
    targetServer.listen((request) async {
      targetReached = true;
      final socket = await WebSocketTransformer.upgrade(request);
      await socket.close();
    });
    final redirectServer =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => redirectServer.close(force: true));
    redirectServer.listen((request) async {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${targetServer.port}/chat',
        );
      await request.response.close();
    });
    final isolated = WsSvrManager.forTesting();
    addTearDown(() => isolated.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));

    await isolated
        .connectToServer(
          _attemptRequest('redirect', redirectServer.port),
        )
        .timeout(const Duration(seconds: 2));

    expect(targetReached, isFalse);
  });

  test('outgoing websocket rejects unsolicited negotiation headers', () async {
    for (final header in const <MapEntry<String, String>>[
      MapEntry<String, String>('Sec-WebSocket-Protocol', 'unexpected'),
      MapEntry<String, String>(
        'Sec-WebSocket-Extensions',
        'permessage-deflate',
      ),
    ]) {
      final peerServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final responseSent = Completer<void>();
      peerServer.listen((request) async {
        final key = request.headers.value('Sec-WebSocket-Key')!;
        request.response
          ..statusCode = HttpStatus.switchingProtocols
          ..headers.set(HttpHeaders.connectionHeader, 'Upgrade')
          ..headers.set(HttpHeaders.upgradeHeader, 'websocket')
          ..headers.set('Sec-WebSocket-Accept', WebSocketChannel.signKey(key))
          ..headers.set(header.key, header.value);
        final socket = await request.response.detachSocket();
        responseSent.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        socket.destroy();
      });
      final isolated = WsSvrManager.forTesting();
      final connecting = isolated.connectToServer(
        _attemptRequest('negotiation-${header.key}', peerServer.port),
      );
      await responseSent.future.timeout(const Duration(seconds: 2));
      final result = await connecting.timeout(const Duration(seconds: 2));

      expect(result.status, ConnectionAttemptStatus.rejected);
      await isolated.closeGracefully(
        closeServer: true,
        forceServerClose: true,
      );
      await peerServer.close(force: true);
    }
  });
}
