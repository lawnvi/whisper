import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:synchronized/synchronized.dart';

class MemoryBoundedFileImage extends FileImage {
  const MemoryBoundedFileImage(super.file);

  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) =>
      super.loadImage(key, _boundedDecoder(decode));
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
