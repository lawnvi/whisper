import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:whisper/helper/native_streaming_sha256.dart';

/// SHA-256 over one file of a folder transfer. Uses libsodium where it loads
/// in the current isolate and the Dart implementation otherwise.
final class FolderFileDigest {
  FolderFileDigest() {
    if (_nativeAvailable != false) {
      try {
        _native = NativeStreamingSha256();
        _nativeAvailable = true;
        return;
      } on Object {
        _nativeAvailable = false;
      }
    }
    _input = sha256.startChunkedConversion(_output);
  }

  static bool? _nativeAvailable;

  NativeStreamingSha256? _native;
  final _DigestOutput _output = _DigestOutput();
  Sink<List<int>>? _input;

  void add(Uint8List bytes) {
    final native = _native;
    if (native != null) {
      native.add(bytes);
    } else {
      _input!.add(bytes);
    }
  }

  Uint8List close() {
    final native = _native;
    if (native != null) {
      _native = null;
      return native.closeBytes();
    }
    _input!.close();
    return Uint8List.fromList(_output.value!.bytes);
  }

  void dispose() {
    _native?.dispose();
    _native = null;
  }
}

final class _DigestOutput implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
