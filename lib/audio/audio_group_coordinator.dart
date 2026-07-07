import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:whisper/audio/audio_capture_source.dart';
import 'package:whisper/audio/audio_clock_sync.dart';
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
  static const int _latencyReportIntervalMicros = 1000000;
  static const int _defaultTargetLatencyMs = 55;
  static const int _minTargetLatencyMs = 55;
  static const int _maxTargetLatencyMs = 95;
  static const int _networkSafetyLatencyMs = 35;
  static const int _nativePlaybackLeadMicros = 35000;
  static const int _maxPlaybackPumpIntervalMicros = 10000;

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
  bool _playbackPumpRunning = false;
  bool _playbackPumpRequested = false;
  final Map<String, AudioClockSyncEstimator> _clockSyncEstimators =
      <String, AudioClockSyncEstimator>{};
  AudioGroupControlSender? _playbackSendControl;
  String _playbackGroupId = '';
  String _playbackStreamId = '';
  String _playbackLocalPeerId = '';
  int _lastPlaybackReportAtMicros = 0;
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
    int targetLatencyMs = _defaultTargetLatencyMs,
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

  Future<AudioGroupSession?> updateGroup({
    required Map<String, AudioChannelRole> sinks,
    required AudioGroupControlSender sendControl,
  }) async {
    final current = _session;
    if (current == null || !current.isLive) {
      throw StateError('No active audio group to update');
    }
    if (sinks.isEmpty) {
      throw ArgumentError.value(sinks, 'sinks', 'must not be empty');
    }
    final nextSinks = Map<String, AudioGroupSink>.from(current.sinks);
    final requestedPeerIds = sinks.keys.toSet();

    for (final sink in current.sinks.values) {
      if (requestedPeerIds.contains(sink.sinkPeerId)) {
        continue;
      }
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
      await _fanout.detachAndClose(sink.sinkPeerId);
      nextSinks.remove(sink.sinkPeerId);
    }

    for (final entry in sinks.entries) {
      final sinkPeerId = entry.key;
      final channelRole = entry.value;
      final existing = nextSinks[sinkPeerId];
      if (existing == null || existing.isTerminal) {
        final sessionId = _sessionIdFactory();
        nextSinks[sinkPeerId] = AudioGroupSink(
          sinkPeerId: sinkPeerId,
          sessionId: sessionId,
          channelRole: channelRole,
          state: AudioGroupSinkState.offered,
        );
        sendControl(
          sinkPeerId,
          AudioGroupControlMessage(
            action: AudioGroupControlAction.groupOffer,
            groupId: current.groupId,
            streamId: current.streamId,
            sessionId: sessionId,
            sourcePeerId: current.sourcePeerId,
            sinkPeerId: sinkPeerId,
            sinkPeerIds: sinks.keys.toList(growable: false),
            format: current.format,
            transport: AudioTransport.websocket,
            path: '/audio',
            channelRole: channelRole,
            targetLatencyMs: current.targetLatencyMs,
          ),
        );
        continue;
      }
      if (existing.channelRole == channelRole) {
        continue;
      }
      nextSinks[sinkPeerId] = existing.copyWith(channelRole: channelRole);
      sendControl(
        sinkPeerId,
        AudioGroupControlMessage(
          action: AudioGroupControlAction.groupUpdate,
          groupId: current.groupId,
          streamId: current.streamId,
          sessionId: existing.sessionId,
          sourcePeerId: current.sourcePeerId,
          sinkPeerId: sinkPeerId,
          sinkPeerIds: sinks.keys.toList(growable: false),
          format: current.format,
          transport: AudioTransport.websocket,
          path: '/audio',
          channelRole: channelRole,
          targetLatencyMs: current.targetLatencyMs,
        ),
      );
    }

    _setSession(current.copyWith(sinks: nextSinks));
    return _session;
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
      case AudioGroupControlAction.sinkJoinRequest:
        break;
      case AudioGroupControlAction.clockProbe:
        _handleClockProbe(
          current,
          message,
          localPeerId: localPeerId,
          sendControl: sendControl,
        );
        break;
      case AudioGroupControlAction.clockReport:
        await _handleClockReport(
          current,
          message,
          localPeerId: localPeerId,
          sendControl: sendControl,
        );
        break;
      case AudioGroupControlAction.latencyReport:
        _handleLatencyReport(
          current,
          message,
          localPeerId: localPeerId,
          sendControl: sendControl,
        );
        break;
      case AudioGroupControlAction.groupUpdate:
        await _handleUpdate(
          current,
          message,
          localPeerId: localPeerId,
        );
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
    _requestPlaybackPump();
    _maybeSendPlaybackLatencyReport();
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
    _playbackLocalPeerId = '';
    _playbackSendControl = null;
    _lastPlaybackReportAtMicros = 0;
    _playbackPumpTimer?.cancel();
    _playbackPumpTimer = null;
    await captureSource?.stop();
    await _fanout.closeAll();
    _clockSyncEstimators.clear();
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
      _playbackSendControl = sendControl;
      _playbackLocalPeerId = localPeerId;
      _lastPlaybackReportAtMicros = 0;
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
      _sendClockProbe(
        next,
        next.sinks[accept.sinkPeerId],
        sendControl: sendControl,
      );
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

  Future<void> _handleUpdate(
    AudioGroupSession current,
    AudioGroupControlMessage update, {
    required String localPeerId,
  }) async {
    if (update.sinkPeerId != localPeerId ||
        current.groupId != update.groupId ||
        current.streamId != update.streamId) {
      return;
    }
    _playbackScheduler?.updateChannelRole(update.channelRole);
    _setSession(current.markSink(
      localPeerId,
      sessionId: update.sessionId.isNotEmpty ? update.sessionId : null,
      channelRole: update.channelRole,
    ));
  }

  void _handleClockProbe(
    AudioGroupSession current,
    AudioGroupControlMessage probe, {
    required String localPeerId,
    required AudioGroupControlSender sendControl,
  }) {
    if (probe.sinkPeerId != localPeerId ||
        current.sourcePeerId != probe.sourcePeerId) {
      return;
    }
    final receivedAtMicros = _clockMicros();
    sendControl(
      probe.sourcePeerId,
      AudioGroupControlMessage(
        action: AudioGroupControlAction.clockReport,
        groupId: current.groupId,
        streamId: current.streamId,
        sessionId: probe.sessionId,
        sourcePeerId: probe.sourcePeerId,
        sinkPeerId: localPeerId,
        channelRole: probe.channelRole,
        targetLatencyMs: current.targetLatencyMs,
        sentAtMicros: probe.sentAtMicros,
        receivedAtMicros: receivedAtMicros,
        sinkClockMicros: _clockMicros(),
      ),
    );
  }

  Future<void> _handleClockReport(
    AudioGroupSession current,
    AudioGroupControlMessage report, {
    required String localPeerId,
    required AudioGroupControlSender sendControl,
  }) async {
    if (current.sourcePeerId == localPeerId) {
      await _handleClockReportAtSource(
        current,
        report,
        sendControl: sendControl,
      );
      return;
    }
    if (report.sinkPeerId != localPeerId) {
      return;
    }
    _playbackScheduler?.updateClockOffsetMicros(report.clockOffsetMicros);
    _setSession(current.markSink(
      localPeerId,
      clockOffsetMicros: report.clockOffsetMicros,
      rttMicros: report.rttMicros,
      jitterMicros: report.jitterMicros,
    ));
  }

  Future<void> _handleClockReportAtSource(
    AudioGroupSession current,
    AudioGroupControlMessage report, {
    required AudioGroupControlSender sendControl,
  }) async {
    final sink = current.sinks[report.sinkPeerId];
    if (sink == null || report.sentAtMicros <= 0) {
      return;
    }
    final sourceReceivedAtMicros = _clockMicros();
    final estimator = _clockSyncEstimators.putIfAbsent(
      report.sinkPeerId,
      AudioClockSyncEstimator.new,
    );
    estimator.addSample(AudioClockSyncSample(
      sourceSentAtMicros: report.sentAtMicros,
      sinkReceivedAtMicros: report.receivedAtMicros,
      sinkSentAtMicros: report.sinkClockMicros,
      sourceReceivedAtMicros: sourceReceivedAtMicros,
    ));
    final snapshot = estimator.snapshot;
    if (!snapshot.isValid) {
      _sendClockProbe(
        current,
        sink,
        sendControl: sendControl,
      );
      return;
    }
    final next = current.markSink(
      report.sinkPeerId,
      clockOffsetMicros: snapshot.clockOffsetMicros,
      rttMicros: snapshot.rttMicros,
      jitterMicros: snapshot.jitterMicros,
    );
    _setSession(next);
    sendControl(
      report.sinkPeerId,
      AudioGroupControlMessage(
        action: AudioGroupControlAction.clockReport,
        groupId: current.groupId,
        streamId: current.streamId,
        sessionId: sink.sessionId,
        sourcePeerId: current.sourcePeerId,
        sinkPeerId: report.sinkPeerId,
        channelRole: sink.channelRole,
        targetLatencyMs: current.targetLatencyMs,
        sentAtMicros: sourceReceivedAtMicros,
        clockOffsetMicros: snapshot.clockOffsetMicros,
        rttMicros: snapshot.rttMicros,
        jitterMicros: snapshot.jitterMicros,
      ),
    );
    await _ensureCaptureStartedWhenReady(next);
  }

  Future<void> _ensureCaptureStartedWhenReady(
    AudioGroupSession session,
  ) async {
    if (_captureSource != null) {
      return;
    }
    final sinks = session.sinks.values
        .where((sink) => !sink.isTerminal)
        .toList(growable: false);
    if (sinks.isEmpty) {
      return;
    }
    final allSinksSynchronized = sinks.every(
      (sink) => sink.state == AudioGroupSinkState.active && sink.rttMicros > 0,
    );
    if (!allSinksSynchronized) {
      return;
    }
    final targetLatencyMs = _targetLatencyMsForSinks(
      sinks,
      floorLatencyMs: session.targetLatencyMs,
    );
    final nextSession = targetLatencyMs == session.targetLatencyMs
        ? session
        : session.copyWith(targetLatencyMs: targetLatencyMs);
    if (!identical(nextSession, session)) {
      _setSession(nextSession);
    }
    await _ensureCaptureStarted(nextSession);
  }

  int _targetLatencyMsForSinks(
    Iterable<AudioGroupSink> sinks, {
    required int floorLatencyMs,
  }) {
    var targetLatencyMs = floorLatencyMs.clamp(
      _minTargetLatencyMs,
      _maxTargetLatencyMs,
    );
    for (final sink in sinks) {
      if (sink.rttMicros <= 0) {
        continue;
      }
      final oneWayMs = (sink.rttMicros / 2000).ceil();
      final jitterMs = (sink.jitterMicros / 1000).ceil();
      final candidateMs = oneWayMs + jitterMs + _networkSafetyLatencyMs;
      if (candidateMs > targetLatencyMs) {
        targetLatencyMs = candidateMs;
      }
    }
    return targetLatencyMs.clamp(
      _minTargetLatencyMs,
      _maxTargetLatencyMs,
    );
  }

  void _handleLatencyReport(
    AudioGroupSession current,
    AudioGroupControlMessage report, {
    required String localPeerId,
    required AudioGroupControlSender sendControl,
  }) {
    if (current.sourcePeerId != localPeerId ||
        !current.sinks.containsKey(report.sinkPeerId)) {
      return;
    }
    final next = current.markSink(
      report.sinkPeerId,
      clockOffsetMicros: report.clockOffsetMicros,
      rttMicros: report.rttMicros,
      jitterMicros: report.jitterMicros,
      bufferTargetMicros: report.bufferDepthMicros,
      latePacketCount: report.latePacketCount,
      syncErrorMicros: report.syncErrorMicros,
    );
    _setSession(next);
    _sendClockProbe(
      next,
      next.sinks[report.sinkPeerId],
      sendControl: sendControl,
    );
  }

  void _sendClockProbe(
    AudioGroupSession session,
    AudioGroupSink? sink, {
    required AudioGroupControlSender sendControl,
  }) {
    if (sink == null || sink.isTerminal) {
      return;
    }
    sendControl(
      sink.sinkPeerId,
      AudioGroupControlMessage(
        action: AudioGroupControlAction.clockProbe,
        groupId: session.groupId,
        streamId: session.streamId,
        sessionId: sink.sessionId,
        sourcePeerId: session.sourcePeerId,
        sinkPeerId: sink.sinkPeerId,
        channelRole: sink.channelRole,
        targetLatencyMs: session.targetLatencyMs,
        sentAtMicros: _clockMicros(),
      ),
    );
  }

  void _maybeSendPlaybackLatencyReport() {
    final scheduler = _playbackScheduler;
    final sendControl = _playbackSendControl;
    final localPeerId = _playbackLocalPeerId;
    final current = _session;
    if (scheduler == null ||
        sendControl == null ||
        current == null ||
        localPeerId.isEmpty) {
      return;
    }
    final now = _clockMicros();
    if (_lastPlaybackReportAtMicros != 0 &&
        now - _lastPlaybackReportAtMicros < _latencyReportIntervalMicros) {
      return;
    }
    final sink = current.sinks[localPeerId];
    if (sink == null) {
      return;
    }
    _lastPlaybackReportAtMicros = now;
    final report = scheduler.report;
    sendControl(
      current.sourcePeerId,
      AudioGroupControlMessage(
        action: AudioGroupControlAction.latencyReport,
        groupId: current.groupId,
        streamId: current.streamId,
        sessionId: sink.sessionId,
        sourcePeerId: current.sourcePeerId,
        sinkPeerId: localPeerId,
        channelRole: sink.channelRole,
        targetLatencyMs: current.targetLatencyMs,
        clockOffsetMicros: sink.clockOffsetMicros,
        rttMicros: sink.rttMicros,
        jitterMicros: sink.jitterMicros,
        bufferDepthMicros: report.bufferDepthMicros,
        latePacketCount: report.latePacketCount,
        syncErrorMicros: 0,
      ),
    );
  }

  Future<void> _ensureCaptureStarted(AudioGroupSession session) async {
    if (_captureSource != null) {
      return;
    }
    final codec = await _codecFactory(session.format);
    var nextTargetPlaybackTimeMicros = 0;
    final captureSource = AudioCaptureSource(
      codec: codec,
      platform: _platform,
      onPacket: (packet) {
        final current = _session;
        if (current == null || current.groupId != session.groupId) {
          return;
        }
        final durationMicros = current.format.frameDurationMs *
            Duration.microsecondsPerMillisecond;
        final targetBaseMicros = _clockMicros() +
            current.targetLatencyMs * Duration.microsecondsPerMillisecond;
        final targetPlaybackTimeMicros =
            nextTargetPlaybackTimeMicros <= targetBaseMicros
                ? targetBaseMicros
                : nextTargetPlaybackTimeMicros;
        nextTargetPlaybackTimeMicros =
            targetPlaybackTimeMicros + durationMicros;
        _fanout.send(
          AudioGroupPacketFrame(
            groupId: current.groupId,
            streamId: current.streamId,
            sessionId: current.streamId,
            sourcePeerId: current.sourcePeerId,
            sequence: packet.sequence,
            captureTimeMicros: packet.captureTimeMicros,
            targetPlaybackTimeMicros: targetPlaybackTimeMicros,
            durationMicros: durationMicros,
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
      outputLeadMicros: _nativePlaybackLeadMicros,
      requireClockOffsetBeforePlayback: true,
      writePcm: (pcm, targetPlaybackTimeMicros) {
        return _platform.writePcm(
          sessionId: offer.streamId,
          pcm: _applyPlaybackGain(pcm),
          targetPlaybackTimeMicros: targetPlaybackTimeMicros,
        );
      },
    );
  }

  Future<void> _stopPlaybackOnly() async {
    final playbackCodec = _playbackCodec;
    final playbackStreamId = _playbackStreamId;
    _playbackPumpTimer?.cancel();
    _playbackPumpTimer = null;
    _playbackPumpRequested = false;
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
    if (_playbackPumpRunning) {
      _playbackPumpRequested = true;
      return;
    }
    _playbackPumpRunning = true;
    _playbackPumpTimer?.cancel();
    _playbackPumpTimer = null;
    try {
      while (true) {
        _playbackPumpRequested = false;
        final scheduler = _playbackScheduler;
        if (scheduler == null) {
          return;
        }
        await scheduler.pump();
        if (!_playbackPumpRequested) {
          break;
        }
      }
    } finally {
      _playbackPumpRunning = false;
    }
    final scheduler = _playbackScheduler;
    if (scheduler == null) {
      return;
    }
    final report = scheduler.report;
    if (report.queuedPacketCount == 0) {
      return;
    }
    final delay = Duration(microseconds: _playbackPumpDelayMicros(report));
    _playbackPumpTimer = Timer(delay, () {
      unawaited(_pumpPlayback());
    });
  }

  void _requestPlaybackPump() {
    if (_playbackPumpRunning) {
      _playbackPumpRequested = true;
      return;
    }
    _playbackPumpTimer?.cancel();
    _playbackPumpTimer = null;
    unawaited(_pumpPlayback());
  }

  int _playbackPumpDelayMicros(AudioGroupPlaybackReport report) {
    if (report.nextPumpDelayMicros <= 0) {
      return 1;
    }
    if (report.nextPumpDelayMicros > _maxPlaybackPumpIntervalMicros) {
      return _maxPlaybackPumpIntervalMicros;
    }
    return report.nextPumpDelayMicros;
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
