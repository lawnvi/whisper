import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/no_delay_socket.dart';

void main() {
  test('a route can claim the socket its request came in on, once', () async {
    final listening = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepting = NoDelayServerSocket(listening);
    final server = HttpServer.listenOn(accepting);
    addTearDown(() => server.close(force: true));
    final claimed = <Socket?>[];
    server.listen((request) {
      final connection = request.connectionInfo!;
      claimed
        ..add(accepting.claim(connection))
        ..add(accepting.claim(connection));
      request.response
        ..write('ok')
        ..close();
    });

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.get(
      '127.0.0.1',
      accepting.port,
      '/',
    )).close();
    await response.drain<void>();
    expect(claimed, hasLength(2));
    expect(claimed.first, isNotNull);
    expect(claimed.first!.remotePort, isNot(accepting.port));
    // Handed out once: another route cannot tune it again.
    expect(claimed.last, isNull);
  });

  test('on Windows the file connection gets deep buffers', () async {
    final listening = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(listening.close);
    final socket = await Socket.connect('127.0.0.1', listening.port);
    addTearDown(socket.destroy);
    int buffer(int option) => ByteData.sublistView(
      socket.getRawOption(RawSocketOption(0xffff, option, Uint8List(4))),
    ).getInt32(0, Endian.host);
    widenTransferBuffers(socket);
    if (Platform.isWindows) {
      expect(buffer(0x1001), greaterThanOrEqualTo(16 * 1024 * 1024));
      expect(buffer(0x1002), greaterThanOrEqualTo(16 * 1024 * 1024));
    }
  });

  test('only the connection that carries files is widened', () {
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();
    // The chat route, once admitted, before the upgrade.
    final chat = manager.substring(
      manager.indexOf('_admission.tryOpenChat(remoteAddress)'),
      manager.indexOf('final chatHandler = webSocketHandler('),
    );
    expect(chat, contains('_acceptedSockets?.claim(connectionInfo)'));
    expect(chat, contains('widenTransferBuffers(accepted)'));
    // The connection this device opens to a peer.
    final outgoing = manager.substring(
      manager.indexOf('Future<WebSocket> _connectOutgoingWebSocket('),
    );
    expect(
      outgoing.substring(0, outgoing.indexOf('\n  }\n')),
      contains('widenTransferBuffers(socket);'),
    );
    expect('widenTransferBuffers('.allMatches(manager), hasLength(2));
    // Media (audio, input, live video) keep the system's buffers.
    final helper = File('lib/socket/no_delay_socket.dart').readAsStringSync();
    final connect = helper.substring(
      helper.indexOf('Future<WebSocket> connectNoDelayWebSocket('),
    );
    expect(connect, isNot(contains('widenTransferBuffers(')));
  });
}
