part of 'audio_media_isolate.dart';

typedef AudioCaptureCallbackNative =
    Void Function(
      Int64 sequence,
      Int64 captureTimeMicros,
      Int32 sampleRate,
      Int32 channels,
      Pointer<Int16> pcm,
      Int32 sampleCount,
    );
typedef _SetCaptureCallbackC =
    Void Function(Pointer<NativeFunction<AudioCaptureCallbackNative>> callback);
typedef _SetCaptureCallbackDart =
    void Function(Pointer<NativeFunction<AudioCaptureCallbackNative>> callback);
typedef _FreeBufferC = Void Function(Pointer<Void> buffer);
typedef _FreeBufferDart = void Function(Pointer<Void> buffer);
typedef _WritePcmC =
    Int32 Function(Int64 handle, Pointer<Int16> pcm, Int32 sampleCount);
typedef _WritePcmDart =
    int Function(int handle, Pointer<Int16> pcm, int sampleCount);

/// The native functions, called on this isolate's thread.
class _NativeAudio {
  _NativeAudio(AudioNativeEntryPoints entry)
    : _setCaptureCallback =
          Pointer<NativeFunction<_SetCaptureCallbackC>>.fromAddress(
            entry.setCaptureCallback,
          ).asFunction<_SetCaptureCallbackDart>(),
      _freeBuffer = Pointer<NativeFunction<_FreeBufferC>>.fromAddress(
        entry.freeBuffer,
      ).asFunction<_FreeBufferDart>(),
      _writePcm = Pointer<NativeFunction<_WritePcmC>>.fromAddress(
        entry.writePcm,
      ).asFunction<_WritePcmDart>();

  final _SetCaptureCallbackDart _setCaptureCallback;
  final _FreeBufferDart _freeBuffer;
  final _WritePcmDart _writePcm;
  Pointer<Int16> _buffer = nullptr;
  int _bufferSamples = 0;

  void setCaptureCallback(
    Pointer<NativeFunction<AudioCaptureCallbackNative>> callback,
  ) {
    _setCaptureCallback(callback);
  }

  /// Copies a captured buffer and frees the native one.
  Int16List take(Pointer<Int16> pcm, int sampleCount) {
    if (pcm == nullptr) {
      return Int16List(0);
    }
    final copy = Int16List.fromList(pcm.asTypedList(sampleCount));
    _freeBuffer(pcm.cast());
    return copy;
  }

  /// False when [handle] is not the playback running now.
  bool write(int handle, Int16List pcm) {
    if (pcm.isEmpty) {
      return true;
    }
    if (_bufferSamples < pcm.length) {
      if (_buffer != nullptr) {
        malloc.free(_buffer);
      }
      _buffer = malloc<Int16>(pcm.length);
      _bufferSamples = pcm.length;
    }
    _buffer.asTypedList(pcm.length).setAll(0, pcm);
    return _writePcm(handle, _buffer, pcm.length) == 0;
  }
}
