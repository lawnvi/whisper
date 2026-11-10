import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:whisper/socket/aead_engine.dart';

/// The wire format of one encrypted UDP datagram beside a media WebSocket:
///
/// `WUD1` | lane id (8) | sequence (uint64, big-endian) | tag (16) | sealed
///
/// The lane id says which session and direction a datagram belongs to, so
/// one socket serves them all. Each direction has its own key, so the two ends never
/// use the same nonce under the same key. A datagram may be lost, repeated
/// or late: [DatagramOpener] takes each sequence once, within a window of
/// the newest.
abstract final class DatagramFormat {
  static const List<int> magic = <int>[0x57, 0x55, 0x44, 0x31];
  static const int laneIdOffset = 4;
  static const int laneIdBytes = 8;
  static const int sequenceOffset = 12;
  static const int tagOffset = 20;
  static const int tagBytes = 16;
  static const int overheadBytes = tagOffset + tagBytes;

  /// With the header, under the 1500-byte MTU of Ethernet and Wi-Fi, so no
  /// datagram is split on a LAN. Two packets of sound fit.
  static const int maxPayloadBytes = 1400;
}

/// Which way a datagram goes: from the side that dialed the WebSocket (the
/// source of input or sound) or back to it.
enum DatagramDirection { fromDialer, toDialer }

/// The keys and lane id of one session's datagrams, from what both ends
/// already share once the WebSocket is authenticated: the media key and the
/// one-time upgrade token (the channel binding).
final class DatagramKeys {
  DatagramKeys._(this._laneIds, this._fromDialer, this._toDialer);

  factory DatagramKeys.derive({
    required Uint8List mediaKey,
    required Uint8List channelBinding,
    required String namespace,
    required String sessionId,
  }) {
    if (mediaKey.length != 32 || channelBinding.length != 32) {
      throw ArgumentError('datagram keys need 32-byte key and binding');
    }
    if (namespace.isEmpty || sessionId.isEmpty) {
      throw ArgumentError('datagram keys need a namespace and session');
    }
    Uint8List derive(String label) {
      final context = BytesBuilder(copy: false)
        ..add(utf8.encode('whisper-datagram-v1\u0000$label\u0000'))
        ..add(utf8.encode('$namespace\u0000$sessionId\u0000'))
        ..add(channelBinding);
      return Uint8List.fromList(
        hashes.Hmac(hashes.sha256, mediaKey).convert(context.takeBytes()).bytes,
      );
    }

    Uint8List laneId(String label) => Uint8List.fromList(
      Uint8List.sublistView(derive(label), 0, DatagramFormat.laneIdBytes),
    );
    return DatagramKeys._(
      (laneId('lane-from-dialer'), laneId('lane-to-dialer')),
      WhisperAead.takeKey(derive('from-dialer')),
      WhisperAead.takeKey(derive('to-dialer')),
    );
  }

  final (Uint8List, Uint8List) _laneIds;
  final WhisperAeadKey _fromDialer;
  final WhisperAeadKey _toDialer;

  /// The id datagrams going [direction] carry.
  Uint8List laneId(DatagramDirection direction) =>
      direction == DatagramDirection.fromDialer ? _laneIds.$1 : _laneIds.$2;

  /// What the dialer seals with and the other end opens with, or back.
  DatagramSealer sealer(DatagramDirection direction) => DatagramSealer._(
    laneId(direction),
    direction == DatagramDirection.fromDialer ? _fromDialer : _toDialer,
  );

  DatagramOpener opener(DatagramDirection direction) => DatagramOpener._(
    laneId(direction),
    direction == DatagramDirection.fromDialer ? _fromDialer : _toDialer,
  );

  void destroy() {
    _fromDialer.destroy();
    _toDialer.destroy();
  }
}

Uint8List _nonce(int sequence) {
  final nonce = Uint8List(24);
  ByteData.sublistView(nonce).setUint64(16, sequence);
  return nonce;
}

final List<int> _aadDomain = utf8.encode('whisper-datagram-aead-v1\u0000');

Uint8List _aad(Uint8List header) => Uint8List(_aadDomain.length + header.length)
  ..setAll(0, _aadDomain)
  ..setAll(_aadDomain.length, header);

final class DatagramSealer {
  DatagramSealer._(this.laneId, this._key);

  final Uint8List laneId;
  final WhisperAeadKey _key;
  int _next = 0;

  Uint8List seal(Uint8List payload) {
    if (payload.length > DatagramFormat.maxPayloadBytes) {
      throw ArgumentError.value(payload.length, 'payload.length');
    }
    final sequence = _next++;
    final out = Uint8List(DatagramFormat.overheadBytes + payload.length)
      ..setAll(0, DatagramFormat.magic)
      ..setAll(DatagramFormat.laneIdOffset, laneId);
    ByteData.sublistView(
      out,
    ).setUint64(DatagramFormat.sequenceOffset, sequence);
    final header = Uint8List.sublistView(out, 0, DatagramFormat.tagOffset);
    _key.encryptInto(
      message: payload,
      cipherText: Uint8List.sublistView(out, DatagramFormat.overheadBytes),
      mac: Uint8List.sublistView(
        out,
        DatagramFormat.tagOffset,
        DatagramFormat.overheadBytes,
      ),
      nonce: _nonce(sequence),
      additionalData: _aad(header),
    );
    return out;
  }
}

/// Opens datagrams of one lane and direction. Each sequence is taken once;
/// one more than [window] behind the newest is refused, being either a
/// replay or too late to matter.
final class DatagramOpener {
  DatagramOpener._(this.laneId, this._key);

  static const int window = 1024;

  final Uint8List laneId;
  final WhisperAeadKey _key;
  final Uint32List _seen = Uint32List(window ~/ 32);
  int _newest = -1;

  /// The lane id of [datagram], or null when it is not one of ours.
  static Uint8List? laneIdOf(Uint8List datagram) {
    if (datagram.length < DatagramFormat.overheadBytes) return null;
    for (var i = 0; i < DatagramFormat.magic.length; i++) {
      if (datagram[i] != DatagramFormat.magic[i]) return null;
    }
    return Uint8List.sublistView(
      datagram,
      DatagramFormat.laneIdOffset,
      DatagramFormat.laneIdOffset + DatagramFormat.laneIdBytes,
    );
  }

  /// The payload, or null for a datagram that is not genuine, not this
  /// lane's, or already taken.
  Uint8List? open(Uint8List datagram) {
    final lane = laneIdOf(datagram);
    if (lane == null ||
        datagram.length >
            DatagramFormat.overheadBytes + DatagramFormat.maxPayloadBytes) {
      return null;
    }
    for (var i = 0; i < lane.length; i++) {
      if (lane[i] != laneId[i]) return null;
    }
    final sequence = ByteData.sublistView(
      datagram,
    ).getUint64(DatagramFormat.sequenceOffset);
    if (sequence < 0 || !_fresh(sequence)) return null;
    final Uint8List payload;
    try {
      payload = _key.decrypt(
        cipherText: Uint8List.sublistView(
          datagram,
          DatagramFormat.overheadBytes,
        ),
        mac: Uint8List.sublistView(
          datagram,
          DatagramFormat.tagOffset,
          DatagramFormat.overheadBytes,
        ),
        nonce: _nonce(sequence),
        additionalData: _aad(
          Uint8List.sublistView(datagram, 0, DatagramFormat.tagOffset),
        ),
      );
    } on WhisperAeadAuthenticationException {
      return null;
    }
    // Only a genuine datagram moves the window.
    _take(sequence);
    return payload;
  }

  bool _fresh(int sequence) {
    if (sequence > _newest) return true;
    if (_newest - sequence >= window) return false;
    final slot = sequence % window;
    return _seen[slot >> 5] & (1 << (slot & 31)) == 0;
  }

  void _take(int sequence) {
    if (sequence > _newest) {
      // Forget the slots the window slides past.
      final gap = sequence - _newest;
      if (gap >= window) {
        _seen.fillRange(0, _seen.length, 0);
      } else {
        for (var s = _newest + 1; s <= sequence; s++) {
          final slot = s % window;
          _seen[slot >> 5] &= ~(1 << (slot & 31));
        }
      }
      _newest = sequence;
    }
    final slot = sequence % window;
    _seen[slot >> 5] |= 1 << (slot & 31);
  }
}
