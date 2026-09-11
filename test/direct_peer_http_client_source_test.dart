import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 对等连接必须走两台设备直接互达的链路:所有出站拨号/媒体升级都不能
/// 让 dart:io 默认的 HTTP_PROXY 环境变量代理介入。
void main() {
  test('peer dial and media upgrades never use an environment proxy', () {
    final helper = File(
      'lib/socket/direct_peer_http_client.dart',
    ).readAsStringSync();
    expect(helper, contains("findProxy = (_) => 'DIRECT'"));

    final svrmanager = File('lib/socket/svrmanager.dart').readAsStringSync();
    expect(svrmanager, contains('httpClient = newDirectPeerHttpClient()'));
    expect(svrmanager, isNot(contains('httpClient = HttpClient()')));

    for (final path in <String>[
      'lib/remote_input/remote_input_packet_transport.dart',
      'lib/socket/packet_byte_transport.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        isNot(contains('IOWebSocketChannel.connect(uri);')),
        reason: '$path must pass a direct customClient',
      );
      expect(source, contains('customClient: newDirectPeerHttpClient()'));
    }
  });
}
