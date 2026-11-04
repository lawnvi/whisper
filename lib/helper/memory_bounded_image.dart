import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:synchronized/synchronized.dart';

class MemoryBoundedFileImage extends FileImage {
  const MemoryBoundedFileImage(super.file);

  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(key, _boundedDecoder(decode)),
        scale: key.scale,
        debugLabel: key.file.path,
      );

  /// FileImage checks `file.runtimeType == File`, which is never so: a real file
  /// is a `_File`. It then reads the whole file into Dart and copies that for the
  /// engine, twice the size of the picture for each one on screen. The engine can
  /// read it by itself.
  static Future<ui.Codec> _load(
    FileImage key,
    ImageDecoderCallback decode,
  ) async {
    if (await key.file.length() == 0) {
      PaintingBinding.instance.imageCache.evict(key);
      throw StateError(
        '${key.file} is empty and cannot be loaded as an image.',
      );
    }
    return decode(await ui.ImmutableBuffer.fromFilePath(key.file.path));
  }
}

class MemoryBoundedMemoryImage extends MemoryImage {
  const MemoryBoundedMemoryImage(super.bytes);

  @override
  ImageStreamCompleter loadImage(
    MemoryImage key,
    ImageDecoderCallback decode,
  ) => super.loadImage(key, _boundedDecoder(decode));
}

ImageDecoderCallback _boundedDecoder(ImageDecoderCallback decode) =>
    (buffer, {getTargetSize}) async => MemoryBoundedImageCodec(
      await decode(buffer, getTargetSize: getTargetSize),
    );

/// PNG decoding can temporarily allocate the original bitmap even for a small
/// thumbnail. Serialize static decodes instead of multiplying that peak.
class MemoryBoundedImageCodec implements ui.Codec {
  MemoryBoundedImageCodec(this._codec);

  static final Lock _staticDecodes = Lock();
  final ui.Codec _codec;
  bool _disposed = false;

  @override
  int get frameCount => _codec.frameCount;

  @override
  int get repetitionCount => _codec.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() {
    if (_disposed) {
      return Future.error(StateError('Image codec disposed'));
    }
    if (frameCount > 1) {
      return _codec.getNextFrame();
    }
    return _staticDecodes.synchronized(() {
      if (_disposed) {
        throw StateError('Image codec disposed');
      }
      return _codec.getNextFrame();
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _codec.dispose();
  }
}
