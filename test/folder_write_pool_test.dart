import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/socket/folder_transfer_manifest.dart';
import 'package:whisper/socket/folder_transfer_scan.dart';
import 'package:whisper/socket/folder_transfer_sink.dart';
import 'package:whisper/socket/folder_transfer_source.dart';
import 'package:whisper/socket/folder_write_pool.dart';

Uint8List _pattern(int length, int seed) {
  final random = math.Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

void _writeTree(Directory root, Map<String, List<int>> files) {
  for (final entry in files.entries) {
    final file = File(p.join(root.path, entry.key));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(entry.value);
  }
}

/// Every file below [root] by relative path, plus directories as `path/`.
Map<String, String> _snapshot(Directory root) {
  final result = <String, String>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    final relative = p
        .relative(entity.path, from: root.path)
        .replaceAll(r'\', '/');
    if (entity is Directory) {
      result['$relative/'] = '';
    } else if (entity is File) {
      result[relative] = sha256.convert(entity.readAsBytesSync()).toString();
    }
  }
  return result;
}

void _expectSameTimes(Directory source, Directory received) {
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relative = p.relative(entity.path, from: source.path);
    expect(
      File(p.join(received.path, relative)).lastModifiedSync(),
      entity.lastModifiedSync(),
      reason: relative,
    );
  }
}

FolderReceiveConfig _config(
  Directory staging,
  FolderScanResult scan, {
  int checkpointIntervalBytes = 1 << 30,
  int checkpointIntervalMs = 1 << 30,
  int writeWorkers = 0,
}) => FolderReceiveConfig(
  stagingPath: staging.path,
  streamSize: scan.streamSize,
  manifestLength: scan.manifest.length,
  manifestSha256: scan.manifestSha256,
  fileCount: scan.fileCount,
  directoryCount: scan.directoryCount,
  totalBytes: scan.totalBytes,
  caseInsensitiveNames: false,
  pathSeparator: Platform.pathSeparator,
  checkpointIntervalBytes: checkpointIntervalBytes,
  checkpointIntervalMs: checkpointIntervalMs,
  writeWorkers: writeWorkers,
);

Directory _tree(Directory staging) =>
    Directory(p.join(staging.path, folderStagingTreeName));

/// Keeps the files it is handed, so a test decides which of them reach the
/// disk and in what order.
final class _HeldWrites implements FolderDeferredWrites {
  _HeldWrites({this.maxFileBytes = 1024 * 1024});

  @override
  final int maxFileBytes;
  final List<FolderDeferredFile> pending = <FolderDeferredFile>[];
  bool disposed = false;

  @override
  void write(FolderDeferredFile file) => pending.add(file);

  @override
  void dispose() => disposed = true;

  /// Puts [file] on disk the way a worker does.
  void land(FolderDeferredFile file, {bool withTime = true}) {
    pending.remove(file);
    File(file.path).writeAsBytesSync(file.bytes);
    if (withTime && file.modifiedMs > 0) {
      File(file.path).setLastModifiedSync(
        DateTime.fromMillisecondsSinceEpoch(file.modifiedMs),
      );
    }
  }
}

void main() {
  late Directory temp;
  late Directory source;
  late Directory staging;
  final readers = <FolderStreamReader>[];
  final writers = <FolderStreamWriter>[];

  setUp(() {
    temp = Directory.systemTemp.createTempSync('whisper-folder-pool-');
    source = Directory(p.join(temp.path, 'source'))..createSync();
    staging = Directory(p.join(temp.path, 'staging'));
  });

  tearDown(() {
    for (final writer in writers) {
      writer.abandon();
    }
    for (final reader in readers) {
      reader.close();
    }
    writers.clear();
    readers.clear();
    temp.deleteSync(recursive: true);
  });

  final sampleFiles = <String, List<int>>{
    'readme.txt': utf8.encode('hello'),
    'empty.bin': const <int>[],
    'docs/guide.md': _pattern(3000, 1),
    'docs/deep/nested/data.bin': _pattern(70000, 2),
    'photos/a.jpg': _pattern(12345, 3),
    'photos/b.jpg': _pattern(1, 4),
    '中文 目录/文件.txt': utf8.encode('内容'),
  };

  Uint8List streamOf(FolderScanResult scan) {
    final reader = FolderStreamReader(
      rootPath: source.path,
      manifest: FolderManifest.parse(
        scan.manifest,
        pathSeparator: Platform.pathSeparator,
      ),
    );
    readers.add(reader);
    final stream = Uint8List(scan.streamSize);
    reader.fill(stream, 0, 0, stream.length);
    return stream;
  }

  FolderStreamWriter writerWith(
    FolderReceiveConfig config,
    FolderDeferredWrites? deferred,
  ) {
    final writer = FolderStreamWriter(config, deferred: deferred);
    writers.add(writer);
    return writer;
  }

  void feed(FolderStreamWriter writer, Uint8List stream, {int chunk = 4096}) {
    var offset = writer.processedOffset;
    while (offset < stream.length) {
      final end = math.min(stream.length, offset + chunk);
      writer.add(Uint8List.sublistView(stream, offset, end));
      offset = end;
    }
  }

  group('small files written away from the stream', () {
    test('arrive intact in whatever order they reach the disk', () {
      _writeTree(source, sampleFiles);
      final scan = scanFolderForTransfer(source.path);
      final stream = streamOf(scan);
      final expected = _snapshot(source);

      for (final chunk in <int>[1, 33, 4096, 1 << 20]) {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
        final held = _HeldWrites();
        final writer = writerWith(_config(staging, scan), held)..open();
        feed(writer, stream, chunk: chunk);

        expect(held.pending, hasLength(sampleFiles.length));
        expect(writer.processedOffset, scan.streamSize);
        expect(writer.isComplete, isFalse, reason: 'nothing is on disk yet');
        expect(writer.deferredBytes, scan.totalBytes);

        for (final file in held.pending.reversed.toList()) {
          held.land(file);
          writer.settleDeferred(file.file);
        }

        expect(writer.isComplete, isTrue, reason: 'chunk $chunk');
        expect(writer.durableOffset, scan.streamSize);
        expect(writer.deferredBytes, 0);
        expect(writer.summary.filesWritten, sampleFiles.length);
        expect(writer.summary.filesSkipped, 0);
        writer.close();
        expect(held.disposed, isTrue);
        expect(_snapshot(_tree(staging)), expected, reason: 'chunk $chunk');
        _expectSameTimes(source, _tree(staging));
      }
    });

    test('a file over the limit is written as it arrives', () {
      _writeTree(source, <String, List<int>>{
        'a-small.bin': _pattern(100, 1),
        'b-large.bin': _pattern(5000, 2),
        'c-small.bin': _pattern(100, 3),
      });
      final scan = scanFolderForTransfer(source.path);
      final held = _HeldWrites(maxFileBytes: 1000);
      final writer = writerWith(_config(staging, scan), held)..open();
      feed(writer, streamOf(scan));

      expect(held.pending.map((file) => p.basename(file.path)), <String>[
        'a-small.bin',
        'c-small.bin',
      ]);
      expect(
        File(p.join(_tree(staging).path, 'b-large.bin')).lengthSync(),
        5000,
      );
      // The large file is on disk, but the small one ahead of it is not.
      writer.checkpoint();
      expect(writer.durableOffset, scan.manifest.length);
    });

    test('a checkpoint stops at the first file still on its way', () {
      _writeTree(source, <String, List<int>>{
        for (var index = 0; index < 6; index += 1)
          'f$index.bin': _pattern(200 + index, index),
      });
      final scan = scanFolderForTransfer(source.path);
      final manifest = FolderManifest.parse(scan.manifest);
      final held = _HeldWrites();
      final writer = writerWith(_config(staging, scan), held)..open();
      feed(writer, streamOf(scan));
      final files = held.pending.toList();

      writer.checkpoint();
      expect(writer.durableOffset, manifest.fileStart(0));

      // Later files landing first move nothing.
      for (final index in <int>[3, 1, 2]) {
        held.land(files[index]);
        writer.settleDeferred(files[index].file);
      }
      writer.checkpoint();
      expect(writer.durableOffset, manifest.fileStart(0));

      held.land(files[0]);
      writer.settleDeferred(files[0].file);
      writer.checkpoint();
      expect(writer.durableOffset, manifest.fileStart(4));
      expect(writer.isComplete, isFalse);

      for (final index in <int>[5, 4]) {
        held.land(files[index]);
        writer.settleDeferred(files[index].file);
      }
      expect(writer.isComplete, isTrue);
      expect(writer.durableOffset, scan.streamSize);
    });

    test('a file still being gathered is not counted as written', () {
      _writeTree(source, <String, List<int>>{
        'a.bin': _pattern(300, 1),
        'b.bin': _pattern(300, 2),
      });
      final scan = scanFolderForTransfer(source.path);
      final manifest = FolderManifest.parse(scan.manifest);
      final stream = streamOf(scan);
      final held = _HeldWrites();
      final writer = writerWith(_config(staging, scan), held)..open();

      writer.add(Uint8List.sublistView(stream, 0, manifest.fileStart(1) + 120));
      held.land(held.pending.single);
      writer.settleDeferred(0);
      writer.checkpoint();

      expect(writer.processedOffset, manifest.fileStart(1) + 120);
      expect(writer.durableOffset, manifest.fileStart(1));
    });

    test('progress comes due on its own once the writes are done', () async {
      _writeTree(source, <String, List<int>>{
        'a.bin': _pattern(300, 1),
        'b.bin': _pattern(300, 2),
      });
      final scan = scanFolderForTransfer(source.path);
      final manifest = FolderManifest.parse(scan.manifest);
      final stream = streamOf(scan);
      final held = _HeldWrites();
      final writer = writerWith(
        _config(staging, scan, checkpointIntervalMs: 30),
        held,
      )..open();
      writer.add(Uint8List.sublistView(stream, 0, manifest.fileStart(1) + 5));
      held.land(held.pending.single);
      writer.settleDeferred(0);
      final before = writer.durableOffset;

      writer.checkpointIfDue();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      writer.checkpointIfDue();

      expect(before, lessThan(manifest.fileStart(1)));
      expect(writer.durableOffset, manifest.fileStart(1));
    });

    test('a file that cannot be written is left out', () {
      _writeTree(source, sampleFiles);
      final scan = scanFolderForTransfer(source.path);
      final held = _HeldWrites();
      final writer = writerWith(_config(staging, scan), held)..open();
      feed(writer, streamOf(scan));

      for (final file in held.pending.toList()) {
        if (p.basename(file.path) == 'a.jpg') {
          held.pending.remove(file);
          writer.settleDeferred(
            file.file,
            failure: const FolderWriteFailure(
              diskFull: false,
              description: 'refused',
            ),
          );
        } else {
          held.land(file);
          writer.settleDeferred(file.file);
        }
      }

      expect(writer.isComplete, isTrue);
      final summary = writer.summary;
      expect(summary.filesWritten, sampleFiles.length - 1);
      expect(summary.filesSkipped, 1);
      expect(summary.skipped.single.path, 'photos/a.jpg');
      expect(summary.skipped.single.reason, FolderSkipReason.writeFailed);
    });

    test('a full disk ends the transfer', () {
      _writeTree(source, sampleFiles);
      final scan = scanFolderForTransfer(source.path);
      final held = _HeldWrites();
      final writer = writerWith(_config(staging, scan), held)..open();
      feed(writer, streamOf(scan));

      expect(
        () => writer.settleDeferred(
          held.pending.first.file,
          failure: const FolderWriteFailure(
            diskFull: true,
            description: 'no space',
          ),
        ),
        throwsA(
          isA<FolderReceiveException>().having(
            (error) => error.kind,
            'kind',
            FolderReceiveFailureKind.storage,
          ),
        ),
      );
    });

    test('a damaged file is never handed over, nor an older copy kept', () {
      _writeTree(source, <String, List<int>>{
        'a.bin': _pattern(500, 5),
        'b.bin': _pattern(500, 6),
      });
      final scan = scanFolderForTransfer(source.path);
      final stream = streamOf(scan);
      stream[scan.manifest.length + 3] ^= 0xff;
      final held = _HeldWrites();
      final writer = writerWith(_config(staging, scan), held)..open();
      // What an earlier attempt could have left where the file goes.
      writer.add(Uint8List.sublistView(stream, 0, scan.manifest.length));
      File(p.join(_tree(staging).path, 'a.bin')).writeAsBytesSync(<int>[1, 2]);
      feed(writer, stream);

      expect(held.pending.map((file) => p.basename(file.path)), <String>[
        'b.bin',
      ]);
      held.land(held.pending.single);
      writer.settleDeferred(1);

      expect(writer.isComplete, isTrue);
      expect(writer.summary.skipped.single.path, 'a.bin');
      expect(writer.summary.skipped.single.reason, FolderSkipReason.integrity);
      expect(_snapshot(_tree(staging)).keys, <String>['b.bin']);
    });

    test('a restart continues at the first file that never landed', () {
      _writeTree(source, <String, List<int>>{
        for (var index = 0; index < 8; index += 1)
          'f$index.bin': _pattern(400 + index, index),
      });
      final scan = scanFolderForTransfer(source.path);
      final manifest = FolderManifest.parse(scan.manifest);
      final stream = streamOf(scan);
      final expected = _snapshot(source);
      final held = _HeldWrites();
      final first = writerWith(_config(staging, scan), held)..open();
      feed(first, stream);
      final files = held.pending.toList();
      // Files 0, 1, 2 and 5 landed, the first two without their dates; 3
      // never did. Then the process is gone.
      held.land(files[0], withTime: false);
      held.land(files[1], withTime: false);
      held.land(files[2]);
      held.land(files[5]);
      for (final index in <int>[0, 1, 2, 5]) {
        first.settleDeferred(files[index].file);
      }
      first.abandon();

      final second = writerWith(_config(staging, scan), null);
      final resume = second.open();
      expect(resume.processedOffset, manifest.trailerStart(2));
      expect(resume.durableOffset, resume.processedOffset);
      feed(second, stream);

      expect(second.isComplete, isTrue);
      expect(second.summary.filesWritten, scan.fileCount);
      expect(second.summary.filesSkipped, 0);
      second.close();
      expect(_snapshot(_tree(staging)), expected);
      _expectSameTimes(source, _tree(staging));
    });

    test('a clean stop records only what is on disk', () {
      _writeTree(source, <String, List<int>>{
        for (var index = 0; index < 5; index += 1)
          'f$index.bin': _pattern(400 + index, index),
      });
      final scan = scanFolderForTransfer(source.path);
      final manifest = FolderManifest.parse(scan.manifest);
      final stream = streamOf(scan);
      final held = _HeldWrites();
      final first = writerWith(_config(staging, scan), held)..open();
      feed(first, stream);
      final files = held.pending.toList();
      held.land(files[0]);
      first.settleDeferred(files[0].file);
      first.close();

      // A file that lands after the stop changes nothing.
      first.settleDeferred(files[1].file);

      final second = writerWith(_config(staging, scan), null);
      expect(second.open().processedOffset, manifest.fileStart(1));
      feed(second, stream);
      expect(second.isComplete, isTrue);
      second.close();
      expect(_snapshot(_tree(staging)), _snapshot(source));
    });
  });

  group('write pool', () {
    Map<String, List<int>> manySmallFiles() => <String, List<int>>{
      ...sampleFiles,
      for (var directory = 0; directory < 6; directory += 1)
        for (var index = 0; index < 60; index += 1)
          'many/d$directory/f$index.txt': _pattern(
            (directory * 60 + index) * 7 % 3000,
            directory * 100 + index,
          ),
      'large/video.bin': _pattern(1500000, 77),
    };

    test('a folder of small files arrives intact through it', () async {
      _writeTree(source, manySmallFiles());
      final scan = scanFolderForTransfer(source.path);
      final stream = streamOf(scan);
      final session = await FolderReceiveSession.start(
        _config(staging, scan, writeWorkers: 3),
      );
      final reports = <FolderReceiveProgress>[];
      session.onProgress = reports.add;

      for (var offset = 0; offset < stream.length; offset += 300000) {
        session.add(
          Uint8List.sublistView(
            stream,
            offset,
            math.min(stream.length, offset + 300000),
          ),
        );
      }
      final summary = await session.finished;
      await session.close();

      expect(summary.filesWritten, scan.fileCount);
      expect(summary.filesSkipped, 0);
      expect(session.latest.durableOffset, scan.streamSize);
      expect(
        reports.every(
          (report) => report.durableOffset <= report.processedOffset,
        ),
        isTrue,
      );
      expect(_snapshot(_tree(staging)), _snapshot(source));
      _expectSameTimes(source, _tree(staging));
    });

    test('what is written becomes durable without more data', () async {
      _writeTree(source, manySmallFiles());
      final scan = scanFolderForTransfer(source.path);
      final manifest = FolderManifest.parse(scan.manifest);
      final stream = streamOf(scan);
      final session = await FolderReceiveSession.start(
        _config(staging, scan, checkpointIntervalMs: 50, writeWorkers: 2),
      );
      addTearDown(session.close);
      // Everything but the end of the last file, which keeps the stream
      // open with nothing more arriving.
      final cut = scan.streamSize - 5;
      session.add(Uint8List.sublistView(stream, 0, cut));

      final settled = manifest.fileStart(scan.fileCount - 1);
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (session.latest.durableOffset < settled &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(session.latest.durableOffset, greaterThanOrEqualTo(settled));
      expect(session.latest.durableOffset, lessThanOrEqualTo(cut));
    });

    test('closing with files still on their way can be continued', () async {
      _writeTree(source, manySmallFiles());
      final scan = scanFolderForTransfer(source.path);
      final stream = streamOf(scan);
      final cut = scan.streamSize * 2 ~/ 3;

      final first = await FolderReceiveSession.start(
        _config(staging, scan, writeWorkers: 3),
      );
      first.add(Uint8List.sublistView(stream, 0, cut));
      await first.close();
      await expectLater(first.finished, throwsA(isA<FolderReceiveException>()));
      // The workers have let go: nothing changes under staging any more.
      final left = _snapshot(_tree(staging));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(_snapshot(_tree(staging)), left);

      final second = await FolderReceiveSession.start(
        _config(staging, scan, writeWorkers: 3),
      );
      final resumeAt = second.resume.processedOffset;
      expect(resumeAt, lessThanOrEqualTo(cut));
      second.add(Uint8List.sublistView(stream, resumeAt));
      final summary = await second.finished;
      await second.close();

      expect(summary.filesSkipped, 0);
      expect(summary.filesWritten, scan.fileCount);
      expect(_snapshot(_tree(staging)), _snapshot(source));
      _expectSameTimes(source, _tree(staging));
    });

    test('reports each file as written or as failed', () async {
      final settled = <int, FolderWriteFailure?>{};
      final done = Completer<void>();
      final pool = FolderWritePool(
        workers: 2,
        onSettled: (file, failure) {
          settled[file] = failure;
          if (settled.length == 3 && !done.isCompleted) done.complete();
        },
        onBroken: (description) => done.completeError(description),
      );
      addTearDown(pool.dispose);
      final modified = DateTime(2021, 3, 4, 5, 6, 7);

      pool.write(
        FolderDeferredFile(
          file: 0,
          path: p.join(temp.path, 'kept.bin'),
          bytes: _pattern(2000, 1),
          modifiedMs: modified.millisecondsSinceEpoch,
        ),
      );
      pool.write(
        FolderDeferredFile(
          file: 1,
          path: p.join(temp.path, 'missing', 'lost.bin'),
          bytes: _pattern(10, 2),
          modifiedMs: 0,
        ),
      );
      pool.write(
        FolderDeferredFile(
          file: 2,
          path: p.join(temp.path, 'empty.bin'),
          bytes: Uint8List(0),
          modifiedMs: 0,
        ),
      );
      await done.future.timeout(const Duration(seconds: 20));

      expect(settled[0], isNull);
      expect(settled[2], isNull);
      expect(settled[1], isNotNull);
      expect(settled[1]!.diskFull, isFalse);
      final kept = File(p.join(temp.path, 'kept.bin'));
      expect(kept.readAsBytesSync(), _pattern(2000, 1));
      expect(kept.lastModifiedSync(), modified);
      expect(File(p.join(temp.path, 'empty.bin')).lengthSync(), 0);
    });

    test('a pool that was never used is let go of at once', () {
      FolderWritePool(
        workers: 4,
        onSettled: (_, _) => fail('nothing was handed over'),
        onBroken: (description) => fail(description),
      ).dispose();
    });
  });
}
