import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:synchronized/synchronized.dart';

class MemoryBoundedFileImage extends FileImage {
  const MemoryBoundedFileImage(super.file, {super.scale});

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

/// Decodes [image] so that it still covers [extent] pixels both ways, for
/// `BoxFit.cover`. `ResizeImage` only fits: a wide screenshot in a square would
/// come out a few pixels tall and be blown up again, a blur.
class CoverResizeImage extends ImageProvider<_CoverKey> {
  const CoverResizeImage(this.image, {required this.extent});

  final ImageProvider image;
  final int extent;

  @override
  Future<_CoverKey> obtainKey(ImageConfiguration configuration) async =>
      _CoverKey(await image.obtainKey(configuration), extent);

  @override
  ImageStreamCompleter loadImage(_CoverKey key, ImageDecoderCallback decode) {
    Future<ui.Codec> covering(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) => decode(
      buffer,
      getTargetSize: (width, height) {
        final shortest = width < height ? width : height;
        if (shortest <= extent) return ui.TargetImageSize();
        return ui.TargetImageSize(
          width: (width * extent / shortest).ceil(),
          height: (height * extent / shortest).ceil(),
        );
      },
    );
    return image.loadImage(key.image, covering);
  }
}

class _CoverKey {
  const _CoverKey(this.image, this.extent);

  final Object image;
  final int extent;

  @override
  bool operator ==(Object other) =>
      other is _CoverKey && other.image == image && other.extent == extent;

  @override
  int get hashCode => Object.hash(image, extent);
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
