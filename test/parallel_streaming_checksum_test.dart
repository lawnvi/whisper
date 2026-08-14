import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/parallel_streaming_checksum.dart';

void main() {
  setUpAll(SodiumInit.init);

  test('hashes transferred chunks on a worker isolate in order', () async {
    final first = Uint8List.fromList(
      List<int>.generate(1024 * 1024, (index) => index & 0xff),
    );
    final second = Uint8List.fromList(
      List<int>.generate(128 * 1024, (index) => (index * 3) & 0xff),
    );
    final checksum = await ParallelStreamingChecksum.start();

    checksum
      ..add(first)
      ..add(second);

    expect(await checksum.close(), bytesChecksum(<int>[...first, ...second]));
  });

  test('can dispose a worker before producing a digest', () async {
    final checksum = await ParallelStreamingChecksum.start();
    checksum.add(Uint8List(1024));

    await checksum.dispose();
  });
}
