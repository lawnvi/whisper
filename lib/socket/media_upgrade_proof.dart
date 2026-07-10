import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';

const String mediaUpgradeChallengeType = 'whisper-media-challenge-v1';
const String mediaUpgradeProofType = 'whisper-media-proof-v1';
const String mediaUpgradeReadyType = 'whisper-media-ready-v1';
const int maxMediaUpgradeHandshakeMessageBytes = 2048;

final class MediaUpgradeClientContext {
  MediaUpgradeClientContext({
    required this.namespace,
    required this.sessionId,
    required this.peerId,
    required Uint8List mediaMacKey,
    this.timeout = const Duration(seconds: 3),
  }) : _mediaMacKey = Uint8List.fromList(mediaMacKey) {
    if (sessionId.isEmpty ||
        peerId.isEmpty ||
        mediaMacKey.length != 32 ||
        timeout <= Duration.zero) {
      throw const FormatException('invalid media upgrade client context');
    }
  }

  final String namespace;
  final String sessionId;
  final String peerId;
  final Duration timeout;
  final Uint8List _mediaMacKey;

  Uint8List get mediaMacKey => Uint8List.fromList(_mediaMacKey);
}

final class MediaUpgradeChallenge {
  MediaUpgradeChallenge({
    required String route,
    required String namespace,
    required this.sessionId,
    required this.tokenHash,
    required this.nonce,
    required this.peerId,
    required this.connectionGeneration,
  })  : route = normalizeMediaRoute(route),
        namespace = normalizeMediaNamespace(namespace, route: route) {
    if (sessionId.isEmpty || peerId.isEmpty || connectionGeneration < 0) {
      throw const FormatException('invalid media upgrade challenge context');
    }
    _decodeCanonical32Bytes(tokenHash, field: 'tokenHash');
    _decodeCanonical32Bytes(nonce, field: 'nonce');
  }

  factory MediaUpgradeChallenge.fromWire(Object? value) {
    if (value is! String ||
        utf8.encode(value).length > maxMediaUpgradeHandshakeMessageBytes) {
      throw const FormatException('invalid media upgrade challenge');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      throw const FormatException('invalid media upgrade challenge');
    }
    if (decoded is! Map<String, dynamic> ||
        !_hasExactKeys(decoded, const <String>{
          'type',
          'route',
          'namespace',
          'session',
          'tokenHash',
          'nonce',
          'peer',
          'generation',
        }) ||
        decoded['type'] != mediaUpgradeChallengeType ||
        decoded['route'] is! String ||
        decoded['namespace'] is! String ||
        decoded['session'] is! String ||
        decoded['tokenHash'] is! String ||
        decoded['nonce'] is! String ||
        decoded['peer'] is! String ||
        decoded['generation'] is! int) {
      throw const FormatException('invalid media upgrade challenge');
    }
    return MediaUpgradeChallenge(
      route: decoded['route'] as String,
      namespace: decoded['namespace'] as String,
      sessionId: decoded['session'] as String,
      tokenHash: decoded['tokenHash'] as String,
      nonce: decoded['nonce'] as String,
      peerId: decoded['peer'] as String,
      connectionGeneration: decoded['generation'] as int,
    );
  }

  final String route;
  final String namespace;
  final String sessionId;
  final String tokenHash;
  final String nonce;
  final String peerId;
  final int connectionGeneration;

  String toWire() => jsonEncode(<String, Object>{
        'type': mediaUpgradeChallengeType,
        'route': route,
        'namespace': namespace,
        'session': sessionId,
        'tokenHash': tokenHash,
        'nonce': nonce,
        'peer': peerId,
        'generation': connectionGeneration,
      });
}

String mediaUpgradeTokenHash(String token) =>
    _encodeCanonical32Bytes(sha256.convert(utf8.encode(token)).bytes);

String createMediaUpgradeProof({
  required MediaUpgradeChallenge challenge,
  required Uint8List mediaMacKey,
}) {
  if (mediaMacKey.length != 32) {
    throw ArgumentError.value(mediaMacKey.length, 'mediaMacKey.length');
  }
  final mac = Hmac(sha256, mediaMacKey).convert(
    _mediaUpgradeProofTranscript(challenge),
  );
  return _encodeCanonical32Bytes(mac.bytes);
}

String encodeMediaUpgradeProof(String proof) {
  _decodeCanonical32Bytes(proof, field: 'proof');
  return jsonEncode(<String, Object>{
    'type': mediaUpgradeProofType,
    'proof': proof,
  });
}

String decodeMediaUpgradeProof(Object? value) {
  if (value is! String ||
      utf8.encode(value).length > maxMediaUpgradeHandshakeMessageBytes) {
    throw const FormatException('invalid media upgrade proof');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(value);
  } on FormatException {
    throw const FormatException('invalid media upgrade proof');
  }
  if (decoded is! Map<String, dynamic> ||
      !_hasExactKeys(decoded, const <String>{'type', 'proof'}) ||
      decoded['type'] != mediaUpgradeProofType ||
      decoded['proof'] is! String) {
    throw const FormatException('invalid media upgrade proof');
  }
  final proof = decoded['proof'] as String;
  _decodeCanonical32Bytes(proof, field: 'proof');
  return proof;
}

bool verifyMediaUpgradeProof({
  required MediaUpgradeChallenge challenge,
  required String proof,
  required Uint8List mediaMacKey,
}) {
  Uint8List supplied;
  try {
    supplied = _decodeCanonical32Bytes(proof, field: 'proof');
  } on FormatException {
    return false;
  }
  final expected = _decodeCanonical32Bytes(
    createMediaUpgradeProof(
      challenge: challenge,
      mediaMacKey: mediaMacKey,
    ),
    field: 'proof',
  );
  return constantTimeBytesEqual(supplied, expected);
}

bool isMediaUpgradeReady(Object? value) {
  if (value is! String ||
      utf8.encode(value).length > maxMediaUpgradeHandshakeMessageBytes) {
    return false;
  }
  try {
    final decoded = jsonDecode(value);
    return decoded is Map<String, dynamic> &&
        _hasExactKeys(decoded, const <String>{'type'}) &&
        decoded['type'] == mediaUpgradeReadyType;
  } on FormatException {
    return false;
  }
}

String encodeMediaUpgradeReady() =>
    jsonEncode(const <String, Object>{'type': mediaUpgradeReadyType});

Future<WebSocketChannel> authenticateMediaWebSocketClient(
  WebSocketChannel channel, {
  required Uri uri,
  required String route,
  required String namespace,
  required String sessionId,
  required String peerId,
  required Uint8List mediaMacKey,
  Duration timeout = const Duration(seconds: 3),
}) {
  final sessions = uri.queryParametersAll['session'];
  final tokens = uri.queryParametersAll['token'];
  if (sessions == null ||
      sessions.length != 1 ||
      sessions.single != sessionId ||
      tokens == null ||
      tokens.length != 1 ||
      tokens.single.isEmpty ||
      peerId.isEmpty ||
      mediaMacKey.length != 32 ||
      timeout <= Duration.zero) {
    throw const FormatException('invalid media upgrade client context');
  }
  return _MediaUpgradeClientHandshake(
    channel: channel,
    route: normalizeMediaRoute(route),
    namespace: normalizeMediaNamespace(namespace, route: route),
    sessionId: sessionId,
    peerId: peerId,
    tokenHash: mediaUpgradeTokenHash(tokens.single),
    mediaMacKey: mediaMacKey,
    timeout: timeout,
  ).result;
}

final class _MediaUpgradeClientHandshake {
  _MediaUpgradeClientHandshake({
    required WebSocketChannel channel,
    required this.route,
    required this.namespace,
    required this.sessionId,
    required this.peerId,
    required this.tokenHash,
    required Uint8List mediaMacKey,
    required Duration timeout,
  })  : _channel = channel,
        _mediaMacKey = Uint8List.fromList(mediaMacKey) {
    _subscription = channel.stream.listen(
      _handleMessage,
      onError: _handleError,
      onDone: _handleDone,
      cancelOnError: false,
    );
    _timer = Timer(
      timeout,
      () => _fail(TimeoutException('media upgrade proof timed out')),
    );
  }

  final WebSocketChannel _channel;
  final String route;
  final String namespace;
  final String sessionId;
  final String peerId;
  final String tokenHash;
  final Uint8List _mediaMacKey;
  final StreamController<dynamic> _authenticatedMessages =
      StreamController<dynamic>(sync: true);
  final Completer<WebSocketChannel> _result = Completer<WebSocketChannel>();
  StreamSubscription<dynamic>? _subscription;
  Timer? _timer;
  bool _proofSent = false;
  bool _authenticated = false;
  bool _failed = false;

  Future<WebSocketChannel> get result => _result.future;

  void _handleMessage(dynamic message) {
    if (_failed) {
      return;
    }
    if (_authenticated) {
      _authenticatedMessages.add(message);
      return;
    }
    try {
      if (!_proofSent) {
        final challenge = MediaUpgradeChallenge.fromWire(message);
        if (challenge.route != route ||
            challenge.namespace != namespace ||
            challenge.sessionId != sessionId ||
            challenge.tokenHash != tokenHash ||
            challenge.peerId != peerId) {
          throw const FormatException('media upgrade challenge mismatch');
        }
        final proof = createMediaUpgradeProof(
          challenge: challenge,
          mediaMacKey: _mediaMacKey,
        );
        _channel.sink.add(encodeMediaUpgradeProof(proof));
        _proofSent = true;
        return;
      }
      if (!isMediaUpgradeReady(message)) {
        throw const FormatException('invalid media upgrade ready message');
      }
      _authenticated = true;
      _timer?.cancel();
      _timer = null;
      _result.complete(
        _ForwardedWebSocketChannel(_channel, _authenticatedMessages.stream),
      );
    } catch (error, stackTrace) {
      _fail(error, stackTrace);
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    if (_authenticated) {
      _authenticatedMessages.addError(error, stackTrace);
      return;
    }
    _fail(error, stackTrace);
  }

  void _handleDone() {
    if (_authenticated) {
      unawaited(_authenticatedMessages.close());
      return;
    }
    _fail(StateError('media upgrade socket closed'));
  }

  void _fail(Object error, [StackTrace? stackTrace]) {
    if (_failed || _authenticated) {
      return;
    }
    _failed = true;
    _timer?.cancel();
    _timer = null;
    if (!_result.isCompleted) {
      if (stackTrace == null) {
        _result.completeError(error);
      } else {
        _result.completeError(error, stackTrace);
      }
    }
    unawaited(
      _subscription?.cancel().catchError((Object _, StackTrace __) {}) ??
          Future<void>.value(),
    );
    unawaited(
      _authenticatedMessages.close().catchError((Object _, StackTrace __) {}),
    );
    unawaited(
      _channel.sink
          .close(4001, 'media_auth_failed')
          .catchError((Object _, StackTrace __) {}),
    );
  }
}

final class MediaUpgradeServerSession {
  MediaUpgradeServerSession({
    required WebSocketChannel channel,
    required MediaUpgradeChallenge challenge,
    required Uint8List mediaMacKey,
    required Duration timeout,
    required bool Function(WebSocketChannel channel) onAuthenticated,
    required void Function() onProvisionalFinished,
  })  : _channel = channel,
        _challenge = challenge,
        _mediaMacKey = Uint8List.fromList(mediaMacKey),
        _timeout = timeout,
        _onAuthenticated = onAuthenticated,
        _onProvisionalFinished = onProvisionalFinished {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout');
    }
    _start();
  }

  final WebSocketChannel _channel;
  final MediaUpgradeChallenge _challenge;
  final Uint8List _mediaMacKey;
  final Duration _timeout;
  final bool Function(WebSocketChannel channel) _onAuthenticated;
  final void Function() _onProvisionalFinished;
  final StreamController<dynamic> _authenticatedMessages =
      StreamController<dynamic>(sync: true);
  StreamSubscription<dynamic>? _subscription;
  Timer? _timer;
  bool _authenticated = false;
  bool _finished = false;
  bool _closing = false;

  void _start() {
    _subscription = _channel.stream.listen(
      _handleMessage,
      onError: (Object error, StackTrace stackTrace) {
        if (_authenticated) {
          _authenticatedMessages.addError(error, stackTrace);
        } else {
          _fail();
        }
      },
      onDone: () {
        if (!_authenticated) {
          _finishProvisional();
        }
        unawaited(_authenticatedMessages.close());
      },
      cancelOnError: false,
    );
    _timer = Timer(_timeout, _fail);
    try {
      _channel.sink.add(_challenge.toWire());
    } catch (_) {
      _fail();
    }
  }

  void _handleMessage(dynamic message) {
    if (_closing) {
      return;
    }
    if (_authenticated) {
      _authenticatedMessages.add(message);
      return;
    }
    try {
      final proof = decodeMediaUpgradeProof(message);
      if (!verifyMediaUpgradeProof(
        challenge: _challenge,
        proof: proof,
        mediaMacKey: _mediaMacKey,
      )) {
        _fail();
        return;
      }
      final authenticatedChannel = _ForwardedWebSocketChannel(
        _channel,
        _authenticatedMessages.stream,
      );
      if (!_onAuthenticated(authenticatedChannel)) {
        _fail();
        return;
      }
      _authenticated = true;
      _timer?.cancel();
      _timer = null;
      _finishProvisional();
      _channel.sink.add(encodeMediaUpgradeReady());
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    if (_closing || _authenticated) {
      return;
    }
    _closing = true;
    _timer?.cancel();
    _timer = null;
    _finishProvisional();
    unawaited(
      _subscription?.cancel().catchError((Object _, StackTrace __) {}) ??
          Future<void>.value(),
    );
    unawaited(
      _authenticatedMessages.close().catchError((Object _, StackTrace __) {}),
    );
    unawaited(
      _channel.sink
          .close(4001, 'media_auth_failed')
          .catchError((Object _, StackTrace __) {}),
    );
  }

  void _finishProvisional() {
    if (_finished) {
      return;
    }
    _finished = true;
    _onProvisionalFinished();
  }
}

final class _ForwardedWebSocketChannel extends StreamChannelMixin
    implements WebSocketChannel {
  _ForwardedWebSocketChannel(this._inner, this._stream);

  final WebSocketChannel _inner;
  final Stream<dynamic> _stream;

  @override
  Stream<dynamic> get stream => _stream;

  @override
  WebSocketSink get sink => _inner.sink;

  @override
  String? get protocol => _inner.protocol;

  @override
  int? get closeCode => _inner.closeCode;

  @override
  String? get closeReason => _inner.closeReason;

  @override
  Future<void> get ready => _inner.ready;
}

Uint8List _mediaUpgradeProofTranscript(MediaUpgradeChallenge challenge) {
  final domain = utf8.encode('whisper-media-upgrade-proof-v1\u0000');
  final fields = <List<int>>[
    utf8.encode(challenge.route),
    utf8.encode(challenge.namespace),
    utf8.encode(challenge.sessionId),
    utf8.encode(challenge.tokenHash),
    utf8.encode(challenge.nonce),
    utf8.encode(challenge.peerId),
  ];
  if (fields.any((field) => field.length > 0xffff)) {
    throw const FormatException('media upgrade proof context is too long');
  }
  final length = domain.length +
      fields.fold<int>(0, (total, field) => total + 2 + field.length) +
      8;
  final transcript = Uint8List(length);
  final data = ByteData.sublistView(transcript);
  var offset = 0;
  transcript.setRange(offset, offset + domain.length, domain);
  offset += domain.length;
  for (final field in fields) {
    data.setUint16(offset, field.length);
    offset += 2;
    transcript.setRange(offset, offset + field.length, field);
    offset += field.length;
  }
  data.setUint64(offset, challenge.connectionGeneration);
  return transcript;
}

bool _hasExactKeys(Map<String, dynamic> value, Set<String> expected) =>
    value.length == expected.length && value.keys.toSet().containsAll(expected);

String _encodeCanonical32Bytes(List<int> bytes) {
  if (bytes.length != 32) {
    throw const FormatException('invalid 32-byte media upgrade value');
  }
  return base64Url.encode(bytes).replaceAll('=', '');
}

Uint8List _decodeCanonical32Bytes(String value, {required String field}) {
  if (value.length != 43 ||
      value.contains('=') ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw FormatException('invalid media upgrade $field');
  }
  try {
    final decoded = Uint8List.fromList(base64Url.decode('$value='));
    if (decoded.length != 32 || _encodeCanonical32Bytes(decoded) != value) {
      throw FormatException('invalid media upgrade $field');
    }
    return decoded;
  } on FormatException {
    throw FormatException('invalid media upgrade $field');
  }
}
