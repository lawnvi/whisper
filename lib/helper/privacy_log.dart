import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';

typedef PrivacyLogSink = void Function(String line);

final class PrivacyShortId {
  const PrivacyShortId._(this.value);

  final String value;
}

final class PrivacyErrorType {
  const PrivacyErrorType._(this.kind);

  final PrivacyErrorKind kind;

  String get value => kind.name;
}

enum PrivacyRoute { chat, audio, input, other }

enum PrivacyIdKind { peer, transfer, message, session, group, stream }

enum PrivacyErrorKind {
  fileSystem,
  socket,
  http,
  tls,
  timeout,
  format,
  state,
  argument,
  unsupported,
  unknown,
}

enum PrivacyEvent { transferProgress, testEvent }

extension on PrivacyEvent {
  String get wireName => switch (this) {
        PrivacyEvent.transferProgress => 'transfer_progress',
        PrivacyEvent.testEvent => 'test_event',
      };
}

enum PrivacyField {
  allowed,
  bytes,
  errorType,
  peerId,
  retrying,
  route,
  state,
  transferId,
  value,
}

final class PrivacyLog {
  PrivacyLog({PrivacyLogSink? sink}) : _sink = sink ?? _developerSink;

  static final RegExp _canonicalIdPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  final PrivacyLogSink _sink;

  PrivacyShortId shortId(PrivacyIdKind kind, String raw) {
    if (!_canonicalIdPattern.hasMatch(raw)) {
      throw ArgumentError.value(raw, 'raw', 'must be a canonical UUID');
    }
    final input = utf8.encode(
      'whisper-privacy-short-id-v1\u0000${kind.name}\u0000$raw',
    );
    final digest = sha256.convert(input).toString();
    return PrivacyShortId._(digest.substring(0, 12));
  }

  PrivacyRoute redactUri(Uri uri) {
    return switch (uri.path) {
      '/chat' => PrivacyRoute.chat,
      '/audio' => PrivacyRoute.audio,
      '/input' => PrivacyRoute.input,
      _ => PrivacyRoute.other,
    };
  }

  PrivacyErrorType errorType(Object error) {
    final kind = switch (error) {
      SocketException() => PrivacyErrorKind.socket,
      FileSystemException() => PrivacyErrorKind.fileSystem,
      HandshakeException() || TlsException() => PrivacyErrorKind.tls,
      HttpException() => PrivacyErrorKind.http,
      TimeoutException() => PrivacyErrorKind.timeout,
      FormatException() => PrivacyErrorKind.format,
      ArgumentError() => PrivacyErrorKind.argument,
      UnsupportedError() => PrivacyErrorKind.unsupported,
      StateError() => PrivacyErrorKind.state,
      _ => PrivacyErrorKind.unknown,
    };
    return PrivacyErrorType._(kind);
  }

  void event(PrivacyEvent name, Map<PrivacyField, Object> fields) {
    final output = SplayTreeMap<String, Object>();
    for (final entry in fields.entries) {
      output[entry.key.name] = _safeFieldValue(entry.value);
    }
    output['event'] = name.wireName;
    _sink(jsonEncode(output));
  }

  static Object _safeFieldValue(Object value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      if (!value.isFinite) {
        throw ArgumentError('Privacy log numbers must be finite');
      }
      return value;
    }
    if (value is PrivacyShortId) {
      return value.value;
    }
    if (value is PrivacyErrorType) {
      return value.value;
    }
    if (value is Enum) {
      return value.name;
    }
    throw ArgumentError('Unsupported privacy log field type');
  }

  static void _developerSink(String line) {
    developer.log(line, name: 'whisper.privacy');
  }
}
