import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/page/remote_files/files_drag.dart';
import 'package:whisper/page/remote_files/files_model.dart';

/// A file dragged or pasted out of the app is written into Finder's or
/// Explorer's file as it arrives: the size shows from the start and the
/// bytes follow the transfer, instead of an empty file until it is all
/// here (which looked like a failed copy).
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('whisper-hand-over-');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Uint8List bytes(int n, int seed) =>
      Uint8List.fromList(List<int>.generate(n, (i) => (i * 7 + seed) % 251));

  test('pieces are handed over as the transfer commits them', () async {
    const size = 3 * 100000;
    final content = bytes(size, 3);
    final temp = File(p.join(dir.path, 'movie.mp4.part'));
    final fetch = FilesFetchOut.debug();
    final sink = _Collect();
    int? opened;
    final progress = <double>[];
    final handing = filesHandOver(
      fetch,
      open: (n) {
        opened = n;
        return sink;
      },
      onProgress: progress.add,
    );

    await temp.writeAsBytes(content.sublist(0, 100000));
    fetch.debugArrive(temp.path, 100000, size);
    await _until(() => sink.length >= 100000);
    expect(opened, size, reason: 'opened with the whole size at once');
    expect(sink.length, 100000);
    expect(sink.closed, isFalse);

    // Written past what the transfer committed: not handed over yet.
    await temp.writeAsBytes(content.sublist(0, 250000));
    fetch.debugArrive(temp.path, 200000, size);
    await _until(() => sink.length >= 200000);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sink.length, 200000);

    // Done: moved to where it lands, the rest comes from there.
    final landed = File(p.join(dir.path, 'movie.mp4'));
    await temp.writeAsBytes(content);
    await temp.rename(landed.path);
    fetch.debugDone(landed.path);
    await handing;
    expect(sink.length, size);
    expect(sink.bytes, content);
    expect(progress.last, 1.0);
  });

  test(
    'a finished transfer without its file named yet is waited for',
    () async {
      // The last update has everything committed but no file to read until
      // it is placed: the hand-over waits instead of spinning (it once kept
      // the isolate busy, so the placement never came).
      final content = bytes(3000, 5);
      final fetch = FilesFetchOut.debug();
      final sink = _Collect();
      final handing = filesHandOver(fetch, open: (_) => sink);
      fetch.debugArrive('', 3000, 3000);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final landed = File(p.join(dir.path, 'b2.txt'));
      await landed.writeAsBytes(content);
      fetch.debugDone(landed.path);
      await handing.timeout(const Duration(seconds: 5));
      expect(sink.bytes, content);
    },
  );

  test('a failed transfer is an error for the other app', () async {
    final fetch = FilesFetchOut.debug();
    final temp = File(p.join(dir.path, 'x.part'));
    await temp.writeAsBytes(bytes(1000, 1));
    final sink = _Collect();
    final handing = filesHandOver(fetch, open: (_) => sink);
    fetch.debugArrive(temp.path, 1000, 5000);
    await _until(() => sink.length == 1000);
    fetch.debugFail(StateError('peer gone'));
    await expectLater(handing, throwsStateError);
  });

  test(
    'a file that came whole at once is handed over from where it is',
    () async {
      final content = bytes(4096, 9);
      final landed = File(p.join(dir.path, 'small.txt'));
      await landed.writeAsBytes(content);
      final fetch = FilesFetchOut.debug()..debugDone(landed.path);
      final sink = _Collect();
      int? opened;
      await filesHandOver(
        fetch,
        open: (n) {
          opened = n;
          return sink;
        },
      );
      expect(opened, 4096);
      expect(sink.bytes, content);
    },
  );

  test('Finder draws the progress of a file dragged out', () {
    // The plugin publishes the destination's progress in thousandths with
    // no total; the app gives it one before it is published (checked by
    // hand: a subscriber, as Finder is, saw 25 %, 50 %, 100 %).
    final window = File(
      'macos/Runner/MainFlutterWindow.swift',
    ).readAsStringSync();
    final install = window.indexOf('FilePromiseProgress.install()');
    expect(install, isNot(-1));
    expect(install, lessThan(window.indexOf('RegisterGeneratedPlugins(')));
    expect(
      window,
      contains('kind == .file, fileURL != nil, totalUnitCount == 0'),
    );
    expect(window, contains('totalUnitCount = 1000'));
    expect(window, contains('fileOperationKind = .receiving'));
  });

  group('a folder dragged out to Finder', () {
    Future<void> tree(String root) async {
      await Directory(p.join(root, 'sub')).create(recursive: true);
      await File(p.join(root, 'a.txt')).writeAsString('a');
      await File(p.join(root, 'sub', 'b.txt')).writeAsString('b');
    }

    Future<Map<String, String>> read(String root) async => {
      await for (final entity in Directory(root).list(recursive: true))
        if (entity is File)
          p.relative(entity.path, from: root): await entity.readAsString(),
    };

    test('takes the place of the empty folder Finder shows', () async {
      final staged = p.join(dir.path, 'staging', 'Photos');
      await tree(staged);
      final shown = await Directory(
        p.join(dir.path, 'Desktop', 'Photos'),
      ).create(recursive: true);
      await FilesFolderPromises.moveFolderInto(staged, shown.path);
      expect(await read(shown.path), {
        'a.txt': 'a',
        p.join('sub', 'b.txt'): 'b',
      });
      expect(Directory(staged).existsSync(), isFalse);
    });

    test('moves in beside what got into it meanwhile', () async {
      final staged = p.join(dir.path, 'staging', 'Photos');
      await tree(staged);
      final shown = await Directory(
        p.join(dir.path, 'Desktop', 'Photos'),
      ).create(recursive: true);
      await File(p.join(shown.path, '.DS_Store')).writeAsString('finder');
      await FilesFolderPromises.moveFolderInto(staged, shown.path);
      expect(await read(shown.path), {
        '.DS_Store': 'finder',
        'a.txt': 'a',
        p.join('sub', 'b.txt'): 'b',
      });
      expect(Directory(staged).existsSync(), isFalse);
    });

    test('the runner fulfils folder promises over the channel the file '
        'manager answers', () {
      final window = File(
        'macos/Runner/MainFlutterWindow.swift',
      ).readAsStringSync();
      final drag = File(
        'lib/page/remote_files/files_drag.dart',
      ).readAsStringSync();
      const channel = "'com.vireen.whisper/folder_promises'";
      expect(drag, contains(channel));
      expect(window, contains(channel.replaceAll("'", '"')));
      final install = window.indexOf('FolderPromises.install()');
      expect(install, isNot(-1));
      expect(install, lessThan(window.indexOf('RegisterGeneratedPlugins(')));
      // The plugin sets the type before the delegate; the swap looks at it.
      expect(window, contains('fileType == FolderPromises.folderType'));
      expect(window, contains('static let folderType = "public.folder"'));
      expect(drag, contains("uniformTypeIdentifiers: ['public.folder']"));
      for (final method in ["'write'", "'cancel'", "'progress'"]) {
        expect(drag, contains(method));
        expect(window, contains(method.replaceAll("'", '"')));
      }
    });
  });
}

class _Collect implements EventSink<Object?> {
  final _builder = BytesBuilder();
  bool closed = false;

  int get length => _builder.length;
  Uint8List get bytes => _builder.toBytes();

  @override
  void add(Object? event) => _builder.add(event! as List<int>);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  void close() => closed = true;
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}
