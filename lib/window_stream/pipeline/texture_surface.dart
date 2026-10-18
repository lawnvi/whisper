import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/media_packet.dart';
import '../window_stream_log.dart';
import 'media_sink.dart';

/// Receiving side on Android and iOS: a hardware decoder that draws into a
/// Flutter texture, so the viewer's controls are ordinary widgets on top of
/// the video. The UI isolate creates and disposes it; the stream isolate
/// feeds frames through [TextureFrameSink].
class TextureStreamSurface {
  TextureStreamSurface._(this.textureId);

  static const _control = MethodChannel('com.vireen.whisper/window_stream');
  static final _surfaces = <int, TextureStreamSurface>{};
  static bool _handlerInstalled = false;

  final int textureId;
  final _events = StreamController<TextureSurfaceEvent>.broadcast();

  Stream<TextureSurfaceEvent> get events => _events.stream;

  final _frames = StreamController<TextureFrame>.broadcast();

  /// Every decoded frame while [watchFrames] is on (iOS): what the viewer
  /// needs to tell when the picture has settled after the window opened,
  /// resized or resumed.
  Stream<TextureFrame> get frames => _frames.stream;

  /// Asks the decoder to report each frame on [frames] (or to stop). False
  /// where the platform cannot (Android's decoder here reports sizes only).
  Future<bool> watchFrames(bool on) async {
    try {
      await _control.invokeMethod<void>('watch', {'id': textureId, 'on': on});
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// The window sends sound (known from its first chunk): the viewer
  /// offers to mute it.
  final hasAudio = ValueNotifier<bool>(false);

  /// The sound's numbers as of the decoder's last report: queued ms,
  /// underruns, resyncs, playing (1/0), chunks. Empty without sound.
  List<double> latestAudioStats = const [];

  /// Silences this window's sound here (or lets it play again).
  Future<void> setAudioMuted(bool muted) async {
    try {
      await _control.invokeMethod<void>('audioMute', {
        'id': textureId,
        'muted': muted,
      });
    } on MissingPluginException {
      // No sound here at all.
    } on PlatformException {
      // Same.
    }
  }

  /// The decoder's numbers as of its last report (every 2 s while frames
  /// arrive; iOS): decoded fps, dropped, decode ms, queued, presented,
  /// decoder rebuilds. Empty until the first report.
  List<double> latestStats = const [];

  /// Whether a hardware keyboard is attached (iPhone and iPad; null where
  /// the platform does not say). Updated as keyboards come and go.
  static final hardwareKeyboard = ValueNotifier<bool?>(null);

  static void _install() {
    if (!_handlerInstalled) {
      _handlerInstalled = true;
      _control.setMethodCallHandler(_onNativeCall);
    }
  }

  /// Asks whether a hardware keyboard is attached now (iOS), and keeps
  /// [hardwareKeyboard] current from then on.
  static Future<bool?> refreshHardwareKeyboard() async {
    if (!Platform.isIOS) {
      return null;
    }
    _install();
    try {
      final attached = await _control.invokeMethod<bool>('hardwareKeyboard');
      hardwareKeyboard.value = attached;
      return attached;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<TextureStreamSurface> create({
    required int width,
    required int height,
  }) async {
    _install();
    final id = await _control.invokeMethod<int>('create', {
      'width': width,
      'height': height,
    });
    final surface = TextureStreamSurface._(id!);
    _surfaces[surface.textureId] = surface;
    return surface;
  }

  static Future<void> _onNativeCall(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    if (call.method == 'hardwareKeyboard') {
      hardwareKeyboard.value = args['attached'] == true;
      return;
    }
    final surface = _surfaces[(args['id'] as num?)?.toInt()];
    if (surface == null) {
      return;
    }
    switch (call.method) {
      case 'stats':
        final values = args['values'];
        if (values is List) {
          surface.latestStats = [
            for (final value in values) (value as num?)?.toDouble() ?? 0,
          ];
        }
        final audio = args['audio'];
        if (audio is List) {
          surface.latestAudioStats = [
            for (final value in audio) (value as num?)?.toDouble() ?? 0,
          ];
        }
      case 'audio':
        surface.hasAudio.value = args['playing'] == true;
      case 'decoderReset':
        // iOS rebuilt the decoder (back from the background, or the system
        // took it away); a keyframe was asked for.
        final time = DateTime.now().toIso8601String().substring(11, 23);
        WindowStreamLog.write(
          '$time texture ${surface.textureId} decoder rebuilt '
          '(${args['reason']})',
        );
      case 'needKeyframe':
        surface._events.add(const TextureNeedsKeyframe());
      case 'size':
        surface._events.add(
          TextureVideoSize(
            (args['width'] as num?)?.toInt() ?? 0,
            (args['height'] as num?)?.toInt() ?? 0,
          ),
        );
      case 'frame':
        if (!surface._frames.isClosed) {
          surface._frames.add(
            TextureFrame(
              (args['width'] as num?)?.toInt() ?? 0,
              (args['height'] as num?)?.toInt() ?? 0,
              (args['count'] as num?)?.toInt() ?? 0,
              replay: args['replay'] == true,
            ),
          );
        }
      case 'error':
        surface._events.add(TextureDecoderError('${args['reason']}'));
    }
  }

  /// The newest decoded frame as JPEG, its longer edge at most [maxEdge]
  /// pixels (0: full size); null when there is none yet or the platform
  /// cannot (Android draws into a surface it does not read back).
  Future<Uint8List?> snapshot({int maxEdge = 0, double quality = 0.78}) async {
    try {
      return await _control.invokeMethod<Uint8List>('snapshot', {
        'id': textureId,
        'maxEdge': maxEdge,
        'quality': quality,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// The decoder's numbers now (see [latestStats]); empty where unknown.
  Future<List<double>> stats() async {
    try {
      final values = await _control.invokeMethod<List<Object?>>('stats', {
        'id': textureId,
      });
      if (values == null) {
        return const [];
      }
      return latestStats = [
        for (final value in values) (value as num?)?.toDouble() ?? 0,
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// The surface for [textureId] while it exists (the viewer page reaches
  /// its decoder through this).
  static TextureStreamSurface? of(int textureId) => _surfaces[textureId];

  Future<void> resize(int width, int height) {
    return _control.invokeMethod('resize', {
      'id': textureId,
      'width': width,
      'height': height,
    });
  }

  Future<void> dispose() async {
    _surfaces.remove(textureId);
    await _control.invokeMethod('dispose', {'id': textureId});
    await _events.close();
    await _frames.close();
  }
}

/// One decoded frame: its size in pixels and how many the decoder has
/// shown so far.
class TextureFrame {
  const TextureFrame(
    this.width,
    this.height,
    this.count, {
    this.replay = false,
  });

  final int width;
  final int height;
  final int count;

  /// Not a new frame: the one already on screen when watching began.
  final bool replay;
}

sealed class TextureSurfaceEvent {
  const TextureSurfaceEvent();
}

class TextureNeedsKeyframe extends TextureSurfaceEvent {
  const TextureNeedsKeyframe();
}

class TextureVideoSize extends TextureSurfaceEvent {
  const TextureVideoSize(this.width, this.height);

  final int width;
  final int height;
}

class TextureDecoderError extends TextureSurfaceEvent {
  const TextureDecoderError(this.reason);

  final String reason;
}

/// Sends frames to the texture decoder from the stream isolate (which must
/// have called BackgroundIsolateBinaryMessenger.ensureInitialized).
class TextureFrameSink implements MediaSink {
  static const _frames = BasicMessageChannel<ByteData>(
    'com.vireen.whisper/window_stream_frames',
    BinaryCodec(),
  );

  /// Header: int64 decoder id, int64 pts µs, int32 flags (little-endian).
  static const int headerBytes = 20;

  /// Header flags: video parameter sets, video keyframe, a chunk of the
  /// window's sound (PCM s16le, interleaved), the sound's format (payload:
  /// int32 sample rate, int32 channels, little-endian).
  static const int flagConfig = 1;
  static const int flagKey = 2;
  static const int flagAudio = 16;
  static const int flagAudioFormat = 32;

  @override
  MediaPacketWriter beginVideo(int surface, int length) {
    return _TexturePacket(surface, length);
  }

  @override
  MediaPacketWriter beginAudio(int surface, int length) =>
      _TexturePacket(surface, length, audio: true);

  @override
  void configureAudio(
    int surface, {
    required int sampleRate,
    required int channels,
  }) {
    send(
      encode(surface, 0, flagAudioFormat, audioFormat(sampleRate, channels)),
    );
  }

  /// The payload of a [flagAudioFormat] message.
  static Uint8List audioFormat(int sampleRate, int channels) {
    final payload = Uint8List(8);
    ByteData.sublistView(payload)
      ..setInt32(0, sampleRate, Endian.little)
      ..setInt32(4, channels, Endian.little);
    return payload;
  }

  static Uint8List encode(
    int surface,
    int ptsUs,
    int flags,
    Uint8List payload,
  ) {
    final out = Uint8List(headerBytes + payload.length);
    ByteData.sublistView(out)
      ..setInt64(0, surface, Endian.little)
      ..setInt64(8, ptsUs, Endian.little)
      ..setInt32(16, flags, Endian.little);
    out.setRange(headerBytes, out.length, payload);
    return out;
  }

  static void send(Uint8List message) {
    unawaited(_frames.send(ByteData.sublistView(message)));
  }
}

class _TexturePacket implements MediaPacketWriter {
  _TexturePacket(this._surface, int length, {this.audio = false})
    : _buffer = Uint8List(TextureFrameSink.headerBytes + length);

  final int _surface;
  final bool audio;
  final Uint8List _buffer;
  int _filled = TextureFrameSink.headerBytes;

  @override
  void write(Uint8List chunk) {
    final take = chunk.length.clamp(0, _buffer.length - _filled);
    _buffer.setRange(_filled, _filled + take, chunk);
    _filled += take;
  }

  @override
  void commit({required int ptsUs, required bool config, required bool key}) {
    ByteData.sublistView(_buffer)
      ..setInt64(0, _surface, Endian.little)
      ..setInt64(8, ptsUs, Endian.little)
      ..setInt32(
        16,
        audio
            ? TextureFrameSink.flagAudio
            : (config ? TextureFrameSink.flagConfig : 0) |
                  (key ? TextureFrameSink.flagKey : 0),
        Endian.little,
      );
    TextureFrameSink.send(Uint8List.sublistView(_buffer, 0, _filled));
  }

  @override
  void discard() {}
}
