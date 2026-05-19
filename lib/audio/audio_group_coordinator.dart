import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:whisper/audio/audio_capture_source.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_fanout_transport.dart';
import 'package:whisper/audio/audio_group_playback_scheduler.dart';
import 'package:whisper/audio/audio_group_session.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/helper/local.dart';

typedef AudioGroupControlSender = void Function(
  String peerId,
  AudioGroupControlMessage control,
);
typedef AudioGroupIdFactory = String Function();
typedef AudioGroupCodecFactory = Future<AudioCodec> Function(
  AudioStreamFormat format,
);
typedef AudioGroupTransportFactory = Future<AudioGroupPacketTransport> Function(
  Uri uri,
);
typedef AudioGroupPlaybackGainProvider = Future<double> Function();

class AudioGroupCoordinator extends ChangeNotifier {
  AudioGroupCoordinator({
    AudioPlatform? platform,
    AudioGroupCodecFactory? codecFactory,
    AudioGroupTransportFactory? transportFactory,
    AudioGroupPlaybackGainProvider? playbackGainProvider,
    AudioGroupClock? clockMicros,
    AudioGroupIdFactory? groupIdFactory,
    AudioGroupIdFactory? streamIdFactory,
    AudioGroupIdFactory? sessionIdFactory,
  })  : _platform = platform ?? AudioPlatform(),
        _codecFactory = codecFactory ?? _createDefaultAudioGroupCodec,
        _transportFactory =
            transportFactory ?? AudioGroupWebSocketPacketTransport.connect,
        _playbackGainProvider =
            playbackGainProvider ?? LocalSetting().audioSharePlaybackGain,
        _clockMicros =
            clockMicros ?? (() => DateTime.now().microsecondsSinceEpoch),
        _groupIdFactory = groupIdFactory ?? const Uuid().v4,
        _streamIdFactory = streamIdFactory ?? const Uuid().v4,
        _sessionIdFactory = sessionIdFactory ?? const Uuid().v4;

  static final AudioGroupCoordinator shared = AudioGroupCoordinator();

  final AudioPlatform _platform;
  final AudioGroupCodecFactory _codecFactory;
  final AudioGroupTransportFactory _transportFactory;
  final AudioGroupPlaybackGainProvider _playbackGainProvider;
  final AudioGroupClock _clockMicros;
  final AudioGroupIdFactory _groupIdFactory;
  final AudioGroupIdFactory _streamIdFactory;
  final AudioGroupIdFactory _sessionIdFactory;

  late final AudioFanoutTransport _fanout = AudioFanoutTransport(
    onSinkFailure: _markSinkFailed,
  );
  AudioGroupSession? _session;
  AudioCaptureSource? _captureSource;
  AudioCodec? _playbackCodec;
  AudioGroupPlaybackScheduler? _playbackScheduler;
  Timer? _playbackPumpTimer;
  String _playbackGroupId = '';
  String _playbackStreamId = '';
  double _playbackGain = 1.0;

  AudioGroupSession? get session => _session;

  bool get hasLiveSession => _session?.isLive == true;

  bool isForPeer(String peerId) {
    final current = _session;
    if (current == null || peerId.isEmpty) {
      return false;
    }
    return current.sourcePeerId == peerId || current.sinks.containsKey(peerId);
  }

  AudioGroupSession startGroup({
    required String sourcePeerId,
    required Map<String, AudioChannelRole> sinks,
    required AudioStreamFormat format,
    required AudioGroupControlSender sendControl,
    int targetLatencyMs = 160,
  }) {
    if (hasLiveSession) {
      throw StateError('An audio group is already active');
    }
    if (sinks.isEmpty) {
      throw ArgumentError.value(sinks, 'sinks', 'must not be empty');
    }
    final groupId = _groupIdFactory();
    final streamId = _streamIdFactory();
    var nextSession = AudioGroupSession.offering(
      groupId: groupId,
      streamId: streamId,
      sourcePeerId: sourcePeerId,
      format: format,
      sinks: sinks,
      targetLatencyMs: targetLatencyMs,
    );
    for (final entry in sinks.entries) {
      final sinkPeerId = entry.key;
      final sessionId = _sessionIdFactory();
      nextSession = nextSession.markSink(
        sinkPeerId,
        sessionId: sessionId,
      );
      sendControl(
        sinkPeerId,
        AudioGroupControlMessage(
          action: AudioGroupControlAction.groupOffer,
          groupId: groupId,
          streamId: streamId,
          sessionId: sessionId,
          sourcePeerId: sourcePeerId,
          sinkPeerId: sinkPeerId,
          sinkPeerIds: sinks.keys.toList(growable: false),
          format: format,
          transport: AudioTransport.websocket,
          path: '/audio',
          channelRole: entry.value,
          targetLatencyMs: targetLatencyMs,
        ),
      );
    }
    _setSession(nextSession);
    return nextSession;
  }

  Future<AudioGroupSession?> handleControlMessage(
    AudioGroupControlMessage message, {
    required String localPeerId,
    required String remoteHost,
    required int remotePort,
    required AudioGroupControlSender sendControl,
  }) async {
    if (message.action == AudioGroupControlAction.groupOffer) {
      await _handleOffer(
        message,
        localPeerId: localPeerId,
        sendControl: sendControl,
      );
      return _session;
    }

    final current = _session;
    if (current == null || current.groupId != message.groupId) {
      return current;
    }
    switch (message.action) {
      case AudioGroupControlAction.groupAccept:
        await _handleAccept(
          current,
          message,
          localPeerId: localPeerId,
          remoteHost: remoteHost,
          remotePort: remotePort,
          sendControl: sendControl,
        );
        break;
      case AudioGroupControlAction.groupReject:
      case AudioGroupControlAction.error:
        _setSession(current.markSink(
          message.sinkPeerId,
          state: AudioGroupSinkState.failed,
          sessionId: message.sessionId,
          lastError: message.errorMessage,
        ));
        break;
      case AudioGroupControlAction.groupStop:
        if (current.sourcePeerId != localPeerId) {
          await stopLocal();
        } else {
          _setSession(current.markSink(
            message.sinkPeerId,
            state: AudioGroupSinkState.stopped,
            sessionId: message.sessionId,
          ));
        }
        break;
      case AudioGroupControlAction.groupOffer:
      case AudioGroupControlAction.groupUpdate:
      case AudioGroupControlAction.clockProbe:
      case AudioGroupControlAction.clockReport:
      case AudioGroupControlAction.latencyReport:
        break;
    }
    return _session;
  }

  Future<void> handlePacket(AudioGroupPacketFrame packet) async {
    final codec = _playbackCodec;
    final scheduler = _playbackScheduler;
    if (codec == null ||
        scheduler == null ||
        packet.groupId != _playbackGroupId ||
        packet.streamId != _playbackStreamId) {
      return;
    }
    scheduler.enqueue(packet, codec.decode(packet.payload));
    await _pumpPlayback();
  }

  Future<void> stopGroup({
    required AudioGroupControlSender sendControl,
  }) async {
    final current = _session;
    if (current == null) {
      return;
    }
    for (final sink in current.sinks.values) {
      sendControl(
        sink.sinkPeerId,
        AudioGroupControlMessage(
          action: AudioGroupControlAction.groupStop,
          groupId: current.groupId,
          streamId: current.streamId,
          sessionId: sink.sessionId,
          sourcePeerId: current.sourcePeerId,
          sinkPeerId: sink.sinkPeerId,
          channelRole: sink.channelRole,
          targetLatencyMs: current.targetLatencyMs,
        ),
      );
    }
    await stopLocal();
  }

  Future<void> stopLocal() async {
    final captureSource = _captureSource;
    final playbackCodec = _playbackCodec;
    final playbackStreamId = _playbackStreamId;
    _captureSource = null;
    _playbackCodec = null;
    _playbackScheduler = null;
    _playbackGroupId = '';
    _playbackStreamId = '';
    _playbackPumpTimer?.cancel();
    _playbackPumpTimer = null;
    await captureSource?.stop();
    await _fanout.closeAll();
    if (playbackStreamId.isNotEmpty) {
      await _platform.stopPlayback(sessionId: playbackStreamId);
    }
    playbackCodec?.dispose();
    _setSession(null);
  }

  Future<void> _handleOffer(
    AudioGroupControlMessage offer, {
    required String localPeerId,
    required AudioGroupControlSender sendControl,
  }) async {
    if (offer.sinkPeerId != localPeerId) {
      return;
    }
    if (hasLiveSession && _session?.groupId != offer.groupId) {
      sendControl(
        offer.sourcePeerId,
        AudioGroupControlMessage(
          action: AudioGroupControlAction.groupReject,
          groupId: offer.groupId,
          streamId: offer.streamId,
          sessionId: offer.sessionId,
          sourcePeerId: offer.sourcePeerId,
          sinkPeerId: offer.sinkPeerId,
          channelRole: offer.channelRole,
          errorMessage: 'Another audio group is already active',
        ),
      );
      return;
    }
    final format = offer.format;
    if (format == null) {
      sendControl(
        offer.sourcePeerId,
        AudioGroupControlMessage(
          action: AudioGroupControlAction.groupReject,
          groupId: offer.groupId,
          streamId: offer.streamId,
          sessionId: offer.sessionId,
          sourcePeerId: offer.sourcePeerId,
          sinkPeerId: offer.sinkPeerId,
          errorMessage: 'audio group offer missing format',
        ),
      );
      return;
    }

    try {
      await _startPlayback(offer, format: format);
      _setSession(AudioGroupSession.offering(
        groupId: offer.groupId,
        streamId: offer.streamId,
        sourcePeerId: offer.sourcePeerId,
        format: format,
        sinks: <String, AudioChannelRole>{
          localPeerId: offer.channelRole,
        },
        targetLatencyMs: offer.targetLatencyMs,
      ).markSink(
        localPeerId,
        state: AudioGroupSinkState.active,
        sessionId: offer.sessionId,
      ));
      sendControl(
        offer.sourcePeerId,
        AudioGroupControlMessage(
          action: AudioGroupControlAction.groupAccept,
          groupId: offer.groupId,
          streamId: offer.streamId,
          sessionId: offer.sessionId,
          sourcePeerId: offer.sourcePeerId,
          sinkPeerId: localPeerId,
          channelRole: offer.channelRole,
          targetLatencyMs: offer.targetLatencyMs,
        ),
      );
    } catch (error) {
      await stopLocal();
      sendControl(
        offer.sourcePeerId,
        AudioGroupControlMessage(
          action: AudioGroupControlAction.error,
          groupId: offer.groupId,
          streamId: offer.streamId,
          sessionId: offer.sessionId,
          sourcePeerId: offer.sourcePeerId,
          sinkPeerId: offer.sinkPeerId,
          channelRole: offer.channelRole,
          errorMessage: _friendlyErrorMessage(error),
        ),
      );
    }
  }

  Future<void> _handleAccept(
    AudioGroupSession current,
    AudioGroupControlMessage accept, {
    required String localPeerId,
    required String remoteHost,
    required int remotePort,
    required AudioGroupControlSender sendControl,
  }) async {
    if (current.sourcePeerId != localPeerId) {
      return;
    }
    final sink = current.sinks[accept.sinkPeerId];
    if (sink == null || sink.isTerminal) {
      return;
    }
    try {
      if (remoteHost.isNotEmpty && remotePort > 0) {
        final transport = await _transportFactory(
          _audioUri(
            host: remoteHost,
            port: remotePort,
            path: accept.path,
          ),
        );
        _fanout.attach(accept.sinkPeerId, transport);
      }
      var next = current.markSink(
        accept.sinkPeerId,
        state: AudioGroupSinkState.active,
        sessionId: accept.sessionId,
        channelRole: accept.channelRole,
        host: remoteHost,
        port: remotePort,
      );
      _setSession(next);
      await _ensureCaptureStarted(next);
    } catch (error) {
      final errorMessage = _friendlyErrorMessage(error);
      _setSession(current.markSink(
        accept.sinkPeerId,
        state: AudioGroupSinkState.failed,
        sessionId: accept.sessionId,
        lastError: errorMessage,
      ));
      sendControl(
        accept.sinkPeerId,
        AudioGroupControlMessage(
          action: AudioGroupControlAction.error,
          groupId: accept.groupId,
          streamId: accept.streamId,
          sessionId: accept.sessionId,
          sourcePeerId: accept.sourcePeerId,
          sinkPeerId: accept.sinkPeerId,
          errorMessage: errorMessage,
        ),
      );
    }
  }

  Future<void> _ensureCaptureStarted(AudioGroupSession session) async {
    if (_captureSource != null) {
      return;
    }
    final codec = await _codecFactory(session.format);
    final captureSource = AudioCaptureSource(
      codec: codec,
      platform: _platform,
      onPacket: (packet) {
        final current = _session;
        if (current == null || current.groupId != session.groupId) {
          return;
        }
        _fanout.send(
          AudioGroupPacketFrame(
            groupId: current.groupId,
            streamId: current.streamId,
            sessionId: current.streamId,
            sourcePeerId: current.sourcePeerId,
            sequence: packet.sequence,
            captureTimeMicros: packet.captureTimeMicros,
            targetPlaybackTimeMicros: packet.captureTimeMicros +
                current.targetLatencyMs * Duration.microsecondsPerMillisecond,
            durationMicros: current.format.frameDurationMs *
                Duration.microsecondsPerMillisecond,
            channelMask: current.format.channels == 1
                ? AudioChannelMask.mono
                : AudioChannelMask.stereo,
            payload: packet.payload,
          ),
        );
      },
    );
    _captureSource = captureSource;
    await captureSource.start(
      sessionId: session.streamId,
      format: session.format,
    );
  }

  Future<void> _startPlayback(
    AudioGroupControlMessage offer, {
    required AudioStreamFormat format,
  }) async {
    await _stopPlaybackOnly();
    final codec = await _codecFactory(format);
    _playbackGain = _normalizePlaybackGain(await _playbackGainProvider());
    _playbackCodec = codec;
    _playbackGroupId = offer.groupId;
    _playbackStreamId = offer.streamId;
    await _platform.startPlayback(
      sessionId: offer.streamId,
      format: format,
    );
    _playbackScheduler = AudioGroupPlaybackScheduler(
      channelRole: offer.channelRole,
      channels: format.channels,
      clockMicros: _clockMicros,
      startupBufferMicros: 20000,
      writePcm: (pcm) {
        return _platform.writePcm(
          sessionId: offer.streamId,
          pcm: _applyPlaybackGain(pcm),
        );
      },
    );
  }

  Future<void> _stopPlaybackOnly() async {
    final playbackCodec = _playbackCodec;
    final playbackStreamId = _playbackStreamId;
    _playbackPumpTimer?.cancel();
    _playbackPumpTimer = null;
    _playbackCodec = null;
    _playbackScheduler = null;
    _playbackGroupId = '';
    _playbackStreamId = '';
    if (playbackStreamId.isNotEmpty) {
      await _platform.stopPlayback(sessionId: playbackStreamId);
    }
    playbackCodec?.dispose();
  }

  Future<void> _pumpPlayback() async {
    _playbackPumpTimer?.cancel();
    _playbackPumpTimer = null;
    final scheduler = _playbackScheduler;
    if (scheduler == null) {
      return;
    }
    await scheduler.pump();
    final report = scheduler.report;
    if (report.queuedPacketCount == 0) {
      return;
    }
    final delay = Duration(
      microseconds:
          report.bufferDepthMicros <= 0 ? 1 : report.bufferDepthMicros,
    );
    _playbackPumpTimer = Timer(delay, () {
      unawaited(_pumpPlayback());
    });
  }

  void _markSinkFailed(String sinkPeerId, Object error) {
    final current = _session;
    if (current == null) {
      return;
    }
    _setSession(current.markSink(
      sinkPeerId,
      state: AudioGroupSinkState.failed,
      lastError: _friendlyErrorMessage(error),
    ));
  }

  void _setSession(AudioGroupSession? session) {
    _session = session;
    notifyListeners();
  }

  Uri _audioUri({
    required String host,
    required int port,
    required String path,
  }) {
    final normalizedPath = path.isEmpty ? '/audio' : path;
    return Uri(
      scheme: 'ws',
      host: host,
      port: port,
      path: normalizedPath.startsWith('/')
          ? normalizedPath.substring(1)
          : normalizedPath,
    );
  }

  Int16List _applyPlaybackGain(Int16List pcm) {
    if (_playbackGain == 1.0) {
      return pcm;
    }
    final amplified = Int16List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      amplified[i] =
          (pcm[i] * _playbackGain).round().clamp(-32768, 32767).toInt();
    }
    return amplified;
  }

  double _normalizePlaybackGain(double gain) {
    if (!gain.isFinite) {
      return 1.0;
    }
    return gain.clamp(1.0, 3.0).toDouble();
  }

  String _friendlyErrorMessage(Object error) {
    if (error is PlatformException) {
      return error.message?.trim().isNotEmpty == true
          ? error.message!.trim()
          : error.code;
    }
    final text = error.toString();
    const platformPrefix = 'PlatformException(';
    if (!text.startsWith(platformPrefix)) {
      return text;
    }
    final parts = text
        .substring(platformPrefix.length, text.length - 1)
        .split(',')
        .map((part) => part.trim())
        .toList(growable: false);
    if (parts.length >= 2 && parts[1].isNotEmpty) {
      return parts[1];
    }
    return text;
  }
}

Future<AudioCodec> _createDefaultAudioGroupCodec(
  AudioStreamFormat format,
) async {
  final config = AudioCodecConfig.fromStreamFormat(format);
  switch (format.codec) {
    case AudioCodecKind.opus:
      return OpusAudioCodec.create(config);
    case AudioCodecKind.pcmS16le:
      return PcmPassthroughAudioCodec(config);
  }
}
