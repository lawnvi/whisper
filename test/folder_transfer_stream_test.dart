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

Uint8List _pattern(int length, int seed) {
  final random = math.Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

/// Writes [files] (relative path to content) and [directories] under [root].
void _writeTree(
  Directory root,
  Map<String, List<int>> files, {
  List<String> directories = const <String>[],
}) {
  for (final directory in directories) {
    Directory(p.join(root.path, directory)).createSync(recursive: true);
  }
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

FolderReceiveConfig _config(
  Directory staging,
  FolderScanResult scan, {
  bool caseInsensitiveNames = false,
  int checkpointIntervalBytes = 1 << 30,
  int checkpointIntervalMs = 1 << 30,
}) => FolderReceiveConfig(
  stagingPath: staging.path,
  streamSize: scan.streamSize,
  manifestLength: scan.manifest.length,
  manifestSha256: scan.manifestSha256,
  fileCount: scan.fileCount,
  directoryCount: scan.directoryCount,
  totalBytes: scan.totalBytes,
  caseInsensitiveNames: caseInsensitiveNames,
  pathSeparator: Platform.pathSeparator,
  checkpointIntervalBytes: checkpointIntervalBytes,
  checkpointIntervalMs: checkpointIntervalMs,
);

// Windows does not delete a folder while a file in it is open, so every
// reader and writer a test leaves behind is let go of before the cleanup.
final List<FolderStreamReader> _readers = <FolderStreamReader>[];
final List<FolderStreamWriter> _writers = <FolderStreamWriter>[];

FolderStreamReader _reader(Directory source, FolderScanResult scan) {
  final reader = FolderStreamReader(
    rootPath: source.path,
    manifest: FolderManifest.parse(
      scan.manifest,
      pathSeparator: Platform.pathSeparator,
    ),
  );
  _readers.add(reader);
  return reader;
}

FolderStreamWriter _writer(
  FolderReceiveConfig config, {
  void Function(FolderReceiveProgress progress)? onProgress,
}) {
  final writer = FolderStreamWriter(config, onProgress: onProgress);
  _writers.add(writer);
  return writer;
}

/// Every file under [received] carries the modification time of its source.
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

/// Pumps the stream from [reader] into [writer] in pieces of [chunk] bytes,
/// from [start] until [end] (the whole stream by default).
void _pump(
  FolderStreamReader reader,
  FolderStreamWriter writer, {
  required int chunk,
  int? start,
  int? end,
}) {
  final limit = end ?? reader.manifest.streamSize;
  var offset = start ?? writer.processedOffset;
  while (offset < limit) {
    final length = math.min(chunk, limit - offset);
    final buffer = Uint8List(length);
    reader.fill(buffer, 0, offset, length);
    writer.add(buffer);
    offset += length;
  }
}

Directory _tree(Directory staging) =>
    Directory(p.join(staging.path, folderStagingTreeName));

void main() {
  late Directory temp;
  late Directory source;
  late Directory staging;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('whisper-folder-stream-');
    source = Directory(p.join(temp.path, 'source'))..createSync();
    staging = Directory(p.join(temp.path, 'staging'));
  });

  tearDown(() {
    for (final writer in _writers) {
      writer.abandon();
    }
    for (final reader in _readers) {
      reader.close();
    }
    _writers.clear();
    _readers.clear();
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

  group('manifest', () {
    test('a scanned tree parses back with the same shape', () {
      _writeTree(source, sampleFiles, directories: <String>['hollow/inner']);

      final scan = scanFolderForTransfer(source.path);
      final manifest = FolderManifest.parse(scan.manifest);

      expect(scan.failure, isNull);
      expect(scan.fileCount, sampleFiles.length);
      expect(scan.skippedCount, 0);
      expect(manifest.fileCount, sampleFiles.length);
      expect(manifest.directoryCount, scan.directoryCount);
      expect(
        manifest.totalFileBytes,
        sampleFiles.values.fold<int>(0, (sum, bytes) => sum + bytes.length),
      );
      expect(manifest.streamSize, scan.streamSize);
      final paths = <String>{
        for (var entry = 0; entry < manifest.entryCount; entry += 1)
          manifest.isDirectory(entry)
              ? '${manifest.relativePath(entry)}/'
              : manifest.relativePath(entry),
      };
      expect(paths, containsAll(sampleFiles.keys));
      expect(paths, containsAll(<String>['hollow/', 'hollow/inner/']));
      for (var file = 0; file < manifest.fileCount; file += 1) {
        final path = manifest.relativePath(manifest.fileEntry(file));
        expect(manifest.fileSize(file), sampleFiles[path]!.length);
        expect(manifest.fileAt(manifest.fileStart(file)), file);
        expect(manifest.fileAt(manifest.fileStart(file + 1) - 1), file);
      }
      expect(manifest.fileAt(0), -1);
      expect(manifest.fileAt(manifest.manifestLength - 1), -1);
    });

    Uint8List build(void Function(FolderManifestBuilder builder) fill) {
      final builder = FolderManifestBuilder();
      fill(builder);
      return builder.build();
    }

    Uint8List name(String value) => utf8.encode(value);

    test('names that could leave the folder are rejected', () {
      for (final bad in <String>['..', '.', 'a/b', r'a\b', 'CON', 'x.', '']) {
        expect(
          () => FolderManifest.parse(
            build(
              (builder) => builder.addFile(
                parent: folderManifestRootParent,
                name: name(bad),
                size: 0,
                modifiedMs: 0,
              ),
            ),
          ),
          throwsA(isA<FolderManifestException>()),
          reason: bad,
        );
      }
    });

    test('a parent has to be an earlier directory', () {
      expect(
        () => FolderManifest.parse(
          build((builder) {
            builder.addFile(
              parent: folderManifestRootParent,
              name: name('a'),
              size: 0,
              modifiedMs: 0,
            );
            builder.addFile(parent: 0, name: name('b'), size: 0, modifiedMs: 0);
          }),
        ),
        throwsA(isA<FolderManifestException>()),
      );
      expect(
        () => FolderManifest.parse(
          build((builder) => builder.addDirectory(parent: 3, name: name('a'))),
        ),
        throwsA(isA<FolderManifestException>()),
      );
    });

    test('siblings have to be in order, which rules out duplicates', () {
      for (final names in <List<String>>[
        <String>['b', 'a'],
        <String>['a', 'a'],
      ]) {
        expect(
          () => FolderManifest.parse(
            build((builder) {
              for (final value in names) {
                builder.addFile(
                  parent: folderManifestRootParent,
                  name: name(value),
                  size: 0,
                  modifiedMs: 0,
                );
              }
            }),
          ),
          throwsA(isA<FolderManifestException>()),
          reason: '$names',
        );
      }
    });

    test('damaged bytes are rejected', () {
      _writeTree(source, sampleFiles);
      final manifest = scanFolderForTransfer(source.path).manifest;

      expect(
        () => FolderManifest.parse(
          Uint8List.sublistView(manifest, 0, manifest.length - 1),
        ),
        throwsA(isA<FolderManifestException>()),
      );
      expect(
        () => FolderManifest.parse(Uint8List.fromList(manifest)..[0] = 0),
        throwsA(isA<FolderManifestException>()),
      );
      // A total that no longer matches the entries.
      final wrongTotal = Uint8List.fromList(manifest);
      ByteData.sublistView(wrongTotal).setUint64(12, 1);
      expect(
        () => FolderManifest.parse(wrongTotal),
        throwsA(isA<FolderManifestException>()),
      );
    });

    test('a path nested too deeply is rejected', () {
      expect(
        () => FolderManifest.parse(
          build((builder) {
            var parent = folderManifestRootParent;
            for (var depth = 0; depth <= folderManifestMaxDepth; depth += 1) {
              parent = builder.addDirectory(parent: parent, name: name('d'));
            }
          }),
        ),
        throwsA(isA<FolderManifestException>()),
      );
    });

    test('names that differ only by case collide when asked to', () {
      final bytes = build((builder) {
        final upper = builder.addDirectory(
          parent: folderManifestRootParent,
          name: name('Docs'),
        );
        builder.addFile(
          parent: folderManifestRootParent,
          name: name('README'),
          size: 1,
          modifiedMs: 0,
        );
        final lower = builder.addDirectory(
          parent: folderManifestRootParent,
          name: name('docs'),
        );
        builder.addFile(
          parent: folderManifestRootParent,
          name: name('readme'),
          size: 2,
          modifiedMs: 0,
        );
        builder.addFile(parent: upper, name: name('a'), size: 3, modifiedMs: 0);
        builder.addFile(parent: lower, name: name('b'), size: 4, modifiedMs: 0);
      });

      final exact = FolderManifest.parse(bytes);
      final folded = FolderManifest.parse(bytes, caseInsensitiveNames: true);

      expect(exact.skippedFileCount, 0);
      expect(folded.skippedFileCount, 2);
      expect(
        <String>[
          for (var file = 0; file < folded.fileCount; file += 1)
            if (folded.isFileSkipped(file))
              folded.relativePath(folded.fileEntry(file)),
        ],
        <String>['readme', 'docs/b'],
      );
    });
  });

  group('scan', () {
    test('links, system files and unusable names stay out', () {
      _writeTree(source, <String, List<int>>{
        'keep.txt': <int>[1],
        '.DS_Store': <int>[2],
        'sub/Thumbs.db': <int>[3],
        'sub/desktop.ini': <int>[4],
        'sub/kept.bin': <int>[5],
      });
      if (!Platform.isWindows) {
        File(p.join(source.path, 'bad:name.txt')).writeAsBytesSync(<int>[6]);
        Link(p.join(source.path, 'link')).createSync(temp.path);
        Link(
          p.join(source.path, 'file-link'),
        ).createSync(p.join(source.path, 'keep.txt'));
      }

      final scan = scanFolderForTransfer(source.path);
      final manifest = FolderManifest.parse(scan.manifest);

      expect(<String>[
        for (var file = 0; file < manifest.fileCount; file += 1)
          manifest.relativePath(manifest.fileEntry(file)),
      ], unorderedEquals(<String>['keep.txt', 'sub/kept.bin']));
      if (!Platform.isWindows) {
        expect(scan.skippedCount, 3);
        expect(
          <String, FolderSkipReason>{
            for (final entry in scan.skipped) entry.path: entry.reason,
          },
          <String, FolderSkipReason>{
            'bad:name.txt': FolderSkipReason.invalidName,
            'link': FolderSkipReason.symlink,
            'file-link': FolderSkipReason.symlink,
          },
        );
      }
    });

    test('a tree with too many entries is refused', () {
      _writeTree(source, <String, List<int>>{
        for (var index = 0; index < 5; index += 1) 'f$index': <int>[index],
      });

      expect(
        scanFolderForTransfer(source.path, maxEntries: 4).failure,
        FolderScanFailure.tooManyEntries,
      );
      expect(
        scanFolderForTransfer(source.path, maxStreamSize: 100).failure,
        FolderScanFailure.tooLarge,
      );
      expect(
        scanFolderForTransfer(p.join(temp.path, 'missing')).failure,
        FolderScanFailure.unreadable,
      );
    });

    test('a tree deeper than a Windows path allows is still walked', () {
      // 300 characters below the folder; Windows stops listing at 260.
      final deep = List<String>.generate(
        12,
        (index) => 'level-$index-${'x' * 16}',
      );
      final leaf = File(p.joinAll(<String>[source.path, ...deep, 'leaf.txt']))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('deep');
      File(p.join(leaf.parent.path, 'second.txt')).writeAsStringSync('too');

      final scan = scanFolderForTransfer(source.path);
      final manifest = FolderManifest.parse(scan.manifest);

      expect(scan.skippedCount, 0);
      expect(scan.fileCount, 2);
      expect(
        manifest.relativePath(manifest.fileEntry(0)),
        '${deep.join('/')}/leaf.txt',
      );

      final writer = _writer(_config(staging, scan))..open();
      _pump(_reader(source, scan), writer, chunk: 4096);
      final summary = writer.summary;
      writer.close();
      expect(summary.filesWritten, 2);
      expect(
        File(
          p.joinAll(<String>[_tree(staging).path, ...deep, 'leaf.txt']),
        ).readAsStringSync(),
        'deep',
      );
    });

    test('an empty folder is a valid transfer', () {
      final scan = scanFolderForTransfer(source.path);

      expect(scan.failure, isNull);
      expect(scan.fileCount, 0);
      expect(scan.streamSize, scan.manifest.length);
    });
  });

  group('stream', () {
    test('arrives intact whatever the chunking', () {
      _writeTree(source, sampleFiles, directories: <String>['hollow/inner']);
      final scan = scanFolderForTransfer(source.path);
      final expected = _snapshot(source);

      for (final chunk in <int>[1, 7, 33, 4096, 1 << 20]) {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
        final writer = _writer(_config(staging, scan));
        expect(writer.open().processedOffset, 0);
        _pump(_reader(source, scan), writer, chunk: chunk);

        expect(writer.isComplete, isTrue, reason: 'chunk $chunk');
        expect(writer.summary.filesWritten, sampleFiles.length);
        expect(writer.summary.filesSkipped, 0);
        writer.close();
        expect(_snapshot(_tree(staging)), expected, reason: 'chunk $chunk');
      }
    });

    test('modification times are carried over', () {
      _writeTree(source, <String, List<int>>{
        'old.txt': <int>[1, 2, 3],
        // More files than a time is ever held back for.
        for (var index = 0; index < 60; index += 1)
          'many/f$index.txt': <int>[index],
      });
      final stamp = DateTime(2020, 5, 17, 8, 30);
      var minutes = 0;
      for (final entity in source.listSync(recursive: true)) {
        if (entity is File) {
          entity.setLastModifiedSync(stamp.add(Duration(minutes: ++minutes)));
        }
      }
      File(p.join(source.path, 'old.txt')).setLastModifiedSync(stamp);
      final scan = scanFolderForTransfer(source.path);

      final writer = _writer(_config(staging, scan))..open();
      _pump(_reader(source, scan), writer, chunk: 4096);
      writer.close();

      expect(
        File(p.join(_tree(staging).path, 'old.txt')).lastModifiedSync(),
        stamp,
      );
      _expectSameTimes(source, _tree(staging));
    });

    test('reading a stretch again gives the same bytes', () {
      _writeTree(source, sampleFiles);
      final scan = scanFolderForTransfer(source.path);
      final reader = _reader(source, scan);
      final whole = Uint8List(scan.streamSize);
      reader.fill(whole, 0, 0, whole.length);

      final again = Uint8List(scan.streamSize);
      final other = _reader(source, scan);
      // Backwards, in uneven pieces, so every file is entered mid-way.
      var end = scan.streamSize;
      while (end > 0) {
        final start = math.max(0, end - 997);
        other.fill(again, start, start, end - start);
        end = start;
      }
      expect(again, whole);
      // And once more through the first reader, which has every trailer.
      final replay = Uint8List(5000);
      final from = scan.manifest.length + 10;
      reader.fill(replay, 0, from, replay.length);
      expect(replay, Uint8List.sublistView(whole, from, from + replay.length));
    });

    test('a file that changed is left out and the rest still arrives', () {
      _writeTree(source, sampleFiles);
      final scan = scanFolderForTransfer(source.path);
      File(p.join(source.path, 'photos', 'a.jpg')).writeAsBytesSync(<int>[9]);
      File(p.join(source.path, 'docs', 'guide.md')).deleteSync();

      final reader = _reader(source, scan);
      final writer = _writer(_config(staging, scan))..open();
      _pump(reader, writer, chunk: 1000);
      final summary = writer.summary;
      writer.close();

      expect(summary.filesWritten, sampleFiles.length - 2);
      expect(summary.filesSkipped, 2);
      expect(
        <String, FolderSkipReason>{
          for (final entry in summary.skipped) entry.path: entry.reason,
        },
        <String, FolderSkipReason>{
          'photos/a.jpg': FolderSkipReason.sourceUnavailable,
          'docs/guide.md': FolderSkipReason.sourceUnavailable,
        },
      );
      expect(reader.takeUnavailableFiles(), hasLength(2));
      final received = _snapshot(_tree(staging));
      expect(received.containsKey('photos/a.jpg'), isFalse);
      expect(received.containsKey('docs/guide.md'), isFalse);
      expect(received['photos/b.jpg'], _snapshot(source)['photos/b.jpg']);
    });

    test('a folder that disappeared stops the stream', () {
      _writeTree(source, sampleFiles);
      final scan = scanFolderForTransfer(source.path);
      final reader = _reader(source, scan);
      source.deleteSync(recursive: true);

      expect(
        () => reader.fill(Uint8List(scan.streamSize), 0, 0, scan.streamSize),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a trailer that does not match drops only that file', () {
      _writeTree(source, <String, List<int>>{
        'a.bin': _pattern(500, 5),
        'b.bin': _pattern(500, 6),
      });
      final scan = scanFolderForTransfer(source.path);
      final stream = Uint8List(scan.streamSize);
      _reader(source, scan).fill(stream, 0, 0, stream.length);
      // Flip a byte inside the first file's data.
      stream[scan.manifest.length + 3] ^= 0xff;

      final writer = _writer(_config(staging, scan))..open();
      writer.add(stream);
      final summary = writer.summary;
      writer.close();

      expect(summary.filesWritten, 1);
      expect(summary.skipped.single.path, 'a.bin');
      expect(summary.skipped.single.reason, FolderSkipReason.integrity);
      expect(_snapshot(_tree(staging)).keys, <String>['b.bin']);
    });

    test('case collisions are skipped where the file system folds case', () {
      final builder = FolderManifestBuilder()
        ..addFile(
          parent: folderManifestRootParent,
          name: utf8.encode('A.txt'),
          size: 3,
          modifiedMs: 0,
        )
        ..addFile(
          parent: folderManifestRootParent,
          name: utf8.encode('a.txt'),
          size: 4,
          modifiedMs: 0,
        )
        ..addFile(
          parent: folderManifestRootParent,
          name: utf8.encode('z.txt'),
          size: 2,
          modifiedMs: 0,
        );
      final manifest = builder.build();
      Uint8List trailer(List<int> data) => Uint8List.fromList(<int>[
        folderTrailerStatusOk,
        ...sha256.convert(data).bytes,
      ]);
      final stream = Uint8List.fromList(<int>[
        ...manifest,
        ...<int>[1, 2, 3],
        ...trailer(<int>[1, 2, 3]),
        ...<int>[4, 5, 6, 7],
        ...trailer(<int>[4, 5, 6, 7]),
        ...<int>[8, 9],
        ...trailer(<int>[8, 9]),
      ]);
      final config = FolderReceiveConfig(
        stagingPath: staging.path,
        streamSize: stream.length,
        manifestLength: manifest.length,
        manifestSha256: sha256.convert(manifest).toString(),
        fileCount: 3,
        directoryCount: 0,
        totalBytes: 9,
        caseInsensitiveNames: true,
        pathSeparator: Platform.pathSeparator,
        checkpointIntervalBytes: 1 << 30,
      );

      final writer = _writer(config)..open();
      writer.add(stream);
      final summary = writer.summary;
      writer.close();

      expect(summary.filesWritten, 2);
      expect(summary.filesSkipped, 1);
      expect(summary.skipped.single.path, 'a.txt');
      expect(summary.skipped.single.reason, FolderSkipReason.nameCollision);
      expect(
        File(p.join(_tree(staging).path, 'A.txt')).readAsBytesSync(),
        <int>[1, 2, 3],
      );
      expect(
        File(p.join(_tree(staging).path, 'z.txt')).readAsBytesSync(),
        <int>[8, 9],
      );
    });

    test('a manifest that is not the announced one is refused', () {
      _writeTree(source, sampleFiles);
      final scan = scanFolderForTransfer(source.path);
      final stream = Uint8List(scan.manifest.length);
      _reader(source, scan).fill(stream, 0, 0, stream.length);
      stream[stream.length - 1] ^= 1;

      final writer = _writer(_config(staging, scan))..open();

      expect(
        () => writer.add(stream),
        throwsA(
          isA<FolderReceiveException>().having(
            (error) => error.kind,
            'kind',
            FolderReceiveFailureKind.manifest,
          ),
        ),
      );
      writer.close();
    });
  });

  group('resume', () {
    late FolderScanResult scan;
    late Map<String, String> expected;

    setUp(() {
      _writeTree(
        source,
        <String, List<int>>{...sampleFiles, 'big.bin': _pattern(400000, 7)},
        directories: <String>['hollow'],
      );
      scan = scanFolderForTransfer(source.path);
      expected = _snapshot(source);
    });

    /// Receives up to [cut], stops, then starts over on the same staging.
    void expectResumesAfter(int cut, {required bool cleanStop}) {
      final first = _writer(
        _config(staging, scan, checkpointIntervalBytes: 50000),
      )..open();
      _pump(_reader(source, scan), first, chunk: 777, end: cut);
      if (cleanStop) {
        first.close();
      } else {
        // Where a killed process leaves things: no last checkpoint, and
        // the newest files without their times.
        first.abandon();
      }

      final second = _writer(_config(staging, scan));
      final resume = second.open();
      expect(resume.processedOffset, lessThanOrEqualTo(cut));
      expect(resume.durableOffset, resume.processedOffset);
      _pump(_reader(source, scan), second, chunk: 1500);
      expect(second.isComplete, isTrue);
      expect(second.summary.filesSkipped, 0);
      expect(second.summary.filesWritten, scan.fileCount);
      second.close();
      expect(_snapshot(_tree(staging)), expected, reason: 'cut $cut');
      _expectSameTimes(source, _tree(staging));
    }

    test('from anywhere after a clean stop', () {
      final manifest = FolderManifest.parse(scan.manifest);
      final big = <int>[
        for (var file = 0; file < manifest.fileCount; file += 1)
          if (manifest.fileSize(file) == 400000) file,
      ].single;
      final cuts = <int>[
        0,
        10,
        scan.manifest.length - 1,
        scan.manifest.length,
        scan.manifest.length + 1,
        manifest.fileStart(big) + 1,
        manifest.fileStart(big) + 250000,
        manifest.trailerStart(big),
        manifest.trailerStart(big) + 5,
        manifest.fileStart(big + 1),
        scan.streamSize - 1,
        scan.streamSize,
      ];
      for (final cut in cuts) {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
        expectResumesAfter(cut, cleanStop: true);
      }
    });

    test('a clean stop inside a large file keeps what was received', () {
      final manifest = FolderManifest.parse(scan.manifest);
      final big = <int>[
        for (var file = 0; file < manifest.fileCount; file += 1)
          if (manifest.fileSize(file) == 400000) file,
      ].single;
      final cut = manifest.fileStart(big) + 250000;
      final first = _writer(_config(staging, scan))..open();
      _pump(_reader(source, scan), first, chunk: 4096, end: cut);
      first.close();

      final resume = _writer(_config(staging, scan)).open();

      expect(resume.processedOffset, cut);
    });

    test('after a stop that left no final checkpoint', () {
      for (final cut in <int>[
        scan.manifest.length + 5,
        scan.streamSize ~/ 2,
        scan.streamSize - 40,
      ]) {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
        expectResumesAfter(cut, cleanStop: false);
      }
    });

    test('a file that failed stays failed across a restart', () {
      File(p.join(source.path, 'photos', 'a.jpg')).deleteSync();
      final cut = scan.streamSize - 10;
      final first = _writer(_config(staging, scan))..open();
      _pump(_reader(source, scan), first, chunk: 500, end: cut);
      first.close();

      final second = _writer(_config(staging, scan))..open();
      _pump(_reader(source, scan), second, chunk: 500);
      final summary = second.summary;
      second.close();

      expect(summary.filesSkipped, 1);
      expect(summary.skipped.single.path, 'photos/a.jpg');
      expect(summary.filesWritten, scan.fileCount - 1);
    });

    test('staging that lost its tree is not taken as received', () {
      final first = _writer(_config(staging, scan))..open();
      _pump(_reader(source, scan), first, chunk: 4096);
      first.close();
      _tree(staging).deleteSync(recursive: true);

      final second = _writer(_config(staging, scan));
      final resume = second.open();

      expect(resume.processedOffset, scan.manifest.length);
      expect(second.isComplete, isFalse);
      _pump(_reader(source, scan), second, chunk: 4096);
      second.close();
      expect(_snapshot(_tree(staging)), expected);
    });

    test('staging for another manifest is started over', () {
      final first = _writer(_config(staging, scan))..open();
      _pump(_reader(source, scan), first, chunk: 4096);
      first.close();
      File(p.join(source.path, 'new.txt')).writeAsBytesSync(<int>[1]);
      final rescan = scanFolderForTransfer(source.path);

      final second = _writer(_config(staging, rescan));

      expect(second.open().processedOffset, 0);
      _pump(_reader(source, rescan), second, chunk: 4096);
      second.close();
      expect(_snapshot(_tree(staging)), _snapshot(source));
    });
  });

  group('checkpoints', () {
    test('are taken by bytes and reported as durable progress', () {
      _writeTree(source, <String, List<int>>{'big.bin': _pattern(300000, 8)});
      final scan = scanFolderForTransfer(source.path);
      final reports = <FolderReceiveProgress>[];
      final writer = _writer(
        _config(staging, scan, checkpointIntervalBytes: 100000),
        onProgress: reports.add,
      )..open();

      _pump(_reader(source, scan), writer, chunk: 10000);
      writer.close();

      final durable = reports.map((report) => report.durableOffset).toSet();
      expect(durable.length, greaterThanOrEqualTo(3));
      expect(durable.last, scan.streamSize);
      expect(reports.last.filesSettled, 1);
      expect(
        reports.every(
          (report) => report.durableOffset <= report.processedOffset,
        ),
        isTrue,
      );
    });

    test('are taken by time when the bytes are slow to add up', () async {
      _writeTree(source, <String, List<int>>{
        for (var index = 0; index < 50; index += 1) 'f$index.txt': <int>[index],
      });
      final scan = scanFolderForTransfer(source.path);
      final reports = <FolderReceiveProgress>[];
      final writer = _writer(
        _config(staging, scan, checkpointIntervalMs: 20),
        onProgress: reports.add,
      )..open();
      final reader = _reader(source, scan);

      final half = scan.streamSize ~/ 2;
      _pump(reader, writer, chunk: 64, end: half);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      _pump(reader, writer, chunk: 64, end: half + 64);
      writer.close();

      expect(
        reports.any(
          (report) =>
              report.durableOffset > 0 && report.durableOffset <= half + 64,
        ),
        isTrue,
      );
    });
  });

  group('workers', () {
    test('a folder goes through both isolates', () async {
      _writeTree(source, sampleFiles, directories: <String>['hollow']);
      final scan = scanFolderForTransfer(source.path);
      final manifestFile = File(p.join(temp.path, 'manifest'))
        ..writeAsBytesSync(scan.manifest);
      final folderSource = FolderTransferSource(
        rootPath: source.path,
        manifestPath: () async => manifestFile.path,
        manifestSha256: scan.manifestSha256,
        expectedSize: scan.streamSize,
      );
      addTearDown(folderSource.close);
      final session = await FolderReceiveSession.start(_config(staging, scan));
      final reports = <FolderReceiveProgress>[];
      session.onProgress = reports.add;

      expect(await folderSource.exists(), isTrue);
      expect(folderSource.filesBefore(0), isNull, reason: 'not opened yet');
      expect(await folderSource.length(), scan.streamSize);
      expect(session.resume.processedOffset, 0);
      // A file counts once the stream is past its trailer.
      final layout = FolderManifest.parse(scan.manifest);
      expect(folderSource.filesBefore(0), 0);
      expect(folderSource.filesBefore(layout.fileStart(0)), 0);
      expect(folderSource.filesBefore(layout.fileStart(1) - 1), 0);
      expect(folderSource.filesBefore(layout.fileStart(1)), 1);
      expect(folderSource.filesBefore(layout.fileStart(3) + 1), 3);
      expect(folderSource.filesBefore(scan.streamSize), scan.fileCount);
      var offset = 0;
      while (offset < scan.streamSize) {
        final length = math.min(300000, scan.streamSize - offset);
        session.add(await folderSource.readRange(offset, length));
        offset += length;
      }
      final summary = await session.finished;
      await session.close();

      expect(summary.filesWritten, sampleFiles.length);
      expect(summary.filesSkipped, 0);
      expect(session.latest.durableOffset, scan.streamSize);
      expect(session.latest.filesSettled, scan.fileCount);
      final counted = reports.map((report) => report.filesSettled).toList();
      for (var index = 1; index < counted.length; index += 1) {
        expect(counted[index], greaterThanOrEqualTo(counted[index - 1]));
      }
      expect(_snapshot(_tree(staging)), _snapshot(source));
    });

    test('the source reports files it could not send', () async {
      _writeTree(source, sampleFiles);
      final scan = scanFolderForTransfer(source.path);
      final manifestFile = File(p.join(temp.path, 'manifest'))
        ..writeAsBytesSync(scan.manifest);
      File(p.join(source.path, 'readme.txt')).deleteSync();
      final folderSource = FolderTransferSource(
        rootPath: source.path,
        manifestPath: () async => manifestFile.path,
        manifestSha256: scan.manifestSha256,
        expectedSize: scan.streamSize,
      );
      addTearDown(folderSource.close);

      await folderSource.readRange(0, scan.streamSize);

      expect(folderSource.unavailableFileCount, 1);
      final entries = await folderSource.unavailableEntries(limit: 10);
      expect(entries.single.path, 'readme.txt');
      expect(entries.single.reason, FolderSkipReason.sourceUnavailable);
    });

    test('a manifest that was swapped is not served', () async {
      _writeTree(source, sampleFiles);
      final scan = scanFolderForTransfer(source.path);
      final manifestFile = File(p.join(temp.path, 'manifest'))
        ..writeAsBytesSync(Uint8List.fromList(scan.manifest)..[5] ^= 1);
      final folderSource = FolderTransferSource(
        rootPath: source.path,
        manifestPath: () async => manifestFile.path,
        manifestSha256: scan.manifestSha256,
        expectedSize: scan.streamSize,
      );
      addTearDown(folderSource.close);

      await expectLater(
        folderSource.length(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('closing a session leaves staging to be continued', () async {
      _writeTree(source, <String, List<int>>{
        ...sampleFiles,
        'big.bin': _pattern(900000, 9),
      });
      final scan = scanFolderForTransfer(source.path);
      final stream = Uint8List(scan.streamSize);
      _reader(source, scan).fill(stream, 0, 0, stream.length);
      final cut = scan.streamSize ~/ 2;

      final first = await FolderReceiveSession.start(_config(staging, scan));
      first.add(Uint8List.sublistView(stream, 0, cut));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await first.close();
      await expectLater(first.finished, throwsA(isA<FolderReceiveException>()));

      final second = await FolderReceiveSession.start(_config(staging, scan));
      final resumeAt = second.resume.processedOffset;
      expect(resumeAt, greaterThan(0));
      expect(resumeAt, lessThanOrEqualTo(cut));
      second.add(Uint8List.sublistView(stream, resumeAt));
      final summary = await second.finished;
      await second.close();

      expect(summary.filesSkipped, 0);
      expect(_snapshot(_tree(staging)), _snapshot(source));
    });

    test('an unusable manifest fails the session', () async {
      _writeTree(source, sampleFiles);
      final scan = scanFolderForTransfer(source.path);
      final session = await FolderReceiveSession.start(_config(staging, scan));

      session.add(Uint8List(scan.manifest.length));

      await expectLater(
        session.finished,
        throwsA(
          isA<FolderReceiveException>().having(
            (error) => error.kind,
            'kind',
            FolderReceiveFailureKind.manifest,
          ),
        ),
      );
      await session.close();
    });
  });

  test(
    'ten thousand small files stay cheap per file',
    () {
      final random = math.Random(11);
      final files = <String, List<int>>{
        for (var index = 0; index < 10000; index += 1)
          'd${index % 97}/s${index % 13}/f$index.dat': List<int>.generate(
            20 + random.nextInt(300),
            (_) => random.nextInt(256),
          ),
      };
      _writeTree(source, files);

      final scanWatch = Stopwatch()..start();
      final scan = scanFolderForTransfer(source.path);
      scanWatch.stop();
      final transferWatch = Stopwatch()..start();
      final writer = _writer(_config(staging, scan))..open();
      _pump(_reader(source, scan), writer, chunk: 4 * 1024 * 1024);
      final summary = writer.summary;
      writer.close();
      transferWatch.stop();

      expect(scan.fileCount, 10000);
      expect(summary.filesWritten, 10000);
      expect(summary.filesSkipped, 0);
      // Stream overhead: a manifest entry and a trailer per file, nothing else.
      expect(scan.streamSize - scan.totalBytes, lessThan(10000 * 80));
      printOnFailure(
        'scan ${scanWatch.elapsedMilliseconds} ms, '
        'transfer ${transferWatch.elapsedMilliseconds} ms',
      );
      expect(transferWatch.elapsed, lessThan(const Duration(seconds: 60)));
      expect(_snapshot(_tree(staging)).length, _snapshot(source).length);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
