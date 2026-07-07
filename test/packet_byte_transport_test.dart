import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

void main() {
  test('send after close drops with hook, close is idempotent', () async {
    final sentBytes = <Object>[];
    var dropped = 0;
    var closes = 0;
    final transport = PacketByteTransport(
      sendBytes: sentBytes.add,
      closeSink: () async => closes++,
      onPacketDropped: () => dropped++,
    );
    transport.send([1]);
    await transport.close();
    await transport.close();
    transport.send([2]);
    expect(sentBytes, [
      [1]
    ]);
    expect(dropped, 1);
    expect(closes, 1);
    expect(transport.isClosed, isTrue);
  });

  test('buildPeerPacketUri composes ws uri', () {
    final uri = buildPeerPacketUri(host: '192.168.1.2', port: 9200, path: '/audio');
    expect(uri.scheme, 'ws');
    expect(uri.host, '192.168.1.2');
    expect(uri.port, 9200);
    expect(uri.path, '/audio');
  });
}
