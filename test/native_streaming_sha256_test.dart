import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/native_streaming_sha256.dart';

void main() {
  setUpAll(() async {
    await SodiumInit.init();
  });

  test('native streaming SHA-256 matches the protocol digest', () {
    final checksum = NativeStreamingSha256()
      ..add(Uint8List.fromList(<int>[0, 1, 2]))
      ..add(Uint8List.fromList(<int>[3, 4, 5, 6, 7]));

    const expected =
        '8a851ff82ee7048ad09ec3847f1ddf44944104d2cbd17ef4e3db22c6785a0d45';
    expect(checksum.close(), expected);
    expect(checksum.close(), expected);
  });

  test('the system\'s SHA-256 agrees with a reference across its buffer', () {
    // Larger than the 4 MiB copy buffer, and in uneven pieces.
    final data = Uint8List.fromList(
      List<int>.generate(9 * 1024 * 1024 + 13, (i) => (i * 31 + 7) & 255),
    );
    final checksum = NativeStreamingSha256();
    for (var offset = 0; offset < data.length; offset += 3 * 1024 * 1024 + 5) {
      checksum.add(
        Uint8List.sublistView(
          data,
          offset,
          offset + 3 * 1024 * 1024 + 5 < data.length
              ? offset + 3 * 1024 * 1024 + 5
              : data.length,
        ),
      );
    }
    expect(checksum.close(), crypto.sha256.convert(data).toString());
    if (Platform.isMacOS || Platform.isIOS) {
      expect(NativeStreamingSha256.backend, 'CommonCrypto');
    } else if (Platform.isWindows) {
      expect(NativeStreamingSha256.backend, 'BCrypt');
    }
  });

  test('streaming checksum enables native SHA-256 without wire changes', () {
    StreamingChecksum.installNativeSha256Acceleration();
    final checksum = StreamingChecksum()..add(<int>[0, 1, 2, 3]);

    const expected =
        '054edec1d0211f624fed0cbca9d4f9400b0e491c43742af2c5b0abebf0c990d8';
    expect(checksum.close(), expected);
    expect(checksum.close(), expected);
  });
}
