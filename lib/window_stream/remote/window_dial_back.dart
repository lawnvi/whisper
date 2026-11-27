import 'dart:async';
import 'dart:isolate';

import '../../socket/packet_byte_transport.dart';
import 'inbound_window_relay.dart';
import 'remote_window_worker.dart';

/// A viewer whose stream isolate could not reach the host at all (its
/// firewall, a VPN): the host is asked to dial this device instead, as a
/// phone host that opened the session does from the start
/// (`WindowStreamMediaDial`). The stream isolate asks over [port]; this
/// side, on the UI isolate, issues the token, sets up the relay the host's
/// socket comes in through, and sends `dial`. Once per stream.
class WindowDialBackResponder {
  WindowDialBackResponder({
    required this.hostPeerId,
    required ({String token, int port})? Function() issue,
    required void Function(InboundWindowHostRelay relay) onRelay,
    required Future<bool> Function(String token, int port) sendDial,
  }) : _issue = issue,
       _onRelay = onRelay,
       _sendDial = sendDial {
    _requests.listen(_answer);
  }

  final String hostPeerId;
  final ({String token, int port})? Function() _issue;
  final void Function(InboundWindowHostRelay relay) _onRelay;
  final Future<bool> Function(String token, int port) _sendDial;
  final _requests = ReceivePort('window-dial-back');
  bool _used = false;

  SendPort get port => _requests.sendPort;

  Future<void> _answer(Object? message) async {
    if (message is! SendPort) return;
    if (_used) {
      message.send(null);
      return;
    }
    _used = true;
    final issued = _issue();
    if (issued == null) {
      message.send(null);
      return;
    }
    final relay = InboundWindowHostRelay(
      hostPeerId: hostPeerId,
      binding: mediaPacketChannelBindingFromToken(issued.token),
    );
    _onRelay(relay);
    if (!await _sendDial(issued.token, issued.port)) {
      relay.close();
      message.send(null);
      return;
    }
    message.send(<Object>[relay.port, issued.token]);
  }

  void close() => _requests.close();
}

/// The stream isolate's side: asks over [port] to be dialled, then waits for
/// the host's socket through the relay. Null when the UI isolate could not
/// ask, or the host did not dial in time.
Future<({InboundWindowRelayChannel channel, String token})?> askWindowDialBack(
  SendPort port,
) async {
  final reply = ReceivePort('window-dial-back-reply');
  try {
    port.send(reply.sendPort);
    final answer = await reply.first.timeout(
      const Duration(seconds: 5),
      onTimeout: () => null,
    );
    if (answer case [SendPort relayPort, String token]) {
      return _connected(relayPort, token);
    }
    return null;
  } finally {
    reply.close();
  }
}

Future<({InboundWindowRelayChannel channel, String token})?> _connected(
  SendPort relayPort,
  String token,
) async {
  final channel = InboundWindowRelayChannel(relayPort);
  try {
    await channel.connected.timeout(InboundWhisperWindowSpec.connectTimeout);
  } catch (_) {
    unawaited(channel.sink.close().catchError((Object _) {}));
    return null;
  }
  return (channel: channel, token: token);
}
