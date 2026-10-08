import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:whisper/helper/android_document_picker.dart';

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
    this.capacity = 24,
  }) : assert(capacity > 0),
       _loader = loader ?? _extractVideoThumbnail;

  static VideoThumbnailCache shared = VideoThumbnailCache();
  final int capacity;
  final Future<VideoThumbnail?> Function(String) _loader;
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
        return await _loader(path);
      } on Object {
        return null;
      }
    });
    _entries[key] = result;
    _pending = result.then<void>((_) {});
    return result;
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
  return extractDesktopVideoThumbnail(path);
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
  MediaKit.ensureInitialized();
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
