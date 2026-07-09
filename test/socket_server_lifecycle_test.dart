import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/svrmanager.dart';

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
}
