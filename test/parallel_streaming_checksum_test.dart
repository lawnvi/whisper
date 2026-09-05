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

    await checksum.add(first);
    await checksum.add(second);

    expect(await checksum.close(), bytesChecksum(<int>[...first, ...second]));
  });

  test('can dispose a worker before producing a digest', () async {
    final checksum = await ParallelStreamingChecksum.start();
    await checksum.add(Uint8List(1024));

    await checksum.dispose();
  });

  test(
    'awaited producers bound the backlog without changing the digest',
    () async {
      const limit = 256 * 1024;
      final chunk = Uint8List(64 * 1024);
      final checksum = await ParallelStreamingChecksum.start(
        maxPendingBytes: limit,
      );
      addTearDown(checksum.dispose);
      for (var index = 0; index < 64; index++) {
        await checksum.add(chunk);
        expect(checksum.pendingBytes, lessThan(limit));
      }
      expect(
        await checksum.close(),
        bytesChecksum(Uint8List(chunk.length * 64)),
      );
    },
  );

  test('disposing releases a producer waiting for checksum capacity', () async {
    final checksum = await ParallelStreamingChecksum.start(maxPendingBytes: 1);
    final pending = checksum.add(Uint8List(1024 * 1024));
    final rejected = expectLater(pending, throwsStateError);
    await checksum.dispose();
    await rejected;
    await expectLater(checksum.add(<int>[1]), throwsStateError);
  });

  test('rejects an invalid backlog limit before starting a worker', () async {
    await expectLater(
      ParallelStreamingChecksum.start(maxPendingBytes: 0),
      throwsArgumentError,
    );
  });
}
