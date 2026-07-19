import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:synchronized/synchronized.dart';
import 'package:whisper/socket/aead_engine.dart';

final class AuthenticatedFrameException implements Exception {
  const AuthenticatedFrameException(this.code);

  final String code;

  @override
  String toString() => 'AuthenticatedFrameException($code)';
}

final class AuthenticatedFrameCodec {
  AuthenticatedFrameCodec._({
    required WhisperAeadKey sendKey,
    required WhisperAeadKey receiveKey,
    this.maxPayloadBytes = 16 * 1024 * 1024,
  }) : _sendKey = sendKey,
       _receiveKey = receiveKey {
    if (maxPayloadBytes < 0 || maxPayloadBytes > 0xffffffff) {
      throw ArgumentError.value(maxPayloadBytes, 'maxPayloadBytes');
    }
  }

  static Future<AuthenticatedFrameCodec> create({
    required SecretKey sendKey,
    required SecretKey receiveKey,
    int maxPayloadBytes = 16 * 1024 * 1024,
  }) async {
    if (maxPayloadBytes < 0 || maxPayloadBytes > 0xffffffff) {
      throw ArgumentError.value(maxPayloadBytes, 'maxPayloadBytes');
    }
    Uint8List? sendBytes;
    Uint8List? receiveBytes;
    try {
      sendBytes = Uint8List.fromList(await sendKey.extractBytes());
      receiveBytes = identical(sendKey, receiveKey)
          ? Uint8List.fromList(sendBytes)
          : Uint8List.fromList(await receiveKey.extractBytes());
    } catch (_) {
      sendBytes?.fillRange(0, sendBytes.length, 0);
      receiveBytes?.fillRange(0, receiveBytes.length, 0);
      rethrow;
    } finally {
      sendKey.destroy();
      if (!identical(receiveKey, sendKey)) {
        receiveKey.destroy();
      }
    }

    WhisperAeadKey? acceleratedSendKey;
    WhisperAeadKey? acceleratedReceiveKey;
    try {
      acceleratedSendKey = WhisperAead.takeKey(sendBytes);
      sendBytes = null;
      acceleratedReceiveKey = WhisperAead.takeKey(receiveBytes);
      receiveBytes = null;
      return AuthenticatedFrameCodec._(
        sendKey: acceleratedSendKey,
        receiveKey: acceleratedReceiveKey,
        maxPayloadBytes: maxPayloadBytes,
      );
    } catch (_) {
      acceleratedSendKey?.destroy();
      acceleratedReceiveKey?.destroy();
      rethrow;
    } finally {
      sendBytes?.fillRange(0, sendBytes.length, 0);
      receiveBytes?.fillRange(0, receiveBytes.length, 0);
    }
  }

  static const int _headerLength = 16;
  static const int _tagLength = 16;
  static const int overheadBytes = _headerLength + _tagLength;
  static final Uint8List _magic = Uint8List.fromList(ascii.encode('WAE1'));
  static final Uint8List _aeadDomain = Uint8List.fromList(
    ascii.encode('whisper-frame-aead-v1'),
  );

  final WhisperAeadKey _sendKey;
  final WhisperAeadKey _receiveKey;
  final int maxPayloadBytes;
  final Lock _sendLock = Lock();
  final Lock _receiveLock = Lock();

  int _lastSentSequence = 0;
  int _lastReceivedSequence = 0;
  bool _closed = false;

  int get lastSentSequence => _lastSentSequence;
  int get lastReceivedSequence => _lastReceivedSequence;

  Future<Uint8List> encode(Uint8List payload) {
    return _sendLock.synchronized(() async {
      return _encode(payload);
    });
  }

  Future<Uint8List> _encode(Uint8List payload) async {
    if (_closed) {
      throw const AuthenticatedFrameException('codec_closed');
    }
    if (payload.length > maxPayloadBytes) {
      throw const AuthenticatedFrameException('payload_too_large');
    }
    if (_lastSentSequence >= 0x7fffffffffffffff) {
      throw const AuthenticatedFrameException('sequence_exhausted');
    }
    final sequence = _lastSentSequence + 1;
    final header = _buildHeader(sequence, payload.length);
    final nonce = _nonceFor(sequence);
    final secretBox = _sendKey.encrypt(
      message: payload,
      nonce: nonce,
      additionalData: _buildAad(header),
    );
    if (secretBox.cipherText.length != payload.length ||
        secretBox.mac.length != _tagLength) {
      throw const AuthenticatedFrameException('invalid_cipher_output');
    }
    final frame = BytesBuilder(copy: false)
      ..add(header)
      ..add(secretBox.cipherText)
      ..add(secretBox.mac);
    _lastSentSequence = sequence;
    return frame.takeBytes();
  }

  Future<Uint8List> decode(Uint8List frame) {
    return _receiveLock.synchronized(() async {
      return _decode(frame);
    });
  }

  Future<Uint8List> _decode(Uint8List frame) async {
    if (_closed) {
      throw const AuthenticatedFrameException('codec_closed');
    }
    if (frame.length < overheadBytes) {
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
    final expectedLength = overheadBytes + payloadLength;
    if (frame.length != expectedLength) {
      throw const AuthenticatedFrameException('invalid_length');
    }
    if (sequence != _lastReceivedSequence + 1) {
      throw const AuthenticatedFrameException('invalid_sequence');
    }

    final cipherText = Uint8List.sublistView(
      frame,
      _headerLength,
      _headerLength + payloadLength,
    );
    final tag = Uint8List.sublistView(frame, _headerLength + payloadLength);
    final Uint8List clearText;
    try {
      clearText = _receiveKey.decrypt(
        cipherText: cipherText,
        mac: tag,
        nonce: _nonceFor(sequence),
        additionalData: _buildAad(
          Uint8List.sublistView(frame, 0, _headerLength),
        ),
      );
    } on WhisperAeadAuthenticationException {
      throw const AuthenticatedFrameException('invalid_authentication_tag');
    }

    _lastReceivedSequence = sequence;
    return clearText;
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _sendKey.destroy();
    if (!identical(_receiveKey, _sendKey)) {
      _receiveKey.destroy();
    }
  }

  static Uint8List _buildHeader(int sequence, int payloadLength) {
    final header = Uint8List(_headerLength);
    header.setRange(0, _magic.length, _magic);
    ByteData.sublistView(header)
      ..setUint64(4, sequence)
      ..setUint32(12, payloadLength);
    return header;
  }

  static Uint8List _buildAad(List<int> header) {
    return (BytesBuilder(copy: false)
          ..add(_aeadDomain)
          ..add(header))
        .takeBytes();
  }

  static Uint8List _nonceFor(int sequence) {
    final nonce = Uint8List(24);
    ByteData.sublistView(nonce).setUint64(16, sequence);
    return nonce;
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
