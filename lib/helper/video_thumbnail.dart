import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:whisper/helper/android_document_picker.dart';
import 'package:whisper/helper/desktop_video_library.dart';

class VideoThumbnail {
  const VideoThumbnail({
    required this.bytes,
    required this.aspectRatio,
    this.duration = Duration.zero,
  });

  final Uint8List bytes;
  final double aspectRatio;
  final Duration duration;
}

/// Only one decoder runs at a time; chat rows retain images, never players.
class VideoThumbnailCache {
  VideoThumbnailCache({
    Future<VideoThumbnail?> Function(String)? loader,
    this.capacity = 12,
    Future<Directory?> Function()? directory,
  }) : assert(capacity > 0),
       _loader = loader ?? _extractVideoThumbnail,
       _directory = directory ?? (loader == null ? _thumbnailDirectory : null);

  static VideoThumbnailCache shared = VideoThumbnailCache();

  /// How many thumbnails stay on disk. Each is a few hundred KB at most.
  static const diskCapacity = 300;

  final int capacity;
  final Future<VideoThumbnail?> Function(String) _loader;

  /// Where thumbnails outlive the run. A desktop decodes them with a whole video
  /// player, which takes tens of MB each time; phones ask the system, which keeps
  /// its own.
  final Future<Directory?> Function()? _directory;
  final _entries = <String, Future<VideoThumbnail?>>{};
  Future<void> _pending = Future<void>.value();

  Future<VideoThumbnail?> load(String path) async {
    if (path.isEmpty) return null;
    var key = path;
    if (!path.startsWith('content://')) {
      final FileStat stat;
      try {
        stat = await File(path).stat();
      } on FileSystemException {
        return null;
      }
      if (stat.type != FileSystemEntityType.file) return null;
      key = '$path:${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    }
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return cached;
    }
    while (_entries.length >= capacity) {
      _entries.remove(_entries.keys.first);
    }
    late final Future<VideoThumbnail?> result;
    result = _pending.then((_) async {
      if (!identical(_entries[key], result)) return null;
      try {
        final file = await _fileFor(key);
        final saved = file == null ? null : await _read(file);
        if (saved != null) return saved;
        final made = await _loader(path);
        if (made != null && file != null) unawaited(_write(file, made));
        return made;
      } on Object {
        return null;
      }
    });
    _entries[key] = result;
    _pending = result.then<void>((_) {});
    return result;
  }

  Future<File?> _fileFor(String key) async {
    final directory = await _directory?.call();
    if (directory == null) return null;
    return File(
      '${directory.path}/${sha256.convert(utf8.encode(key)).toString()}.thumb',
    );
  }

  /// A file is the aspect ratio and the duration, then the picture.
  static Future<VideoThumbnail?> _read(File file) async {
    try {
      final data = await file.readAsBytes();
      if (data.length <= _headerBytes) return null;
      final header = ByteData.sublistView(data, 0, _headerBytes);
      return VideoThumbnail(
        bytes: Uint8List.sublistView(data, _headerBytes),
        aspectRatio: header.getFloat64(0),
        duration: Duration(milliseconds: header.getInt64(8)),
      );
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _write(File file, VideoThumbnail thumbnail) async {
    try {
      final header = ByteData(_headerBytes)
        ..setFloat64(0, thumbnail.aspectRatio)
        ..setInt64(8, thumbnail.duration.inMilliseconds);
      final partial = File('${file.path}.partial');
      await partial.writeAsBytes([
        ...header.buffer.asUint8List(),
        ...thumbnail.bytes,
      ], flush: true);
      await partial.rename(file.path);
      await _prune(file.parent);
    } on FileSystemException {
      // It will be made again next time.
    }
  }

  Future<void> _prune(Directory directory) async {
    final files = await directory
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    if (files.length <= diskCapacity) return;
    final dated = [
      for (final file in files) (file, (await file.stat()).modified),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    for (final (file, _) in dated.take(files.length - diskCapacity)) {
      await file.delete();
    }
  }

  static const _headerBytes = 16;
}

Future<Directory?> _thumbnailDirectory() async {
  if (Platform.isAndroid || Platform.isIOS) return null;
  try {
    final base = await getApplicationCacheDirectory();
    return Directory('${base.path}/video_thumbnails').create(recursive: true);
  } on Object {
    return null;
  }
}

Future<VideoThumbnail?> _extractVideoThumbnail(String path) async {
  if (Platform.isAndroid) {
    final bytes = await AndroidDocumentPicker.shared.loadThumbnail(
      uri: path.startsWith('content://') ? path : Uri.file(path).toString(),
      width: 512,
      height: 512,
    );
    return _thumbnailFromBytes(bytes);
  }
  if (Platform.isIOS) {
    final bytes = await const MethodChannel(
      'com.vireen.whisper/ios_dir',
    ).invokeMethod<Uint8List>('videoThumbnail', {'path': path});
    return bytes == null ? null : _thumbnailFromBytes(bytes);
  }
  if (Platform.isMacOS) {
    final made = await _systemVideoThumbnail(path);
    if (made != null) return made;
  }
  return extractDesktopVideoThumbnail(path);
}

/// The system decodes what it can with next to no memory of ours. A whole video
/// player is for the rest: tens of MB, and the allocator keeps them afterwards.
Future<VideoThumbnail?> _systemVideoThumbnail(String path) async {
  try {
    final reply = await const MethodChannel(
      'com.vireen.whisper/window_theme',
    ).invokeMapMethod<String, Object?>('videoThumbnail', {'path': path});
    final bytes = reply?['bytes'] as Uint8List?;
    if (bytes == null) return null;
    final seconds = (reply?['seconds'] as num?)?.toDouble() ?? 0;
    return _thumbnailFromBytes(
      bytes,
      Duration(milliseconds: (seconds * 1000).round()),
    );
  } on Object {
    return null;
  }
}

Future<VideoThumbnail?> _thumbnailFromBytes(
  Uint8List bytes, [
  Duration duration = Duration.zero,
]) async {
  if (bytes.isEmpty) return null;
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final scale = math.min(
      1.0,
      512 / math.max(descriptor.width, descriptor.height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    final frame = await codec.getNextFrame();
    try {
      return VideoThumbnail(
        bytes: scale < 1
            ? (await frame.image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!.buffer.asUint8List()
            : bytes,
        aspectRatio: frame.image.width / frame.image.height,
        duration: duration,
      );
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

Future<VideoThumbnail?> extractDesktopVideoThumbnail(String path) async {
  if (!ensureDesktopVideoLibrary()) {
    return null;
  }
  final player = Player(
    configuration: const PlayerConfiguration(
      muted: true,
      vo: 'null',
      bufferSize: 2 * 1024 * 1024,
    ),
  );
  try {
    final native = player.platform as NativePlayer;
    // Software decode needs no Flutter texture or visible playback window.
    await native.setProperty('hwdec', 'no');
    await player.setAudioTrack(AudioTrack.no());
    await player.setSubtitleTrack(SubtitleTrack.no());
    await player.setVideoTrack(VideoTrack.auto());
    await player.open(Media(Uri.file(path).toString()), play: false);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final bytes = await player.screenshot();
      if (bytes != null && bytes.isNotEmpty) {
        return _thumbnailFromBytes(bytes, player.state.duration);
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    return null;
  } finally {
    await player.dispose();
  }
}
