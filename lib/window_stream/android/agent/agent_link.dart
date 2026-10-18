import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'agent_wire.dart';

/// How the phone's own Whisper reaches a persistent whisper-agent: loopback
/// TCP on [port], proving [token] without sending it (`AppLink.java`). The
/// agent pushed both through Whisper's window-stream provider, which only
/// the shell user (the agent) and root may call.
class AgentLinkInfo {
  const AgentLinkInfo({
    required this.port,
    required this.token,
    this.pid = 0,
    this.protocol = 0,
    this.version = '',
    this.jarSha = '',
  });

  /// From the provider's `link` extras as the plugin hands them over.
  static AgentLinkInfo? fromMap(Object? value) {
    if (value is! Map) {
      return null;
    }
    final port = value['port'];
    final token = value['token'];
    if (port is! int ||
        port <= 0 ||
        port > 65535 ||
        token is! Uint8List ||
        token.length != AgentWire.tokenBytes) {
      return null;
    }
    return AgentLinkInfo(
      port: port,
      token: token,
      pid: value['pid'] is int ? value['pid'] as int : 0,
      protocol: value['protocol'] is int ? value['protocol'] as int : 0,
      version: '${value['version'] ?? ''}',
      jarSha: '${value['jarSha'] ?? ''}',
    );
  }

  final int port;
  final Uint8List token;
  final int pid;
  final int protocol;
  final String version;
  final String jarSha;
}

/// One authenticated connection to the agent: write to [socket], read
/// [input] (the bytes after the handshake).
class AgentConnection {
  AgentConnection(this.socket, this.input);

  final Socket socket;
  final Stream<Uint8List> input;

  void destroy() => socket.destroy();
}

/// A connection the agent refused or that failed its proof.
class AgentLinkException implements Exception {
  const AgentLinkException(this.message);

  final String message;

  @override
  String toString() => 'AgentLinkException($message)';
}

abstract final class AgentLink {
  static final _random = Random.secure();

  /// Opens a [role] connection for [stream] (0 for control) over the link.
  static Future<AgentConnection> connect(
    AgentLinkInfo link, {
    required int role,
    int stream = 0,
    String host = '127.0.0.1',
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final socket = await Socket.connect(host, link.port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    final nonce = Uint8List.fromList(
      List.generate(AgentWire.nonceBytes, (_) => _random.nextInt(256)),
    );
    final hello = AgentWire.appHello(role, stream, nonce);
    try {
      return await handshake(
        socket,
        socket,
        hello: hello,
        token: link.token,
      ).timeout(timeout);
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  /// The client half of the challenge: sends [hello], checks the agent's
  /// proof and answers with its own. Split out of [connect] for tests.
  static Future<AgentConnection> handshake(
    Socket socket,
    Stream<Uint8List> incoming, {
    required Uint8List hello,
    required Uint8List token,
  }) async {
    const answerBytes = AgentWire.nonceBytes + AgentWire.macBytes;
    final pending = BytesBuilder(copy: true);
    final answer = Completer<Uint8List>();
    final rest = StreamController<Uint8List>(sync: true);
    late final StreamSubscription<Uint8List> subscription;
    subscription = incoming.listen(
      (chunk) {
        if (answer.isCompleted) {
          rest.add(chunk);
          return;
        }
        pending.add(chunk);
        if (pending.length >= answerBytes) {
          final all = pending.takeBytes();
          answer.complete(Uint8List.sublistView(all, 0, answerBytes));
          if (all.length > answerBytes) {
            rest.add(Uint8List.sublistView(all, answerBytes));
          }
        }
      },
      onError: (Object error) {
        if (!answer.isCompleted) {
          answer.completeError(error);
        } else {
          rest.addError(error);
        }
      },
      onDone: () {
        if (!answer.isCompleted) {
          answer.completeError(
            const AgentLinkException('the agent refused the connection'),
          );
        }
        unawaited(rest.close());
      },
      cancelOnError: true,
    );
    rest
      ..onPause = subscription.pause
      ..onResume = subscription.resume
      ..onCancel = subscription.cancel;
    socket.add(hello);
    final reply = await answer.future;
    final agentNonce = Uint8List.sublistView(reply, 0, AgentWire.nonceBytes);
    final proof = Uint8List.sublistView(reply, AgentWire.nonceBytes);
    if (!AgentWire.sameMac(
      proof,
      AgentWire.agentProof(token, hello, agentNonce),
    )) {
      await subscription.cancel();
      throw const AgentLinkException('the agent did not prove the token');
    }
    socket.add(AgentWire.clientProof(token, hello, agentNonce));
    return AgentConnection(socket, rest.stream);
  }
}
