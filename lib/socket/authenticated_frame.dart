import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:synchronized/synchronized.dart';

final class AuthenticatedFrameException implements Exception {
  const AuthenticatedFrameException(this.code);

  final String code;

  @override
  String toString() => 'AuthenticatedFrameException($code)';
}

final class AuthenticatedFrameCodec {
  AuthenticatedFrameCodec({
    required SecretKey sendKey,
    required SecretKey receiveKey,
    this.maxPayloadBytes = 16 * 1024 * 1024,
  })  : _sendKey = sendKey,
        _receiveKey = receiveKey {
    if (maxPayloadBytes < 0 || maxPayloadBytes > 0xffffffff) {
      throw ArgumentError.value(maxPayloadBytes, 'maxPayloadBytes');
    }
  }

  static const int _headerLength = 16;
  static const int _macLength = 32;
  static final Uint8List _magic = Uint8List.fromList(ascii.encode('WAF1'));
  static final Uint8List _macDomain =
      Uint8List.fromList(ascii.encode('whisper-frame-v1'));

  final SecretKey _sendKey;
  final SecretKey _receiveKey;
  final int maxPayloadBytes;
  final Lock _sendLock = Lock();
  final Lock _receiveLock = Lock();

  int _lastSentSequence = 0;
  int _lastReceivedSequence = 0;

  int get lastSentSequence => _lastSentSequence;
  int get lastReceivedSequence => _lastReceivedSequence;

  Future<Uint8List> encode(Uint8List payload) {
    return _sendLock.synchronized(() async {
      return _encode(payload);
    });
  }

  Future<Uint8List> _encode(Uint8List payload) async {
    if (payload.length > maxPayloadBytes) {
      throw const AuthenticatedFrameException('payload_too_large');
    }
    if (_lastSentSequence >= 0x7fffffffffffffff) {
      throw const AuthenticatedFrameException('sequence_exhausted');
    }
    final sequence = _lastSentSequence + 1;
    final authenticatedBytes = _buildAuthenticatedBytes(sequence, payload);
    final mac = await Hmac.sha256().calculateMac(
      authenticatedBytes,
      secretKey: _sendKey,
    );
    final frame = BytesBuilder(copy: false)
      ..add(_magic)
      ..add(authenticatedBytes.sublist(_macDomain.length))
      ..add(mac.bytes);
    _lastSentSequence = sequence;
    return frame.takeBytes();
  }

  Future<Uint8List> decode(Uint8List frame) {
    return _receiveLock.synchronized(() async {
      return _decode(frame);
    });
  }

  Future<Uint8List> _decode(Uint8List frame) async {
    if (frame.length < _headerLength + _macLength) {
      throw const AuthenticatedFrameException('truncated');
    }
    if (!_constantTimeEquals(frame.sublist(0, 4), _magic)) {
      throw const AuthenticatedFrameException('invalid_magic');
    }
    final header = ByteData.sublistView(frame, 4, _headerLength);
    final sequence = header.getUint64(0);
    final payloadLength = header.getUint32(8);
    if (payloadLength > maxPayloadBytes) {
      throw const AuthenticatedFrameException('payload_too_large');
    }
    final expectedLength = _headerLength + payloadLength + _macLength;
    if (frame.length != expectedLength) {
      throw const AuthenticatedFrameException('invalid_length');
    }
    if (sequence != _lastReceivedSequence + 1) {
      throw const AuthenticatedFrameException('invalid_sequence');
    }

    final payload = Uint8List.sublistView(
      frame,
      _headerLength,
      _headerLength + payloadLength,
    );
    final authenticatedBytes = _buildAuthenticatedBytes(sequence, payload);
    final expectedMac = await Hmac.sha256().calculateMac(
      authenticatedBytes,
      secretKey: _receiveKey,
    );
    final actualMac = frame.sublist(_headerLength + payloadLength);
    if (!_constantTimeEquals(actualMac, expectedMac.bytes)) {
      throw const AuthenticatedFrameException('invalid_mac');
    }

    _lastReceivedSequence = sequence;
    return Uint8List.fromList(payload);
  }

  static Uint8List _buildAuthenticatedBytes(
    int sequence,
    List<int> payload,
  ) {
    final header = ByteData(12)
      ..setUint64(0, sequence)
      ..setUint32(8, payload.length);
    return (BytesBuilder(copy: false)
          ..add(_macDomain)
          ..add(header.buffer.asUint8List())
          ..add(payload))
        .takeBytes();
  }
}

bool _constantTimeEquals(List<int> first, List<int> second) {
  if (first.length != second.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < first.length; index += 1) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}
