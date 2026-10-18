import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
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

/// SHA-256 of a stream of bytes, in native code. Every file transfer runs
/// its bytes through this on both ends, so it uses the system's own
/// implementation where there is one: those use the CPU's SHA instructions
/// (CommonCrypto about 3 GB/s on an M4 against libsodium's 0.57; BCrypt
/// 188 MB/s against 110 on a 2015 Xeon without them). libsodium is the
/// fallback, and what Android uses.
final class NativeStreamingSha256 {
  NativeStreamingSha256() : _engine = _Sha256Engine.create();

  static const int digestLength = 32;

  _Sha256Engine? _engine;
  String? _digest;

  /// Which implementation this platform uses, for diagnostics and tests.
  static String get backend => _Sha256Engine.backendName;

  void add(List<int> bytes) {
    final engine = _engine;
    if (engine == null) {
      throw StateError('Cannot add bytes after checksum is closed');
    }
    if (bytes.isEmpty) {
      return;
    }
    final input = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (!engine.update(input)) {
      _release();
      throw StateError('Native SHA-256 update failed');
    }
  }

  String close() {
    final existing = _digest;
    if (existing != null) {
      return existing;
    }
    final value = _finish()
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    _digest = value;
    return value;
  }

  /// The digest as raw bytes, for callers that compare it rather than print
  /// it. Ends the checksum like [close].
  Uint8List closeBytes() => _finish();

  Uint8List _finish() {
    final engine = _engine;
    if (engine == null) {
      throw StateError('Native SHA-256 state is unavailable');
    }
    final output = calloc<Uint8>(digestLength);
    try {
      if (!engine.finish(output)) {
        throw StateError('Native SHA-256 finalization failed');
      }
      return Uint8List.fromList(output.asTypedList(digestLength));
    } finally {
      calloc.free(output);
      _release();
    }
  }

  void dispose() {
    _release();
  }

  void _release() {
    final engine = _engine;
    _engine = null;
    engine?.release();
  }
}

abstract class _Sha256Engine {
  /// The implementation is chosen once per isolate: the system's where it
  /// loads, else libsodium.
  static _Sha256Engine create() {
    final factory = _factory ??= _chooseFactory();
    try {
      return factory();
    } catch (_) {
      if (backendName == 'libsodium') {
        rethrow;
      }
      // The system's failed to start: libsodium from now on.
      backendName = 'libsodium';
      _factory = _SodiumSha256.new;
      return _SodiumSha256();
    }
  }

  static _Sha256Engine Function()? _factory;
  static String backendName = 'libsodium';

  static _Sha256Engine Function() _chooseFactory() {
    try {
      if (Platform.isMacOS || Platform.isIOS) {
        _CommonCryptoSha256.load();
        backendName = 'CommonCrypto';
        return _CommonCryptoSha256.new;
      }
      if (Platform.isWindows) {
        _BCryptSha256.load();
        backendName = 'BCrypt';
        return _BCryptSha256.new;
      }
      if (Platform.isLinux) {
        _OpenSslSha256.load();
        backendName = 'OpenSSL';
        return _OpenSslSha256.new;
      }
    } catch (_) {
      // Not there (an unusual Linux without libcrypto): libsodium.
    }
    backendName = 'libsodium';
    return _SodiumSha256.new;
  }

  bool update(Uint8List input);

  /// Writes the digest to [output] and frees the state.
  bool finish(Pointer<Uint8> output);

  void release();
}

final class _SodiumSha256 extends _Sha256Engine {
  _SodiumSha256() {
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

  Pointer<Void>? _state;

  @override
  bool update(Uint8List input) =>
      _sha256Update(_state!, input.address, input.length) == 0;

  @override
  bool finish(Pointer<Uint8> output) => _sha256Final(_state!, output) == 0;

  @override
  void release() {
    final state = _state;
    _state = null;
    if (state != null) {
      calloc.free(state);
    }
  }
}

/// A system implementation reached through a looked-up function, which
/// needs native memory: input is copied into a buffer of its own first
/// (much faster than the hashing itself).
abstract class _NativeBufferEngine extends _Sha256Engine {
  static const _maxBufferBytes = 4 * 1024 * 1024;
  Pointer<Uint8>? _buffer;
  int _bufferBytes = 0;

  bool feed(
    Uint8List input,
    bool Function(Pointer<Uint8> data, int length) consume,
  ) {
    final wanted = math.min(input.length, _maxBufferBytes);
    if (_bufferBytes < wanted) {
      freeBuffer();
      _buffer = malloc<Uint8>(wanted);
      _bufferBytes = wanted;
    }
    final buffer = _buffer!;
    final view = buffer.asTypedList(_bufferBytes);
    for (var offset = 0; offset < input.length; offset += _bufferBytes) {
      final end = math.min(offset + _bufferBytes, input.length);
      view.setRange(0, end - offset, input, offset);
      if (!consume(buffer, end - offset)) {
        return false;
      }
    }
    return true;
  }

  void freeBuffer() {
    final buffer = _buffer;
    _buffer = null;
    _bufferBytes = 0;
    if (buffer != null) {
      malloc.free(buffer);
    }
  }
}

typedef _CcInit = Int Function(Pointer<Void>);
typedef _CcInitDart = int Function(Pointer<Void>);
typedef _CcUpdate = Int Function(Pointer<Void>, Pointer<Uint8>, Uint32);
typedef _CcUpdateDart = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _CcFinal = Int Function(Pointer<Uint8>, Pointer<Void>);
typedef _CcFinalDart = int Function(Pointer<Uint8>, Pointer<Void>);

/// Apple's CommonCrypto (in libSystem, so always there).
final class _CommonCryptoSha256 extends _NativeBufferEngine {
  _CommonCryptoSha256() {
    final context = calloc<Uint8>(_contextBytes).cast<Void>();
    if (_init(context) != 1) {
      calloc.free(context);
      throw StateError('CommonCrypto SHA-256 initialization failed');
    }
    _context = context;
  }

  // CC_SHA256_CTX is 104 bytes; rounded up.
  static const _contextBytes = 128;

  static late final _CcInitDart _init;
  static late final _CcUpdateDart _update;
  static late final _CcFinalDart _final;

  static void load() {
    final library = DynamicLibrary.process();
    _init = library.lookupFunction<_CcInit, _CcInitDart>('CC_SHA256_Init');
    _update = library.lookupFunction<_CcUpdate, _CcUpdateDart>(
      'CC_SHA256_Update',
    );
    _final = library.lookupFunction<_CcFinal, _CcFinalDart>('CC_SHA256_Final');
  }

  Pointer<Void>? _context;

  @override
  bool update(Uint8List input) =>
      feed(input, (data, length) => _update(_context!, data, length) == 1);

  @override
  bool finish(Pointer<Uint8> output) => _final(output, _context!) == 1;

  @override
  void release() {
    freeBuffer();
    final context = _context;
    _context = null;
    if (context != null) {
      calloc.free(context);
    }
  }
}

typedef _BcOpen =
    Int32 Function(Pointer<IntPtr>, Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _BcOpenDart =
    int Function(Pointer<IntPtr>, Pointer<Utf16>, Pointer<Utf16>, int);
typedef _BcCreate =
    Int32 Function(
      IntPtr,
      Pointer<IntPtr>,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint8>,
      Uint32,
      Uint32,
    );
typedef _BcCreateDart =
    int Function(
      int,
      Pointer<IntPtr>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      int,
    );
typedef _BcHash = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Uint32);
typedef _BcHashDart = int Function(int, Pointer<Uint8>, int, int);
typedef _BcDestroy = Int32 Function(IntPtr);
typedef _BcDestroyDart = int Function(int);

/// Windows' CNG (bcrypt.dll).
final class _BCryptSha256 extends _NativeBufferEngine {
  _BCryptSha256() {
    final handle = calloc<IntPtr>();
    try {
      // Since Windows 8 CNG keeps the hash object itself.
      if (_create(_algorithm, handle, nullptr, 0, nullptr, 0, 0) != 0) {
        throw StateError('BCrypt SHA-256 initialization failed');
      }
      _hash = handle.value;
    } finally {
      calloc.free(handle);
    }
  }

  static late final int _algorithm;
  static late final _BcCreateDart _create;
  static late final _BcHashDart _hashData;
  static late final _BcHashDart _finishHash;
  static late final _BcDestroyDart _destroy;

  static void load() {
    final library = DynamicLibrary.open('bcrypt.dll');
    final open = library.lookupFunction<_BcOpen, _BcOpenDart>(
      'BCryptOpenAlgorithmProvider',
    );
    _create = library.lookupFunction<_BcCreate, _BcCreateDart>(
      'BCryptCreateHash',
    );
    _hashData = library.lookupFunction<_BcHash, _BcHashDart>(
      'BCryptHashData',
      isLeaf: true,
    );
    _finishHash = library.lookupFunction<_BcHash, _BcHashDart>(
      'BCryptFinishHash',
    );
    _destroy = library.lookupFunction<_BcDestroy, _BcDestroyDart>(
      'BCryptDestroyHash',
    );
    final algorithm = calloc<IntPtr>();
    final name = 'SHA256'.toNativeUtf16();
    try {
      if (open(algorithm, name, nullptr, 0) != 0) {
        throw StateError('BCrypt SHA-256 is unavailable');
      }
      // Kept for the isolate's lifetime, as one is meant to.
      _algorithm = algorithm.value;
    } finally {
      calloc.free(name);
      calloc.free(algorithm);
    }
  }

  int? _hash;

  @override
  bool update(Uint8List input) =>
      feed(input, (data, length) => _hashData(_hash!, data, length, 0) == 0);

  @override
  bool finish(Pointer<Uint8> output) =>
      _finishHash(_hash!, output, NativeStreamingSha256.digestLength, 0) == 0;

  @override
  void release() {
    freeBuffer();
    final hash = _hash;
    _hash = null;
    if (hash != null) {
      _destroy(hash);
    }
  }
}

typedef _EvpNew = Pointer<Void> Function();
typedef _EvpMd = Pointer<Void> Function();
typedef _EvpInit = Int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _EvpInitDart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _EvpUpdate = Int Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _EvpUpdateDart = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _EvpFinal =
    Int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);
typedef _EvpFinalDart =
    int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);
typedef _EvpFree = Void Function(Pointer<Void>);
typedef _EvpFreeDart = void Function(Pointer<Void>);

/// The system's OpenSSL, which desktop distributions all have; looked up
/// at run time, so the app does not depend on it.
final class _OpenSslSha256 extends _NativeBufferEngine {
  _OpenSslSha256() {
    final context = _new();
    if (context == nullptr) {
      throw StateError('OpenSSL SHA-256 is unavailable');
    }
    if (_init(context, _sha256(), nullptr) != 1) {
      _free(context);
      throw StateError('OpenSSL SHA-256 initialization failed');
    }
    _context = context;
  }

  static late final Pointer<Void> Function() _new;
  static late final Pointer<Void> Function() _sha256;
  static late final _EvpInitDart _init;
  static late final _EvpUpdateDart _update;
  static late final _EvpFinalDart _final;
  static late final _EvpFreeDart _free;

  static void load() {
    DynamicLibrary? library;
    for (final name in ['libcrypto.so.3', 'libcrypto.so.1.1']) {
      try {
        library = DynamicLibrary.open(name);
        break;
      } on ArgumentError {
        // Try the next one.
      }
    }
    if (library == null) {
      throw StateError('OpenSSL is unavailable');
    }
    _new = library.lookupFunction<_EvpNew, _EvpNew>('EVP_MD_CTX_new');
    _sha256 = library.lookupFunction<_EvpMd, _EvpMd>('EVP_sha256');
    _init = library.lookupFunction<_EvpInit, _EvpInitDart>('EVP_DigestInit_ex');
    _update = library.lookupFunction<_EvpUpdate, _EvpUpdateDart>(
      'EVP_DigestUpdate',
      isLeaf: true,
    );
    _final = library.lookupFunction<_EvpFinal, _EvpFinalDart>(
      'EVP_DigestFinal_ex',
    );
    _free = library.lookupFunction<_EvpFree, _EvpFreeDart>('EVP_MD_CTX_free');
  }

  Pointer<Void>? _context;

  @override
  bool update(Uint8List input) =>
      feed(input, (data, length) => _update(_context!, data, length) == 1);

  @override
  bool finish(Pointer<Uint8> output) => _final(_context!, output, nullptr) == 1;

  @override
  void release() {
    freeBuffer();
    final context = _context;
    _context = null;
    if (context != null) {
      _free(context);
    }
  }
}
