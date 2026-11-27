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

    final pendingOutgoing = File(
      'lib/socket/pending_outgoing_connection.dart',
    ).readAsStringSync();
    expect(pendingOutgoing, contains('httpClient = newDirectPeerHttpClient()'));
    expect(pendingOutgoing, isNot(contains('httpClient = HttpClient()')));
    final svrmanager = File('lib/socket/svrmanager.dart').readAsStringSync();
    expect(svrmanager, isNot(contains('httpClient = HttpClient()')));

    // Every media route dials through this one function.
    final mediaDial = File(
      'lib/socket/media_channel_dial.dart',
    ).readAsStringSync();
    expect(mediaDial, isNot(contains('IOWebSocketChannel.connect(uri);')));
    expect(mediaDial, contains('customClient: newDirectPeerHttpClient()'));
    expect(mediaDial, contains('client: newDirectPeerHttpClient()'));
  });
}
