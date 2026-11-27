import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/no_delay_socket.dart';
import 'package:whisper/socket/pending_outgoing_connection.dart';
import 'package:whisper/socket/pre_auth_byte_cap.dart';

/// 对等设备都在同一局域网,连接必须走两台设备能直接互达的那条链路。
///
/// `dart:io` 的 [HttpClient] 默认会读取 `HTTP_PROXY` / `HTTPS_PROXY`
/// 环境变量;从开着代理的终端启动 app 时,主会话拨号和 `/input`、`/audio`
/// 升级都会被送去代理,代理剥掉 `Upgrade` 头,对端只看到普通 GET 而回 400。
/// 所有对等连接统一用这里的客户端,关闭代理解析。应用内更新下载不在此列。
HttpClient newDirectPeerHttpClient() =>
    HttpClient()..findProxy = (_) => 'DIRECT';

Future<({WebSocket webSocket, Socket socket})> connectOutgoingWebSocket(
  Uri webSocketUri,
  PendingOutgoingConnection attempt, {
  required Duration timeout,
  required Duration pingInterval,
}) async {
  final requestUri = webSocketUri.replace(
    scheme: webSocketUri.scheme == 'wss' ? 'https' : 'http',
  );
  final nonce = newWebSocketKey();
  final httpClient = attempt.createDialHttpClient();
  HttpClientRequest? request;
  var detached = false;
  try {
    request = await httpClient.openUrl('GET', requestUri).timeout(timeout);
    attempt.trackTransportRequest(request);
    request.followRedirects = false;
    if (attempt.isCancelled) {
      request.abort(const OutgoingConnectionCancelled());
      throw const OutgoingConnectionCancelled();
    }
    setWebSocketUpgradeHeaders(request.headers, nonce);
    final response = await request.close().timeout(timeout);
    attempt.untrackTransportRequest(request);
    request = null;
    if (attempt.isCancelled) {
      final socket = await response.detachSocket();
      socket.destroy();
      throw const OutgoingConnectionCancelled();
    }
    final connectionTokens =
        (response.headers[HttpHeaders.connectionHeader] ?? const <String>[])
            .expand((value) => value.split(','))
            .map((value) => value.trim().toLowerCase());
    final upgrade = response.headers.value(HttpHeaders.upgradeHeader);
    final accept = response.headers.value('Sec-WebSocket-Accept');
    Future<Never> rejectResponse(String reason) async {
      final socket = await response.detachSocket();
      socket.destroy();
      throw WebSocketUpgradeRejected(reason, response.statusCode);
    }

    if (response.statusCode != HttpStatus.switchingProtocols ||
        !connectionTokens.contains('upgrade') ||
        upgrade?.trim().toLowerCase() != 'websocket' ||
        accept?.trim() != WebSocketChannel.signKey(nonce)) {
      return rejectResponse(
        "Connection to '$webSocketUri' was not upgraded to websocket",
      );
    }
    if (response.headers.value('Sec-WebSocket-Protocol') != null ||
        response.headers.value('Sec-WebSocket-Extensions') != null) {
      return rejectResponse('unexpected_websocket_negotiation');
    }
    final socket = await response.detachSocket();
    detached = true;
    if (attempt.isCancelled) {
      socket.destroy();
      throw const OutgoingConnectionCancelled();
    }
    setTcpNoDelay(socket);
    tuneChatSocket(socket);
    final webSocket = cappedClientWebSocket(socket, () => attempt.session)
      ..pingInterval = pingInterval;
    return (webSocket: webSocket, socket: socket);
  } finally {
    if (request != null) {
      attempt.untrackTransportRequest(request);
    }
    attempt.releaseDialHttpClient(httpClient, force: !detached);
  }
}

bool isValidWebSocketUpgradeRequest(shelf.Request request) {
  final connection = request.headers[HttpHeaders.connectionHeader];
  final upgrade = request.headers[HttpHeaders.upgradeHeader];
  final version = request.headers['sec-websocket-version'];
  final key = request.headers['sec-websocket-key'];
  if (connection == null ||
      !connection
          .split(',')
          .map((token) => token.trim().toLowerCase())
          .contains('upgrade') ||
      upgrade?.trim().toLowerCase() != 'websocket' ||
      version?.trim() != '13' ||
      key == null) {
    return false;
  }
  try {
    return base64.decode(key.trim()).length == 16;
  } on FormatException {
    return false;
  }
}
