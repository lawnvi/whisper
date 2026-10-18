import 'dart:typed_data';

import '../../audio/audio_codec.dart';
import 'window_stream_control.dart';

/// A streamed window's sound on the host: PCM from the capture, cut into
/// 20 ms frames and coded with Opus for the `/window` route. Falls back to
/// PCM when Opus can't be loaded, which every viewer also plays.
class HostAudioEncoder {
  HostAudioEncoder({required this.send});

  /// Hands a ready packet ([WindowStreamPacket.audioFormat] or
  /// [WindowStreamPacket.audio]) to the stream's transport.
  final void Function(Uint8List packet) send;

  static const int frameMs = 20;
  static const int _bitRate = 128000;

  int _sampleRate = 0;
  int _channels = 0;
  AudioCodec? _codec;
  Future<AudioCodec?>? _opening;
  bool _usePcm = false;

  /// Samples of the next frame not sent yet, and the pts of its first.
  Int16List _pending = Int16List(0);
  int _pendingCount = 0;
  int _pendingPtsUs = 0;
  bool _closed = false;

  int get _frameSamples => _sampleRate * frameMs ~/ 1000 * _channels;

  /// PCM s16le interleaved captured at [ptsUs] (the video's clock).
  void add(
    Uint8List pcm, {
    required int ptsUs,
    required int sampleRate,
    required int channels,
  }) {
    if (_closed || pcm.lengthInBytes < 2 || channels < 1 || channels > 2) {
      return;
    }
    if (sampleRate != _sampleRate || channels != _channels) {
      _reset(sampleRate, channels);
    }
    // A view needs 2-byte alignment; native buffers have it, copies are cheap.
    final aligned = pcm.offsetInBytes.isEven ? pcm : Uint8List.fromList(pcm);
    final samples = Int16List.sublistView(
      aligned,
      0,
      aligned.lengthInBytes - aligned.lengthInBytes % 2,
    );
    final perUs = _sampleRate * _channels / 1e6;
    if (_pendingCount > 0) {
      // A gap (the app was silent and the capture sent nothing): the part
      // frame before it goes out padded with silence, not glued to this.
      final expected = _pendingPtsUs + (_pendingCount / perUs).round();
      if ((ptsUs - expected).abs() > 5000) {
        _pending.fillRange(_pendingCount, _frameSamples, 0);
        _emit(Int16List.fromList(_pending), _pendingPtsUs);
        _pendingCount = 0;
      }
    }
    var offset = 0;
    while (offset < samples.length) {
      if (_pendingCount == 0) {
        _pendingPtsUs = ptsUs + (offset / perUs).round();
      }
      final take = (_frameSamples - _pendingCount).clamp(
        0,
        samples.length - offset,
      );
      _pending.setRange(_pendingCount, _pendingCount + take, samples, offset);
      _pendingCount += take;
      offset += take;
      if (_pendingCount == _frameSamples) {
        _emit(Int16List.fromList(_pending), _pendingPtsUs);
        _pendingCount = 0;
      }
    }
  }

  void _reset(int sampleRate, int channels) {
    _codec?.dispose();
    _codec = null;
    _opening = null;
    _usePcm = false;
    _sampleRate = sampleRate;
    _channels = channels;
    _pending = Int16List(_frameSamples);
    _pendingCount = 0;
    _opening = OpusAudioCodec.create(
      AudioCodecConfig(
        sampleRate: sampleRate,
        channels: channels,
        frameDurationMs: frameMs,
        bitRate: _bitRate,
      ),
    ).then<AudioCodec?>((codec) => codec, onError: (Object _) => null);
    _opening!.then((codec) {
      if (_closed || _sampleRate != sampleRate || _channels != channels) {
        codec?.dispose();
        return;
      }
      _codec = codec;
      _usePcm = codec == null;
      send(
        WindowStreamPacket.audioFormat(
          codec: _usePcm
              ? WindowStreamPacket.audioPcm
              : WindowStreamPacket.audioOpus,
          sampleRate: sampleRate,
          channels: channels,
          frameMs: frameMs,
        ),
      );
    });
  }

  void _emit(Int16List frame, int ptsUs) {
    // Frames before the codec is ready are dropped: the first 20–40 ms.
    final codec = _codec;
    if (_usePcm) {
      send(
        WindowStreamPacket.audio(
          frame.buffer.asUint8List(frame.offsetInBytes, frame.lengthInBytes),
          ptsUs: ptsUs,
        ),
      );
    } else if (codec != null) {
      try {
        send(WindowStreamPacket.audio(codec.encode(frame), ptsUs: ptsUs));
      } catch (_) {
        // One bad frame is a click; the next one goes out.
      }
    }
  }

  void close() {
    _closed = true;
    _codec?.dispose();
    _codec = null;
  }
}
