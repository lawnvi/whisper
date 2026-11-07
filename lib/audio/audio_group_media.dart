import 'dart:async';
import 'dart:typed_data';

import 'package:whisper/audio/audio_capture_source.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_fanout_transport.dart';
import 'package:whisper/audio/audio_group_playback_scheduler.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';

typedef AudioGroupCodecFactory =
    Future<AudioCodec> Function(AudioStreamFormat format);
typedef AudioGroupTransportFactory =
    Future<AudioGroupPacketTransport> Function(Uri uri);

/// How a source reaches one sink's audio.
class AudioGroupSinkDial {
  const AudioGroupSinkDial({
    required this.sinkPeerId,
    required this.sourcePeerId,
    required this.sessionId,
    required this.uri,
    this.mediaUri,
    this.transportToken = '',
    this.mediaSendKey,
  });

  final String sinkPeerId;
  final String sourcePeerId;
  final String sessionId;

  /// The sink's main port.
  final Uri uri;

  /// The port the sink's audio isolate listens on, when it said so: tried
  /// first, and [uri] when it can't be reached.
  final Uri? mediaUri;
  final String transportToken;
  final Uint8List? mediaSendKey;
}

/// A connection to a sink that is not sending yet; see
/// [AudioGroupMedia.attachSink].
abstract class AudioGroupSinkLink {}

class AudioGroupCaptureSpec {
  const AudioGroupCaptureSpec({
    required this.groupId,
    required this.streamId,
    required this.sourcePeerId,
    required this.format,
    required this.targetLatencyMs,
  });

  final String groupId;
  final String streamId;
  final String sourcePeerId;
  final AudioStreamFormat format;
  final int targetLatencyMs;
}

/// This device's sound going to the attached sinks.
abstract class AudioGroupCapture {
  Future<void> start();

  Future<void> stop();

  /// When a packet last went out, or 0. Windows captures nothing while the
  /// computer plays nothing, so no packets is not by itself a fault.
  int get lastSentAtMicros;
}

class AudioGroupPlaybackSpec {
  const AudioGroupPlaybackSpec({
    required this.groupId,
    required this.streamId,
    required this.sessionId,
    required this.sourcePeerId,
    required this.format,
    required this.channelRole,
    required this.gain,
  });

  final String groupId;
  final String streamId;

  /// This sink's session: the media channel's claim is bound to it.
  final String sessionId;
  final String sourcePeerId;
  final AudioStreamFormat format;
  final AudioChannelRole channelRole;
  final double gain;
}

/// The sound of one source played here.
abstract class AudioGroupPlayback {
  /// The port packets can come to without the main isolate, or 0.
  int get mediaPort;

  /// A packet that came in through the main port.
  void deliver(AudioGroupPacketFrame packet);

  void updateClockOffset(int clockOffsetMicros);

  void updateChannelRole(AudioChannelRole channelRole);

  void updateGain(double gain);

  Future<void> stop();
}

typedef AudioGroupPlaybackReportSink =
    void Function(AudioGroupPlaybackReport report);

/// Moves the sound: capture, encoding, scheduling and sending at a source,
/// receiving, decoding, scheduling and playing at a sink. The coordinator
/// keeps the sessions and the control messages.
abstract class AudioGroupMedia {
  /// A sink whose connection failed after it was attached.
  AudioGroupSinkFailure? onSinkFailure;

  Future<AudioGroupSinkLink> connectSink(AudioGroupSinkDial dial);

  void attachSink(String sinkPeerId, AudioGroupSinkLink link);

  Future<void> closeLink(AudioGroupSinkLink link);

  Future<void> disconnectSink(String sinkPeerId);

  Future<void> disconnectAllSinks();

  /// Not started when [shouldStart] says no once the codec is ready.
  AudioGroupCapture capture(
    AudioGroupCaptureSpec spec, {
    required void Function(Object error) onError,
    bool Function()? shouldStart,
  });

  /// Throws when it can't start, and [AudioGroupStartCancelled] when
  /// [shouldStart] says no once the codec is ready. [onReport] comes about
  /// once a second while packets arrive; [onFailure] once, when playing
  /// stopped working.
  Future<AudioGroupPlayback> startPlayback(
    AudioGroupPlaybackSpec spec, {
    required AudioGroupPlaybackReportSink onReport,
    required void Function(Object error) onFailure,
    bool Function()? shouldStart,
  });
}

/// Playback was no longer wanted by the time it could start.
class AudioGroupStartCancelled implements Exception {
  const AudioGroupStartCancelled();
}

/// How long the sink's media port gets before the main port is tried.
const Duration audioGroupMediaPortConnectTimeout = Duration(milliseconds: 1500);

/// Connects to [mediaUri] when there is one, and to [uri] when that fails.
Future<AudioGroupPacketTransport> connectAudioGroupSinkTransport({
  required Uri uri,
  Uri? mediaUri,
  required Future<AudioGroupPacketTransport> Function(Uri uri) connect,
  Duration mediaPortTimeout = audioGroupMediaPortConnectTimeout,
}) async {
  if (mediaUri != null) {
    final attempt = connect(mediaUri);
    try {
      return await attempt.timeout(mediaPortTimeout);
    } catch (_) {
      // Too late now: close it if it still connects.
      unawaited(
        attempt.then(
          (transport) => transport.close().catchError((Object _) {}),
          onError: (Object _) {},
        ),
      );
    }
  }
  return connect(uri);
}

/// Schedules a source's packets: each right after the one before, so the
/// sinks play them without gaps, and from now when that is behind.
class AudioGroupSourceSchedule {
  AudioGroupSourceSchedule({
    required AudioGroupClock clockMicros,
    required int targetLatencyMs,
    required int frameDurationMs,
  }) : _clockMicros = clockMicros,
       _targetLatencyMicros =
           targetLatencyMs * Duration.microsecondsPerMillisecond,
       _durationMicros = frameDurationMs * Duration.microsecondsPerMillisecond;

  /// How far ahead of now plus the target latency a packet may be scheduled.
  /// A burst of packets after a stall (minimizing or restoring the window on
  /// macOS stops the main thread for half a second) would push every later
  /// packet that far ahead too, past what a sink buffers: the sink drops each
  /// one before it is due and nothing plays. The rest of such a burst is
  /// dropped instead.
  static const int maxLeadMicros = 60000;

  /// Further ahead than this, the wall clock went back, as it can when a
  /// computer wakes and sets its time: scheduling starts again from now.
  static const int clockJumpLeadMicros = Duration.microsecondsPerSecond;

  final AudioGroupClock _clockMicros;
  final int _targetLatencyMicros;
  final int _durationMicros;
  int _nextTargetMicros = 0;

  int get durationMicros => _durationMicros;

  /// When the next packet should play, or null to drop it.
  int? next() {
    final baseMicros = _clockMicros() + _targetLatencyMicros;
    final leadMicros = _nextTargetMicros - baseMicros;
    if (leadMicros > maxLeadMicros && leadMicros <= clockJumpLeadMicros) {
      return null;
    }
    final targetMicros = leadMicros <= 0 || leadMicros > clockJumpLeadMicros
        ? baseMicros
        : _nextTargetMicros;
    _nextTargetMicros = targetMicros + _durationMicros;
    return targetMicros;
  }
}

/// A sink's packets from arrival to the PCM writer: decoding, scheduling
/// against the source's clock, and the reports the source sizes latency by.
class AudioGroupPlaybackPipeline {
  AudioGroupPlaybackPipeline({
    required AudioGroupPlaybackSpec spec,
    required AudioCodec codec,
    required AudioGroupClock clockMicros,
    required AudioGroupPcmWriter writePcm,
    required AudioGroupPlaybackReportSink onReport,
    required void Function(Object error) onFailure,
  }) : _spec = spec,
       _codec = codec,
       _clockMicros = clockMicros,
       _onReport = onReport,
       _onFailure = onFailure,
       _gain = spec.gain {
    _scheduler = AudioGroupPlaybackScheduler(
      channelRole: spec.channelRole,
      channels: spec.format.channels,
      clockMicros: clockMicros,
      startupBufferMicros: 20000,
      outputLeadMicros: nativePlaybackLeadMicros,
      requireClockOffsetBeforePlayback: true,
      writePcm: (pcm, targetPlaybackTimeMicros) =>
          writePcm(_applyGain(pcm), targetPlaybackTimeMicros),
    );
  }

  /// How long before a packet is due it goes to the native player.
  static const int nativePlaybackLeadMicros = 35000;
  static const int _maxPumpIntervalMicros = 10000;
  static const int _reportIntervalMicros = 1000000;

  final AudioGroupPlaybackSpec _spec;
  final AudioCodec _codec;
  final AudioGroupClock _clockMicros;
  final AudioGroupPlaybackReportSink _onReport;
  final void Function(Object error) _onFailure;
  late final AudioGroupPlaybackScheduler _scheduler;
  double _gain;
  Timer? _pumpTimer;
  bool _pumping = false;
  bool _pumpRequested = false;
  bool _closed = false;
  bool _failed = false;
  int _lastReportAtMicros = 0;

  AudioGroupPlaybackSpec get spec => _spec;

  bool get isClosed => _closed;

  void deliver(AudioGroupPacketFrame packet) {
    if (_closed ||
        packet.groupId != _spec.groupId ||
        packet.streamId != _spec.streamId) {
      return;
    }
    _scheduler.enqueue(packet, _codec.decode(packet.payload));
    _requestPump();
    _maybeReport();
  }

  void updateClockOffset(int clockOffsetMicros) {
    _scheduler.updateClockOffsetMicros(clockOffsetMicros);
  }

  void updateChannelRole(AudioChannelRole channelRole) {
    _scheduler.updateChannelRole(channelRole);
  }

  void updateGain(double gain) {
    _gain = gain;
  }

  /// Stops scheduling; the caller stops the native player.
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _pumpTimer?.cancel();
    _pumpTimer = null;
    _pumpRequested = false;
    _scheduler.close();
    _codec.dispose();
  }

  void _maybeReport() {
    final now = _clockMicros();
    if (_lastReportAtMicros != 0 &&
        now - _lastReportAtMicros < _reportIntervalMicros) {
      return;
    }
    _lastReportAtMicros = now;
    _onReport(_scheduler.report);
  }

  void _requestPump() {
    if (_closed) {
      return;
    }
    if (_pumping) {
      _pumpRequested = true;
      return;
    }
    _pumpTimer?.cancel();
    _pumpTimer = null;
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_closed) {
      return;
    }
    if (_pumping) {
      _pumpRequested = true;
      return;
    }
    _pumping = true;
    _pumpTimer?.cancel();
    _pumpTimer = null;
    try {
      while (true) {
        _pumpRequested = false;
        if (_closed) {
          return;
        }
        try {
          await _scheduler.pump();
        } catch (error) {
          if (!_closed && !_failed) {
            _failed = true;
            _onFailure(error);
          }
          return;
        }
        if (_closed) {
          return;
        }
        if (!_pumpRequested) {
          break;
        }
      }
    } finally {
      _pumping = false;
    }
    if (_closed) {
      return;
    }
    final report = _scheduler.report;
    if (report.queuedPacketCount == 0) {
      return;
    }
    _pumpTimer = Timer(Duration(microseconds: _pumpDelayMicros(report)), () {
      unawaited(_pump());
    });
  }

  int _pumpDelayMicros(AudioGroupPlaybackReport report) {
    if (report.nextPumpDelayMicros <= 0) {
      return 1;
    }
    if (report.nextPumpDelayMicros > _maxPumpIntervalMicros) {
      return _maxPumpIntervalMicros;
    }
    return report.nextPumpDelayMicros;
  }

  Int16List _applyGain(Int16List pcm) {
    final gain = _gain;
    if (gain == 1.0) {
      return pcm;
    }
    final amplified = Int16List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      amplified[i] = (pcm[i] * gain).round().clamp(-32768, 32767).toInt();
    }
    return amplified;
  }
}

/// Builds the frame a source sends for one encoded packet.
AudioGroupPacketFrame audioGroupPacketFrame(
  AudioGroupCaptureSpec spec,
  AudioPacketFrame packet, {
  required int targetPlaybackTimeMicros,
  required int durationMicros,
}) {
  return AudioGroupPacketFrame(
    groupId: spec.groupId,
    streamId: spec.streamId,
    sessionId: spec.streamId,
    sourcePeerId: spec.sourcePeerId,
    sequence: packet.sequence,
    captureTimeMicros: packet.captureTimeMicros,
    targetPlaybackTimeMicros: targetPlaybackTimeMicros,
    durationMicros: durationMicros,
    channelMask: spec.format.channels == 1
        ? AudioChannelMask.mono
        : AudioChannelMask.stereo,
    payload: packet.payload,
  );
}

/// Everything on this isolate, through the audio MethodChannel. Android,
/// tests, and desktops whose native side has no direct entry points.
class LocalAudioGroupMedia implements AudioGroupMedia {
  LocalAudioGroupMedia({
    required AudioPlatform platform,
    required AudioGroupCodecFactory codecFactory,
    required AudioGroupClock clockMicros,
    AudioGroupTransportFactory? transportFactory,
  }) : _platform = platform,
       _codecFactory = codecFactory,
       _clockMicros = clockMicros,
       _transportFactory = transportFactory;

  final AudioPlatform _platform;
  final AudioGroupCodecFactory _codecFactory;
  final AudioGroupClock _clockMicros;
  final AudioGroupTransportFactory? _transportFactory;
  late final AudioFanoutTransport _fanout = AudioFanoutTransport(
    onSinkFailure: (sinkPeerId, error) =>
        onSinkFailure?.call(sinkPeerId, error),
  );

  @override
  AudioGroupSinkFailure? onSinkFailure;

  @override
  Future<AudioGroupSinkLink> connectSink(AudioGroupSinkDial dial) async {
    final transport = await connectAudioGroupSinkTransport(
      uri: dial.uri,
      mediaUri: dial.mediaUri,
      connect: (uri) {
        final factory = _transportFactory;
        if (factory != null) {
          return factory(uri);
        }
        final mediaSendKey = dial.mediaSendKey;
        if (dial.transportToken.isEmpty || mediaSendKey == null) {
          throw StateError('authenticated audio group context missing');
        }
        return AudioGroupWebSocketPacketTransport.connect(
          uri,
          mediaMacKey: mediaSendKey,
          sessionId: dial.sessionId,
          peerId: dial.sourcePeerId,
        );
      },
    );
    return _LocalSinkLink(transport);
  }

  @override
  void attachSink(String sinkPeerId, AudioGroupSinkLink link) {
    _fanout.attach(sinkPeerId, (link as _LocalSinkLink).transport);
  }

  @override
  Future<void> closeLink(AudioGroupSinkLink link) {
    return (link as _LocalSinkLink).transport.close();
  }

  @override
  Future<void> disconnectSink(String sinkPeerId) {
    return _fanout.detachAndClose(sinkPeerId);
  }

  @override
  Future<void> disconnectAllSinks() => _fanout.closeAll();

  @override
  AudioGroupCapture capture(
    AudioGroupCaptureSpec spec, {
    required void Function(Object error) onError,
    bool Function()? shouldStart,
  }) {
    return _LocalCapture(this, spec, onError, shouldStart);
  }

  @override
  Future<AudioGroupPlayback> startPlayback(
    AudioGroupPlaybackSpec spec, {
    required AudioGroupPlaybackReportSink onReport,
    required void Function(Object error) onFailure,
    bool Function()? shouldStart,
  }) async {
    final codec = await _codecFactory(spec.format);
    if (shouldStart?.call() == false) {
      codec.dispose();
      throw const AudioGroupStartCancelled();
    }
    try {
      await _platform.startPlayback(
        sessionId: spec.streamId,
        format: spec.format,
      );
    } catch (_) {
      codec.dispose();
      rethrow;
    }
    return _LocalPlayback(
      _platform,
      AudioGroupPlaybackPipeline(
        spec: spec,
        codec: codec,
        clockMicros: _clockMicros,
        writePcm: (pcm, targetPlaybackTimeMicros) => _platform.writePcm(
          sessionId: spec.streamId,
          pcm: pcm,
          targetPlaybackTimeMicros: targetPlaybackTimeMicros,
        ),
        onReport: onReport,
        onFailure: onFailure,
      ),
    );
  }
}

class _LocalSinkLink implements AudioGroupSinkLink {
  _LocalSinkLink(this.transport);

  final AudioGroupPacketTransport transport;
}

class _LocalCapture implements AudioGroupCapture {
  _LocalCapture(this._media, this._spec, this._onError, this._shouldStart);

  final LocalAudioGroupMedia _media;
  final AudioGroupCaptureSpec _spec;
  final void Function(Object error) _onError;
  final bool Function()? _shouldStart;
  AudioCaptureSource? _source;
  bool _stopped = false;

  @override
  int lastSentAtMicros = 0;

  @override
  Future<void> start() async {
    final codec = await _media._codecFactory(_spec.format);
    if (_stopped || _shouldStart?.call() == false) {
      codec.dispose();
      return;
    }
    final schedule = AudioGroupSourceSchedule(
      clockMicros: _media._clockMicros,
      targetLatencyMs: _spec.targetLatencyMs,
      frameDurationMs: _spec.format.frameDurationMs,
    );
    final source = AudioCaptureSource(
      codec: codec,
      platform: _media._platform,
      // Native capture gave up after it had started.
      onError: _onError,
      onPacket: (packet) {
        if (_stopped) {
          return;
        }
        final target = schedule.next();
        if (target == null) {
          return;
        }
        lastSentAtMicros = _media._clockMicros();
        _media._fanout.send(
          audioGroupPacketFrame(
            _spec,
            packet,
            targetPlaybackTimeMicros: target,
            durationMicros: schedule.durationMicros,
          ),
        );
      },
    );
    _source = source;
    await source.start(sessionId: _spec.streamId, format: _spec.format);
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    await _source?.stop();
  }
}

class _LocalPlayback implements AudioGroupPlayback {
  _LocalPlayback(this._platform, this._pipeline);

  final AudioPlatform _platform;
  final AudioGroupPlaybackPipeline _pipeline;

  @override
  int get mediaPort => 0;

  @override
  void deliver(AudioGroupPacketFrame packet) => _pipeline.deliver(packet);

  @override
  void updateClockOffset(int clockOffsetMicros) =>
      _pipeline.updateClockOffset(clockOffsetMicros);

  @override
  void updateChannelRole(AudioChannelRole channelRole) =>
      _pipeline.updateChannelRole(channelRole);

  @override
  void updateGain(double gain) => _pipeline.updateGain(gain);

  @override
  Future<void> stop() async {
    if (_pipeline.isClosed) {
      return;
    }
    _pipeline.close();
    await _platform.stopPlayback(sessionId: _pipeline.spec.streamId);
  }
}
