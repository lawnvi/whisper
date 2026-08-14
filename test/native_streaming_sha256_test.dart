import 'dart:typed_data';

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

  test('streaming checksum enables native SHA-256 without wire changes', () {
    StreamingChecksum.installNativeSha256Acceleration();
    final checksum = StreamingChecksum()..add(<int>[0, 1, 2, 3]);

    const expected =
        '054edec1d0211f624fed0cbca9d4f9400b0e491c43742af2c5b0abebf0c990d8';
    expect(checksum.close(), expected);
    expect(checksum.close(), expected);
  });
}
