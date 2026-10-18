import 'dart:ffi';
import 'dart:typed_data';

import 'package:window_stream_native/window_stream_native.dart';

import '../core/media_packet.dart';

/// Where decoded-to-be media goes. The stream isolate writes packets straight
/// into native memory; tests use an in-memory sink.
abstract interface class MediaSink {
  MediaPacketWriter beginVideo(int surface, int length);
  void configureAudio(
    int surface, {
    required int sampleRate,
    required int channels,
  });
  MediaPacketWriter beginAudio(int surface, int length);
}

class NativeMediaSink implements MediaSink {
  NativeMediaSink(this._bindings);

  final WindowStreamNativeBindings _bindings;

  @override
  MediaPacketWriter beginVideo(int surface, int length) {
    return _NativePacket(_bindings, surface, length, video: true);
  }

  @override
  MediaPacketWriter beginAudio(int surface, int length) {
    return _NativePacket(_bindings, surface, length, video: false);
  }

  @override
  void configureAudio(
    int surface, {
    required int sampleRate,
    required int channels,
  }) {
    _bindings.audioConfigure(
      surface,
      WsnAudioCodec.pcmS16le,
      sampleRate,
      channels,
    );
  }
}

/// One packet in native memory: allocated up front, filled chunk by chunk,
/// then handed over (native code frees it).
class _NativePacket implements MediaPacketWriter {
  _NativePacket(
    this._bindings,
    this._surface,
    this._length, {
    required this.video,
  }) : _pointer = _bindings.bufferAlloc(_length) {
    _view = _pointer == nullptr ? null : _pointer.asTypedList(_length);
  }

  final WindowStreamNativeBindings _bindings;
  final int _surface;
  final int _length;
  final bool video;
  final Pointer<Uint8> _pointer;
  Uint8List? _view;
  int _filled = 0;

  @override
  void write(Uint8List chunk) {
    final view = _view;
    if (view == null) {
      return;
    }
    final take = chunk.length.clamp(0, _length - _filled);
    view.setRange(_filled, _filled + take, chunk);
    _filled += take;
  }

  @override
  void commit({required int ptsUs, required bool config, required bool key}) {
    if (_view == null) {
      return;
    }
    _view = null;
    if (video) {
      final flags = (config ? WsnPacket.config : 0) | (key ? WsnPacket.key : 0);
      _bindings.videoPush(_surface, _pointer, _filled, ptsUs, flags);
    } else if (!config) {
      _bindings.audioPush(_surface, _pointer, _filled, ptsUs);
    } else {
      _bindings.free(_pointer.cast());
    }
  }

  @override
  void discard() {
    if (_view == null) {
      return;
    }
    _view = null;
    _bindings.free(_pointer.cast());
  }
}
