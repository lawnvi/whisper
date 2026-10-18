import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Wire format shared with whisper-agent (`android_agent/.../Wire.java`).
///
/// Every connection starts with a hello: `WAG1`, u8 role, u32 stream number
/// (big-endian), 32-byte launch token. Control connections then carry
/// length-prefixed (u32 big-endian) UTF-8 JSON. A stream's video and audio
/// connections carry the scrcpy media format (video starts with one status
/// byte) and its input connection carries scrcpy control messages.
///
/// The phone's own Whisper reaches the agent over loopback TCP, where any
/// app could connect, so it never sends the token: [appHello] carries a
/// nonce, the agent answers with its nonce and [agentProof], and the client
/// replies with [clientProof] (see `AppLink.java`).
abstract final class AgentWire {
  /// 2: persistent agent, app link, `status`, streams owned per session.
  static const int protocolVersion = 2;
  static const int tokenBytes = 32;
  static const int nonceBytes = 32;
  static const int macBytes = 32;
  static const int helloBytes = 4 + 1 + 4 + tokenBytes;
  static const int appHelloBytes = 4 + 1 + 4 + nonceBytes;
  static const int maxMessageBytes = 4 * 1024 * 1024;

  static const int roleControl = 1;
  static const int roleVideo = 2;
  static const int roleAudio = 3;
  static const int roleInput = 4;

  /// The persistent agent's abstract socket (also its single-instance lock).
  static const String daemonSocket = 'whisper_agent';

  static const String mainClass = 'com.vireen.whisper.agent.AgentMain';
  static const String readyLine = 'whisper-agent ready';

  static Uint8List hello(int role, int stream, Uint8List token) {
    if (token.length != tokenBytes) {
      throw ArgumentError.value(token.length, 'token', 'must be 32 bytes');
    }
    final out = Uint8List(helloBytes);
    out.setRange(0, 4, ascii.encode('WAG1'));
    out[4] = role;
    ByteData.sublistView(out, 5, 9).setUint32(0, stream, Endian.big);
    out.setRange(9, helloBytes, token);
    return out;
  }

  static Uint8List appHello(int role, int stream, Uint8List clientNonce) {
    if (clientNonce.length != nonceBytes) {
      throw ArgumentError.value(clientNonce.length, 'clientNonce');
    }
    final out = Uint8List(appHelloBytes);
    out.setRange(0, 4, ascii.encode('WAG2'));
    out[4] = role;
    ByteData.sublistView(out, 5, 9).setUint32(0, stream, Endian.big);
    out.setRange(9, appHelloBytes, clientNonce);
    return out;
  }

  static final _agentLabel = ascii.encode('whisper-agent link agent');
  static final _clientLabel = ascii.encode('whisper-agent link client');

  /// What the agent answers [hello] with, proving it holds [token].
  static Uint8List agentProof(
    Uint8List token,
    Uint8List hello,
    Uint8List agentNonce,
  ) => _mac(token, [_agentLabel, hello, agentNonce]);

  /// What the client answers the agent's nonce with.
  static Uint8List clientProof(
    Uint8List token,
    Uint8List hello,
    Uint8List agentNonce,
  ) => _mac(token, [_clientLabel, hello, agentNonce]);

  static Uint8List _mac(Uint8List key, List<List<int>> parts) {
    final bytes = BytesBuilder(copy: false);
    for (final part in parts) {
      bytes.add(part);
    }
    return Uint8List.fromList(
      Hmac(sha256, key).convert(bytes.takeBytes()).bytes,
    );
  }

  /// Constant-time comparison of two MACs.
  static bool sameMac(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Uint8List frame(Object? message) {
    final payload = utf8.encode(jsonEncode(message));
    if (payload.length > maxMessageBytes) {
      throw ArgumentError('agent message too large: ${payload.length}');
    }
    final out = Uint8List(4 + payload.length);
    ByteData.sublistView(out, 0, 4).setUint32(0, payload.length, Endian.big);
    out.setRange(4, out.length, payload);
    return out;
  }
}

/// Splits the control connection's byte stream into decoded JSON messages.
class AgentMessageReader {
  final _buffer = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  /// Feeds [chunk]; returns every message it completes.
  List<Object?> add(Uint8List chunk) {
    if (_pending.isEmpty) {
      _pending = chunk;
    } else {
      _buffer
        ..add(_pending)
        ..add(chunk);
      _pending = _buffer.takeBytes();
    }
    final messages = <Object?>[];
    var offset = 0;
    while (_pending.length - offset >= 4) {
      final length = ByteData.sublistView(
        _pending,
        offset,
        offset + 4,
      ).getUint32(0, Endian.big);
      if (length > AgentWire.maxMessageBytes) {
        throw FormatException('agent message too large: $length');
      }
      if (_pending.length - offset - 4 < length) {
        break;
      }
      final payload = Uint8List.sublistView(
        _pending,
        offset + 4,
        offset + 4 + length,
      );
      messages.add(jsonDecode(utf8.decode(payload)));
      offset += 4 + length;
    }
    _pending = offset == 0
        ? _pending
        : Uint8List.fromList(Uint8List.sublistView(_pending, offset));
    return messages;
  }
}

/// `assets/window_stream/whisper-agent.json`, written by
/// `script/build_window_agent.sh` next to the jar.
class AgentSidecar {
  const AgentSidecar({
    required this.agentVersion,
    required this.protocol,
    required this.jarSha256,
    required this.sourceSha256,
  });

  factory AgentSidecar.fromJson(Map<String, dynamic> json) {
    final jarSha = json['jarSha256'];
    final protocol = json['protocol'];
    if (jarSha is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(jarSha) ||
        protocol is! int) {
      throw const FormatException('malformed whisper-agent.json');
    }
    return AgentSidecar(
      agentVersion: '${json['agentVersion'] ?? ''}',
      protocol: protocol,
      jarSha256: jarSha,
      sourceSha256: '${json['sourceSha256'] ?? ''}',
    );
  }

  final String agentVersion;
  final int protocol;
  final String jarSha256;
  final String sourceSha256;

  /// Where the jar lives on the phone. Named after its hash so a phone keeps
  /// one copy per build and a new build never runs an old jar.
  String get devicePath =>
      '/data/local/tmp/whisper-agent-${jarSha256.substring(0, 16)}.jar';
}
