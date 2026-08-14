import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

@Native<Int Function()>(
  symbol: 'crypto_hash_sha256_statebytes',
  assetId: 'package:sodium/libsodium',
)
external int _sha256StateBytes();

@Native<Int Function(Pointer<Void>)>(
  symbol: 'crypto_hash_sha256_init',
  assetId: 'package:sodium/libsodium',
)
external int _sha256Init(Pointer<Void> state);

@Native<Int Function(Pointer<Void>, Pointer<Uint8>, Uint64)>(
  symbol: 'crypto_hash_sha256_update',
  assetId: 'package:sodium/libsodium',
  isLeaf: true,
)
external int _sha256Update(
  Pointer<Void> state,
  Pointer<Uint8> input,
  int length,
);

@Native<Int Function(Pointer<Void>, Pointer<Uint8>)>(
  symbol: 'crypto_hash_sha256_final',
  assetId: 'package:sodium/libsodium',
)
external int _sha256Final(Pointer<Void> state, Pointer<Uint8> output);

final class NativeStreamingSha256 {
  NativeStreamingSha256() {
    final stateBytes = _sha256StateBytes();
    if (stateBytes <= 0) {
      throw StateError('Native SHA-256 state is unavailable');
    }
    final state = calloc<Uint8>(stateBytes).cast<Void>();
    if (_sha256Init(state) != 0) {
      calloc.free(state);
      throw StateError('Native SHA-256 initialization failed');
    }
    _state = state;
  }

  static const int digestLength = 32;

  Pointer<Void>? _state;
  String? _digest;

  void add(List<int> bytes) {
    final state = _state;
    if (state == null) {
      throw StateError('Cannot add bytes after checksum is closed');
    }
    if (bytes.isEmpty) {
      return;
    }
    final input = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (_sha256Update(state, input.address, input.length) != 0) {
      _release();
      throw StateError('Native SHA-256 update failed');
    }
  }

  String close() {
    final existing = _digest;
    if (existing != null) {
      return existing;
    }
    final state = _state;
    if (state == null) {
      throw StateError('Native SHA-256 state is unavailable');
    }
    final output = calloc<Uint8>(digestLength);
    try {
      if (_sha256Final(state, output) != 0) {
        throw StateError('Native SHA-256 finalization failed');
      }
      final value = output
          .asTypedList(digestLength)
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      _digest = value;
      return value;
    } finally {
      calloc.free(output);
      _release();
    }
  }

  void dispose() {
    _release();
  }

  void _release() {
    final state = _state;
    _state = null;
    if (state != null) {
      calloc.free(state);
    }
  }
}
