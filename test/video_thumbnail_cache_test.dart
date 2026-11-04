import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:whisper/helper/video_thumbnail.dart';

void main() {
  // Optional native smoke test: provide a local 16:9 video of at least 2 seconds
  // via WHISPER_TEST_VIDEO and the bundled library via WHISPER_TEST_LIBMPV.
  TestWidgetsFlutterBinding.ensureInitialized();
  final sample = Platform.environment['WHISPER_TEST_VIDEO'];
  test(
    'bundled player extracts a bounded thumbnail without a video window',
    () async {
      MediaKit.ensureInitialized(
        libmpv: Platform.environment['WHISPER_TEST_LIBMPV'],
      );
      final thumbnail = await extractDesktopVideoThumbnail(sample!);
      expect(thumbnail, isNotNull);
      expect(thumbnail!.bytes.length, lessThan(200 * 1024));
      expect(thumbnail.aspectRatio, closeTo(16 / 9, .03));
      expect(thumbnail.duration.inSeconds, greaterThanOrEqualTo(2));
    },
    skip: sample == null,
  );

  test('a thumbnail made once is read back from disk next run', () async {
    final root = await Directory.systemTemp.createTemp('thumbs');
    addTearDown(() => root.delete(recursive: true));
    final video = File('${root.path}/a.mp4')..writeAsBytesSync([1, 2, 3]);
    final disk = Directory('${root.path}/cache')..createSync();
    var made = 0;
    VideoThumbnailCache run() => VideoThumbnailCache(
      loader: (_) async {
        made++;
        return VideoThumbnail(
          bytes: Uint8List.fromList([9, 8, 7]),
          aspectRatio: 1.5,
          duration: const Duration(seconds: 3),
        );
      },
      directory: () async => disk,
    );
    await run().load(video.path);
    expect(made, 1);
    // The write does not hold up the thumbnail.
    await Future.doWhile(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return disk.listSync().whereType<File>().every(
        (file) => file.path.endsWith('.partial'),
      );
    });
    final again = await run().load(video.path);
    expect(made, 1, reason: 'no decoder the second time');
    expect(again!.bytes, [9, 8, 7]);
    expect(again.aspectRatio, 1.5);
    expect(again.duration, const Duration(seconds: 3));
    // A changed file is another video.
    video.writeAsBytesSync([1, 2, 3, 4]);
    await run().load(video.path);
    expect(made, 2);
  });

  test(
    'deduplicates concurrent loads and serializes different videos',
    () async {
      final gate = Completer<void>();
      final calls = <String>[];
      final thumbnail = VideoThumbnail(
        bytes: Uint8List(1),
        aspectRatio: 16 / 9,
      );
      final cache = VideoThumbnailCache(
        loader: (path) async {
          calls.add(path);
          await gate.future;
          return thumbnail;
        },
      );
      final first = cache.load('content://first');
      final duplicate = cache.load('content://first');
      final second = cache.load('content://second');
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['content://first']);
      gate.complete();
      expect(await first, same(thumbnail));
      expect(await duplicate, same(thumbnail));
      expect(await second, same(thumbnail));
      expect(calls, ['content://first', 'content://second']);
    },
  );

  test('discarded queued rows do not start another decoder', () async {
    final gate = Completer<void>();
    final calls = <String>[];
    final cache = VideoThumbnailCache(
      capacity: 2,
      loader: (path) async {
        calls.add(path);
        await gate.future;
        return null;
      },
    );
    final first = cache.load('content://first');
    await Future<void>.delayed(Duration.zero);
    final evicted = cache.load('content://evicted');
    final third = cache.load('content://third');
    final fourth = cache.load('content://fourth');
    gate.complete();
    await Future.wait([first, evicted, third, fourth]);
    expect(calls, ['content://first', 'content://third', 'content://fourth']);
  });

  test('failed extraction does not block subsequent videos', () async {
    final thumbnail = VideoThumbnail(bytes: Uint8List(1), aspectRatio: 1);
    final cache = VideoThumbnailCache(
      loader: (path) async {
        if (path.endsWith('bad')) throw StateError('Invalid video');
        return thumbnail;
      },
    );
    expect(await cache.load('content://bad'), isNull);
    expect(await cache.load('content://good'), same(thumbnail));
  });

  test('replaced and deleted local files do not reuse stale covers', () async {
    final directory = await Directory.systemTemp.createTemp('video-cache-test');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/clip.mp4');
    await file.writeAsBytes([1]);
    var calls = 0;
    final cache = VideoThumbnailCache(
      loader: (_) async {
        calls++;
        return VideoThumbnail(bytes: Uint8List(calls), aspectRatio: 1);
      },
    );
    final first = await cache.load(file.path);
    expect(await cache.load(file.path), same(first));
    await file.writeAsBytes([1, 2]);
    expect(await cache.load(file.path), isNot(same(first)));
    expect(calls, 2);
    await file.delete();
    expect(await cache.load(file.path), isNull);
    expect(calls, 2);
  });
}
