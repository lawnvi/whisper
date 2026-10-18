import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:opus_codec_dart/opus_codec_dart.dart' as opus;
import 'package:path/path.dart' as p;

/// libopus inside a stream isolate, where Flutter plugins are not
/// registered: opened the way each platform's opus_codec plugin opens it.
/// On Windows and Linux the plugin unpacks the library into the temporary
/// folder; the main isolate loads it first ([AudioCodec] warm-up), so it is
/// there by the time a stream plays sound.
abstract final class WorkerOpus {
  static bool? _ready;

  /// Whether Opus can be decoded in this isolate.
  static bool ensure() {
    final ready = _ready;
    if (ready != null) {
      return ready;
    }
    try {
      opus.initOpus(_open());
      return _ready = true;
    } catch (_) {
      return _ready = false;
    }
  }

  static DynamicLibrary _open() {
    if (Platform.isMacOS || Platform.isIOS) {
      return DynamicLibrary.process();
    }
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libopus.so');
    }
    final temp = Directory.systemTemp.path;
    if (Platform.isWindows) {
      final name = Abi.current() == Abi.windowsIA32
          ? 'libopus_x86.dll'
          : 'libopus_x64.dll';
      return DynamicLibrary.open(
        p.join(temp, 'opus_flutter_windows', 'opus', name),
      );
    }
    final name = Abi.current() == Abi.linuxArm64
        ? 'libopus_aarch64.so'
        : 'libopus_x86_64.so';
    return openFirst([
      p.join(temp, 'opus_flutter_linux', 'opus', name),
      // The plugin's bundled copy can be an empty file (3.0.5 ships empty
      // blobs); it then uses the system's, and so does this isolate.
      'libopus.so.0',
      'libopus.so',
    ]);
  }

  /// The first of [candidates] that opens.
  @visibleForTesting
  static DynamicLibrary openFirst(
    List<String> candidates, {
    DynamicLibrary Function(String path) open = DynamicLibrary.open,
  }) {
    Object? failure;
    for (final candidate in candidates) {
      try {
        return open(candidate);
      } catch (error) {
        failure = error;
      }
    }
    throw ArgumentError('libopus not found ($failure)');
  }
}

/// Turns a stream's sound frames into PCM for the surface.
class WorkerAudioDecoder {
  WorkerAudioDecoder._(this.sampleRate, this.channels, this._opus);

  /// A decoder for Opus frames ([opusCodec]) or PCM ones, or null when this
  /// isolate cannot decode them.
  static WorkerAudioDecoder? open({
    required int sampleRate,
    required int channels,
    required bool opusCodec,
  }) {
    if (!opusCodec) {
      return WorkerAudioDecoder._(sampleRate, channels, null);
    }
    if (!WorkerOpus.ensure()) {
      return null;
    }
    try {
      return WorkerAudioDecoder._(
        sampleRate,
        channels,
        opus.SimpleOpusDecoder(sampleRate: sampleRate, channels: channels),
      );
    } catch (_) {
      return null;
    }
  }

  final int sampleRate;
  final int channels;
  final opus.SimpleOpusDecoder? _opus;

  /// PCM s16le bytes for one frame; empty when it can't be decoded.
  Uint8List decode(Uint8List frame) {
    final decoder = _opus;
    if (decoder == null) {
      return frame.length.isOdd ? Uint8List(0) : frame;
    }
    try {
      final pcm = decoder.decode(input: frame);
      return pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);
    } catch (_) {
      return Uint8List(0);
    }
  }

  void dispose() {
    _opus?.destroy();
  }
}
