import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';
import 'package:whisper/helper/parallel_streaming_checksum.dart';
import 'package:whisper/socket/file_path_policy.dart';

/// Run with `dart run tool/transfer_completion_benchmark.dart 1024`.
/// Measures local receive/finalization work; this is not a network benchmark.
Future<void> main(List<String> arguments) async {
  final mebibytes = arguments.isEmpty ? 256 : int.parse(arguments.single);
  if (mebibytes <= 0) throw ArgumentError('File size must be positive');
  await SodiumInit.init();
  final root = await Directory.systemTemp.createTemp(
    'whisper-completion-bench-',
  );
  final temp = File('${root.path}/received.part');
  final payload = Uint8List(1024 * 1024);
  for (var i = 0; i < payload.length; i++) {
    payload[i] = (i * 31 + 7) & 0xff;
  }
  final checksum = await ParallelStreamingChecksum.start();
  VerifiedTransferSnapshot? snapshot;
  DownloadFileReservation? reservation;
  final timings = <String, Object>{'mib': mebibytes};
  final timer = Stopwatch();
  try {
    final writer = await temp.open(mode: FileMode.write);
    timer.start();
    try {
      for (var i = 0; i < mebibytes; i++) {
        await writer.writeFrom(payload);
        await checksum.add(payload);
      }
      timings['receive_write_ms'] = timer.elapsedMicroseconds / 1000;
      timer.reset();
      await writer.flush();
    } finally {
      await writer.close();
    }
    timings['flush_ms'] = timer.elapsedMicroseconds / 1000;
    timer.reset();
    final digest = await checksum.close();
    timings['checksum_tail_ms'] = timer.elapsedMicroseconds / 1000;
    timer.reset();
    snapshot = await VerifiedTransferSnapshot.openFromStreamingDigest(
      temp,
      expectedSize: mebibytes * payload.length,
      streamingSha256: digest,
    );
    timings['seal_ms'] = timer.elapsedMicroseconds / 1000;
    timer.reset();
    reservation = await publishVerifiedDownload(snapshot, root, 'received.bin');
    final published = File(reservation.path);
    timings['publication'] = reservation.sourceWasMoved
        ? 'exclusive_move'
        : reservation.sourceWasLinked
        ? 'exclusive_link'
        : 'copy';
    timings['publish_ms'] = timer.elapsedMicroseconds / 1000;
    timings['published_bytes'] = await published.length();
    timings['sha256'] = digest;
    await releaseDownloadReservation(reservation);
    reservation = null;
    print(const JsonEncoder.withIndent('  ').convert(timings));
  } finally {
    await snapshot?.close();
    if (reservation != null) await discardDownloadReservation(reservation);
    await checksum.dispose();
    await root.delete(recursive: true);
  }
}
