import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:whisper/audio/audio_clock_sync.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_failure_reason.dart';
import 'package:whisper/audio/audio_group_media.dart';
import 'package:whisper/audio/audio_media_isolate.dart';
import 'package:whisper/audio/audio_group_playback_scheduler.dart';
import 'package:whisper/audio/audio_group_session.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

typedef AudioGroupControlSender = void Function(
  String peerId,
  AudioGroupControlMessage control,
);
typedef AudioGroupIdFactory = String Function();
typedef AudioGroupPlaybackGainProvider = Future<double> Function();

class AudioGroupCoordinator extends ChangeNotifier {
  AudioGroupCoordinator({
    AudioShareManager? manager,
    AudioGroupMedia? media,
    AudioPlatform? platform,
    AudioGroupCodecFactory? codecFactory,
    AudioGroupTransportFactory? transportFactory,
    AudioGroupPlaybackGainProvider? playbackGainProvider,
    AudioGroupClock? clockMicros,
    AudioGroupIdFactory? groupIdFactory,
    AudioGroupIdFactory? streamIdFactory,
    AudioGroupIdFactory? sessionIdFactory,
    this.offerAnswerLimit = const Duration(seconds: 10),
    this.captureRetryWaits = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
  })  : _manager = manager,
        _media = media ??
            LocalAudioGroupMedia(
              platform: platform ?? AudioPlatform(),
              codecFactory: codecFactory ?? createDefaultAudioGroupCodec,
              clockMicros: clockMicros ?? _wallClockMicros,
              transportFactory: transportFactory,
            ),
        _playbackGainProvider =
            playbackGainProvider ?? LocalSetting().audioSharePlaybackGain,
        _clockMicros = clockMicros ?? _wallClockMicros,
        _groupIdFactory = groupIdFactory ?? const Uuid().v4,
        _streamIdFactory = streamIdFactory ?? const Uuid().v4,
        _sessionIdFactory = sessionIdFactory ?? const Uuid().v4 {
    _media.onSinkFailure = _markSinkFailed;
    _removeChannelLifecycleListener =
        _manager?.addChannelLifecycleListener(_handleMediaChannelClosed);
  }

  static final AudioGroupCoordinator shared = AudioGroupCoordinator(
    manager: AudioShareManager.shared,
    media: _sharedMedia(),
  );

  /// On desktops the sound moves on its own isolate; see
  /// [DesktopAudioGroupMedia]. Android plays through this one.
  static AudioGroupMedia _sharedMedia() {
    final local = LocalAudioGroupMedia(
      platform: AudioPlatform.shared,
      codecFactory: createDefaultAudioGroupCodec,
      clockMicros: _wallClockMicros,
    );
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      return local;
    }
    return DesktopAudioGroupMedia(
      platform: AudioPlatform.shared,
      manager: AudioShareManager.shared,
      fallback: local,
    );
  }
  static const int _defaultTargetLatencyMs = 55;
  static const int _minTargetLatencyMs = 55;
  static const int _maxTargetLatencyMs = 95;
  static const int _networkSafetyLatencyMs = 35;

  final AudioShareManager? _manager;
  final AudioGroupMedia _media;
  final AudioGroupPlaybackGainProvider _playbackGainProvider;
  final AudioGroupClock _clockMicros;
  final AudioGroupIdFactory _groupIdFactory;
  final AudioGroupIdFactory _streamIdFactory;
  final AudioGroupIdFactory _sessionIdFactory;
  VoidCallback? _removeChannelLifecycleListener;
  int _groupGeneration = 0;
  final Map<String, int> _sinkAcceptGenerations = <String, int>{};

  AudioGroupSession? _session;
  AudioGroupCapture? _captureSource;
  Future<void>? _captureStartFuture;
  Future<void>? _captureStopFuture;
  int _captureGeneration = 0;
  AudioGroupPlayback? _playback;
  final Map<String, AudioClockSyncEstimator> _clockSyncEstimators =
      <String, AudioClockSyncEstimator>{};
  AudioGroupControlSender? _playbackSendControl;
  String _playbackGroupId = '';
  String _playbackStreamId = '';
  String _playbackSourcePeerId = '';
  String _playbackSessionId = '';
  String _playbackLocalPeerId = '';
  AudioChannelRole _playbackChannelRole = AudioChannelRole.stereo;
  int _playbackTargetLatencyMs = _defaultTargetLatencyMs;
  int _playbackGeneration = 0;
  _SinkRejoinContext? _sinkRejoinContext;

  /// Playback stopped because the connection dropped (the computers slept,
  /// Wi-Fi went), not because the user paused: once that source is connected
  /// again, this side asks to rejoin by itself. See [peerConnected].
  String _autoRejoinSourcePeerId = '';
  int _autoRejoinAttempts = 0;
  static const _maxAutoRejoinAttempts = 3;

  /// 在途 sinkJoinRequest 所属 group;应答 offer 到达或流程终止时清空。
  String _pendingSinkJoinGroupId = '';

  /// pause/disconnect 取消在途 join 后,一次性拒绝其交错到达的应答 offer:
  /// offer 到达时本地会话已清空,若照常自动接受会回到无声的"播放中"。
  /// 仅针对被取消的 join,源端主动 re-offer 不受影响;requestRejoinAsSink
  /// 重新放行。
  String _declinedOfferGroupId = '';
  double _playbackGain = 1.0;

  // Whether sound really goes out and comes in, which the session alone does
  // not say: a sink that hears nothing stops reporting, and its last numbers
  // stayed on screen as if all was well. Looked at every half second while a
  // group or a playback runs, since nothing arrives to say it stopped.
  static const int _silentAfterMicros = 2000000;
  static const int _unheardAfterMicros = 3000000;
  static const int _starvedAfterMicros = 2500000;

  /// More than a sink keeps: it drops packets before they are due.
  static const int _maxSinkBufferMicros = 250000;
  int _captureStartedAtMicros = 0;
  int _lastQuietAtMicros = 0;
  final Map<String, int> _sinkHeardAtMicros = <String, int>{};
  int _playbackStartedAtMicros = 0;
  int _playbackHeardAtMicros = 0;
  Timer? _healthTimer;
  String _healthSignature = '';
  AudioFailureReason? _captureFailure;

  AudioGroupSession? get session => _session;

  bool get hasLiveSession => _session?.isLive == true;

  bool get isPlaybackActive => _playbackStreamId.isNotEmpty;

  /// Who this device is playing, while [isPlaybackActive].
  String get playbackSourcePeerId => _playbackSourcePeerId;

  /// Why this device's sound could not be captured for the running group, so
  /// a source does not look like it is playing when nothing is heard.
  AudioFailureReason? get captureFailure => _captureFailure;

  /// The sound is close to breaking up right now: a sink (or this device's
  /// own playback) has almost nothing buffered, or got packets too late since
  /// the last look. What shares the link, like a paste's files, gives way.
  bool get audioStrained {
    final now = _clockMicros();
    var strained = false;
    final current = _session;
    if (current != null && current.isLive && _captureSource != null) {
      // With nothing to send, a sink has nothing to report either.
      final sending = !sourceSilent;
      for (final sink in current.sinks.values) {
        if (sink.state != AudioGroupSinkState.active) continue;
        final heard = _sinkHeardAtMicros[sink.sinkPeerId] ?? 0;
        final late = sink.latePacketCount;
        final before = _lateSeen[sink.sinkPeerId];
        _lateSeen[sink.sinkPeerId] = late;
        if (heard == 0) continue;
        // Reports stopped coming: the sink is too busy to say how it is.
        if ((sending && now - heard > _strainReportAgeMicros) ||
            (before != null && late > before) ||
            sink.bufferTargetMicros < _strainBufferMicros) {
          strained = true;
        }
      }
    }
    final own = _ownPlaybackReport;
    if (_playback != null &&
        own != null &&
        now - _ownPlaybackReportAtMicros <= _strainReportAgeMicros) {
      final before = _lateSeen[''];
      _lateSeen[''] = own.latePacketCount;
      if ((before != null && own.latePacketCount > before) ||
          own.bufferDepthMicros < _strainBufferMicros) {
        strained = true;
      }
    }
    return strained;
  }

  static const _strainBufferMicros = 25000;
  static const _strainReportAgeMicros = 1500000;
  final Map<String, int> _lateSeen = <String, int>{};
  AudioGroupPlaybackReport? _ownPlaybackReport;
  int _ownPlaybackReportAtMicros = 0;

  /// This device shares, but has had nothing to send for a while: on Windows,
  /// the computer is playing nothing.
  bool get sourceSilent {
    final capture = _captureSource;
    final current = _session;
    if (capture == null || current == null || !current.isLive) {
      return false;
    }
    final sent = capture.lastSentAtMicros > _captureStartedAtMicros
        ? capture.lastSentAtMicros
        : _captureStartedAtMicros;
    return _clockMicros() - sent >= _silentAfterMicros;
  }

  /// A member this device's sound does not reach: it has not reported while
  /// packets went out, or it holds more than it can play and drops them.
  bool sinkUnheard(String sinkPeerId) {
    final current = _session;
    if (current == null || !current.isLive || _captureSource == null) {
      return false;
    }
    final sink = current.sinks[sinkPeerId];
    if (sink == null || sink.state != AudioGroupSinkState.active) {
      return false;
    }
    if (sink.bufferTargetMicros > _maxSinkBufferMicros) {
      return true;
    }
    if (sourceSilent) {
      return false;
    }
    var since = _sinkHeardAtMicros[sinkPeerId] ?? 0;
    if (_lastQuietAtMicros > since) {
      since = _lastQuietAtMicros;
    }
    return _clockMicros() - since > _unheardAfterMicros;
  }

  /// Playing another device's sound, of which nothing has come for a while.
  bool get playbackStarved {
    if (_playback == null) {
      return false;
    }
    final since = _playbackHeardAtMicros > _playbackStartedAtMicros
        ? _playbackHeardAtMicros
        : _playbackStartedAtMicros;
    return _clockMicros() - since > _starvedAfterMicros;
  }

  void _checkHealth() {
    final current = _session;
    final running = (current != null && current.isLive) || _playback != null;
    if (!running) {
      _healthTimer?.cancel();
      _healthTimer = null;
      _healthSignature = '';
      return;
    }
    _healthTimer ??= Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _checkHealth(),
    );
    final silent = sourceSilent;
    if (silent || _captureSource == null) {
      // Members get a while to report again once there is sound.
      _lastQuietAtMicros = _clockMicros();
    }
    final signature = [
      silent,
      playbackStarved,
      for (final sinkPeerId in current?.sinks.keys ?? const <String>[])
        if (sinkUnheard(sinkPeerId)) sinkPeerId,
    ].join('|');
    if (signature != _healthSignature) {
      final first = _healthSignature.isEmpty;
      _healthSignature = signature;
      if (!first) {
        notifyListeners();
      }
    }
  }

  bool get canRejoinAsSink => _sinkRejoinContext != null;

  String get rejoinSourcePeerId => _sinkRejoinContext?.sourcePeerId ?? '';

  String get rejoinSessionId => _sinkRejoinContext?.sessionId ?? '';

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
    _groupGeneration += 1;
    _sinkAcceptGenerations.clear();
    _captureGeneration += 1;
    _captureFailure = null;
    _captureRetries = 0;
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
      _awaitAnswer(sinkPeerId, sessionId);
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

  /// With [reofferTerminal] false a sink that failed or left stays as it is,
  /// keeping any new channel for when it comes back. Without that, changing
  /// one member would restart a speaker somebody paused on the other device.
  Future<AudioGroupSession?> updateGroup({
    required Map<String, AudioChannelRole> sinks,
    required AudioGroupControlSender sendControl,
    bool reofferTerminal = true,
  }) async {
    final current = _session;
    if (current == null || (!current.isLive && current.sinks.isEmpty)) {
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
      _sinkAcceptGenerations[sink.sinkPeerId] =
          (_sinkAcceptGenerations[sink.sinkPeerId] ?? 0) + 1;
      if (!sink.isTerminal) {
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
      await _media.disconnectSink(sink.sinkPeerId);
      nextSinks.remove(sink.sinkPeerId);
    }

    for (final entry in sinks.entries) {
      final sinkPeerId = entry.key;
      final channelRole = entry.value;
      final existing = nextSinks[sinkPeerId];
      if (existing == null || (existing.isTerminal && reofferTerminal)) {
        final sessionId = _sessionIdFactory();
        nextSinks[sinkPeerId] = AudioGroupSink(
          sinkPeerId: sinkPeerId,
          sessionId: sessionId,
          channelRole: channelRole,
          state: AudioGroupSinkState.offered,
        );
        _awaitAnswer(sinkPeerId, sessionId);
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
      if (existing.isTerminal) {
        continue;
      }
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

    final next = current.copyWith(
      sinks: nextSinks,
      state: current.isLive || nextSinks.values.every((sink) => sink.isTerminal)
          ? null
          : AudioGroupState.offering,
    );
    _setSession(next);
    _stopCaptureIfNoActiveSinks(next);
    return _session;
  }

  Future<AudioGroupSession?> handleControlMessage(
    AudioGroupControlMessage message, {
    required String localPeerId,
    required String remoteHost,
    required int remotePort,
    required AudioGroupControlSender sendControl,
    Uint8List? mediaSendKey,
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
    if (current == null) {
      if (message.action == AudioGroupControlAction.groupStop &&
          _sinkRejoinContext?.groupId == message.groupId) {
        _sinkRejoinContext = null;
        if (_pendingSinkJoinGroupId == message.groupId) {
          _pendingSinkJoinGroupId = ''; // 源端已停组,在途 join 作废
        }
        notifyListeners();
      }
      return current;
    }
    if (current.groupId != message.groupId) {
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
          mediaSendKey: mediaSendKey,
        );
        break;
      case AudioGroupControlAction.groupReject:
      case AudioGroupControlAction.error:
        final failureReason = audioFailureReasonFromWire(message.errorMessage);
        _setSession(current.markSink(
          message.sinkPeerId,
          state: AudioGroupSinkState.failed,
          sessionId: message.sessionId,
          lastError: failureReason.name,
        ));
        break;
      case AudioGroupControlAction.groupStop:
        if (current.sourcePeerId != localPeerId) {
          await stopLocal();
        } else {
          _sinkAcceptGenerations[message.sinkPeerId] =
              (_sinkAcceptGenerations[message.sinkPeerId] ?? 0) + 1;
          await _media.disconnectSink(message.sinkPeerId);
          final next = current.markSink(
            message.sinkPeerId,
            state: AudioGroupSinkState.stopped,
            sessionId: message.sessionId,
          );
          _setSession(next);
          _stopCaptureIfNoActiveSinks(next);
        }
        break;
      case AudioGroupControlAction.groupOffer:
        break;
      case AudioGroupControlAction.sinkJoinRequest:
        final requestedSink = current.sinks[message.sinkPeerId];
        if (current.sourcePeerId == localPeerId && requestedSink != null) {
          final sinks = <String, AudioChannelRole>{
            for (final sink in current.sinks.values)
              if (!sink.isTerminal ||
                  sink.sinkPeerId == requestedSink.sinkPeerId)
                sink.sinkPeerId: sink.channelRole,
          };
          if (requestedSink.isTerminal) {
            final sessionId = _sessionIdFactory();
            sendControl(
              requestedSink.sinkPeerId,
              AudioGroupControlMessage(
                action: AudioGroupControlAction.groupOffer,
                groupId: current.groupId,
                streamId: current.streamId,
                sessionId: sessionId,
                sourcePeerId: current.sourcePeerId,
                sinkPeerId: requestedSink.sinkPeerId,
                sinkPeerIds: sinks.keys.toList(growable: false),
                format: current.format,
                transport: AudioTransport.websocket,
                path: '/audio',
                channelRole: requestedSink.channelRole,
                targetLatencyMs: current.targetLatencyMs,
              ),
            );
            _setSession(current.markSink(
              requestedSink.sinkPeerId,
              state: AudioGroupSinkState.offered,
              sessionId: sessionId,
              channelRole: requestedSink.channelRole,
            ));
          }
        }
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

  Future<void> handlePacket(AudioGroupPacketFrame packet) {
    final playback = _playback;
    if (playback == null ||
        packet.groupId != _playbackGroupId ||
        packet.streamId != _playbackStreamId) {
      return Future<void>.value();
    }
    playback.deliver(packet);
    return Future<void>.value();
  }

  Future<void> stopGroup({
    required AudioGroupControlSender sendControl,
  }) async {
    final current = _session;
    if (current == null) {
      return;
    }
    for (final sink in current.sinks.values) {
      // Over already (the connection went, or it stopped): the device may
      // have restarted since and not know the session, and an older one
      // drops the whole connection over a stop it can't place.
      if (sink.isTerminal) continue;
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

  /// 暂停=断流:通知源端停止对本 sink 的 fanout,本地停止播放,
  /// 但保留后续请求 re-offer 所需的上下文。
  /// buffering(rejoin 在途)时活播字段已清空,回退到 rejoin 上下文,
  /// 使暂停等价于"取消在途 rejoin"而非静默 no-op;被取消 join 的
  /// 应答 offer 若交错到达,将被一次性拒收。
  Future<void> pausePlaybackAsSink() async {
    final resolved = _resolveSinkControlContext();
    if (resolved == null) {
      return;
    }
    _armOfferDeclineIfJoinPending(resolved.groupId);
    _sinkRejoinContext = resolved;
    _autoRejoinSourcePeerId = '';
    resolved.sendControl(resolved.sourcePeerId, _sinkStopMessage(resolved));
    await _stopPlaybackOnly();
    _setSession(null);
  }

  /// The connection to [peerId] is up, or its profile was refreshed. Playback
  /// from it that the connection, not the user, stopped asks to rejoin.
  void peerConnected(String peerId) {
    if (peerId.isEmpty || _autoRejoinSourcePeerId != peerId) {
      return;
    }
    _autoRejoinSourcePeerId = '';
    _autoRejoinAttempts += 1;
    // The control channel settles right after the connection is registered.
    Timer(const Duration(seconds: 1), () {
      if (_sinkRejoinContext?.sourcePeerId != peerId ||
          _pendingSinkJoinGroupId.isNotEmpty) {
        return;
      }
      unawaited(requestRejoinAsSink());
    });
  }

  /// 播放=重新加入:向源端请求 re-offer,后续复用现有 offer/accept 流程。
  Future<bool> requestRejoinAsSink() async {
    final context = _sinkRejoinContext;
    if (context == null) {
      return false;
    }
    context.sendControl(
      context.sourcePeerId,
      AudioGroupControlMessage(
        action: AudioGroupControlAction.sinkJoinRequest,
        groupId: context.groupId,
        streamId: context.streamId,
        sessionId: context.sessionId,
        sourcePeerId: context.sourcePeerId,
        sinkPeerId: context.localPeerId,
        channelRole: context.channelRole,
        targetLatencyMs: context.targetLatencyMs,
      ),
    );
    _pendingSinkJoinGroupId = context.groupId;
    _declinedOfferGroupId = ''; // 用户重新播放,放行后续 offer
    return true;
  }

  Future<void> disconnectPlaybackAsSink() async {
    final resolved = _resolveSinkControlContext();
    if (resolved != null) {
      _armOfferDeclineIfJoinPending(resolved.groupId);
      resolved.sendControl(resolved.sourcePeerId, _sinkStopMessage(resolved));
    }
    await stopLocal();
  }

  /// pause/disconnect 共用的控制上下文解析:优先取活播字段,
  /// buffering(rejoin 在途)时活播字段已清空则回退 rejoin 上下文,
  /// 两者都无法定位时返回 null。
  _SinkRejoinContext? _resolveSinkControlContext() {
    final context = _sinkRejoinContext;
    final sendControl = _playbackSendControl ?? context?.sendControl;
    final groupId =
        _playbackGroupId.isNotEmpty ? _playbackGroupId : context?.groupId ?? '';
    final streamId = _playbackStreamId.isNotEmpty
        ? _playbackStreamId
        : context?.streamId ?? '';
    final sessionId = _playbackSessionId.isNotEmpty
        ? _playbackSessionId
        : context?.sessionId ?? '';
    final sourcePeerId = _playbackSourcePeerId.isNotEmpty
        ? _playbackSourcePeerId
        : context?.sourcePeerId ?? '';
    final localPeerId = _playbackLocalPeerId.isNotEmpty
        ? _playbackLocalPeerId
        : context?.localPeerId ?? '';
    // channelRole/targetLatencyMs 无空值语义,以活播流是否在用为轴取值。
    final channelRole = _playbackStreamId.isNotEmpty
        ? _playbackChannelRole
        : context?.channelRole ?? AudioChannelRole.stereo;
    final targetLatencyMs = _playbackStreamId.isNotEmpty
        ? _playbackTargetLatencyMs
        : context?.targetLatencyMs ?? _defaultTargetLatencyMs;
    if (sendControl == null ||
        groupId.isEmpty ||
        streamId.isEmpty ||
        sessionId.isEmpty ||
        sourcePeerId.isEmpty ||
        localPeerId.isEmpty) {
      return null;
    }
    return _SinkRejoinContext(
      groupId: groupId,
      streamId: streamId,
      sessionId: sessionId,
      sourcePeerId: sourcePeerId,
      localPeerId: localPeerId,
      channelRole: channelRole,
      targetLatencyMs: targetLatencyMs,
      sendControl: sendControl,
    );
  }

  AudioGroupControlMessage _sinkStopMessage(_SinkRejoinContext context) {
    return AudioGroupControlMessage(
      action: AudioGroupControlAction.groupStop,
      groupId: context.groupId,
      streamId: context.streamId,
      sessionId: context.sessionId,
      sourcePeerId: context.sourcePeerId,
      sinkPeerId: context.localPeerId,
      channelRole: context.channelRole,
      targetLatencyMs: context.targetLatencyMs,
    );
  }

  void _armOfferDeclineIfJoinPending(String groupId) {
    if (_pendingSinkJoinGroupId == groupId) {
      _declinedOfferGroupId = groupId;
      _pendingSinkJoinGroupId = '';
    }
  }

  Future<void> stopLocal() async {
    for (final timer in _offerTimers.values) {
      timer.cancel();
    }
    _offerTimers.clear();
    _captureRetry?.cancel();
    _captureRetry = null;
    _captureRetries = 0;
    _groupGeneration += 1;
    _sinkAcceptGenerations.clear();
    _captureGeneration += 1;
    _playbackGeneration += 1;
    final captureSource = _captureSource;
    final playback = _playback;
    _captureSource = null;
    _playback = null;
    _playbackGroupId = '';
    _playbackStreamId = '';
    _playbackSourcePeerId = '';
    _playbackSessionId = '';
    _playbackLocalPeerId = '';
    _playbackChannelRole = AudioChannelRole.stereo;
    _playbackTargetLatencyMs = _defaultTargetLatencyMs;
    _playbackSendControl = null;
    _sinkRejoinContext = null;
    _autoRejoinSourcePeerId = '';
    _pendingSinkJoinGroupId = '';
    _captureFailure = null;
    _sinkHeardAtMicros.clear();
    await _stopCaptureSource(captureSource);
    await _media.disconnectAllSinks();
    _clockSyncEstimators.clear();
    await playback?.stop();
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
    if (offer.groupId == _pendingSinkJoinGroupId) {
      _pendingSinkJoinGroupId = ''; // 在途 join 已被应答
    }
    if (offer.groupId == _declinedOfferGroupId) {
      // 这是已被暂停/断开取消的 join 的迟到应答:一次性拒收,回 groupStop
      // 让源端按停止语义标记本 sink(源端多半已处理过 stop,幂等)。
      _declinedOfferGroupId = '';
      sendControl(
        offer.sourcePeerId,
        AudioGroupControlMessage(
          action: AudioGroupControlAction.groupStop,
          groupId: offer.groupId,
          streamId: offer.streamId,
          sessionId: offer.sessionId,
          sourcePeerId: offer.sourcePeerId,
          sinkPeerId: offer.sinkPeerId,
          channelRole: offer.channelRole,
          targetLatencyMs: offer.targetLatencyMs,
        ),
      );
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
          errorMessage: AudioFailureReason.busy.name,
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
          errorMessage: AudioFailureReason.protocol.name,
        ),
      );
      return;
    }

    final previousRejoinContext = _sinkRejoinContext;
    try {
      if (!await _startPlayback(offer, format: format)) {
        return;
      }
      _playbackSendControl = sendControl;
      _playbackLocalPeerId = localPeerId;
      _sinkRejoinContext = null;
      _autoRejoinSourcePeerId = '';
      _autoRejoinAttempts = 0;
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
          mediaPort: _playback?.mediaPort ?? 0,
        ),
      );
    } catch (error) {
      final failureReason = audioFailureReasonFor(
        error,
        context: AudioFailureContext.playback,
      );
      await stopLocal();
      if (previousRejoinContext != null) {
        _sinkRejoinContext = previousRejoinContext;
        notifyListeners();
      }
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
          errorMessage: failureReason.name,
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
    Uint8List? mediaSendKey,
  }) async {
    if (current.sourcePeerId != localPeerId) {
      return;
    }
    final sink = current.sinks[accept.sinkPeerId];
    if (sink == null || sink.isTerminal) {
      return;
    }
    final groupGeneration = _groupGeneration;
    final expectedSinkSessionId = sink.sessionId;
    final acceptGeneration =
        (_sinkAcceptGenerations[accept.sinkPeerId] ?? 0) + 1;
    _sinkAcceptGenerations[accept.sinkPeerId] = acceptGeneration;
    AudioGroupSinkLink? connectedTransport;
    try {
      if (remoteHost.isNotEmpty && remotePort > 0) {
        Uri uriAt(int port) => _audioUri(
              host: remoteHost,
              port: port,
              path: accept.path,
              sessionId: accept.sessionId,
              transportToken: accept.transportToken,
            );
        connectedTransport = await _media.connectSink(
          AudioGroupSinkDial(
            sinkPeerId: accept.sinkPeerId,
            sourcePeerId: accept.sourcePeerId,
            sessionId: accept.sessionId,
            uri: uriAt(remotePort),
            mediaUri: accept.mediaPort > 0 ? uriAt(accept.mediaPort) : null,
            transportToken: accept.transportToken,
            mediaSendKey: mediaSendKey,
          ),
        );
      }
      if (!_isCurrentAccept(
        accept,
        groupGeneration: groupGeneration,
        acceptGeneration: acceptGeneration,
        expectedSinkSessionId: expectedSinkSessionId,
      )) {
        await _ignoreGroupTransportClose(connectedTransport);
        return;
      }
      final latest = _session!;
      final candidate = latest.markSink(
        accept.sinkPeerId,
        state: AudioGroupSinkState.active,
        sessionId: accept.sessionId,
        channelRole: accept.channelRole,
        host: remoteHost,
        port: remotePort,
      );
      _sendClockProbe(
        candidate,
        candidate.sinks[accept.sinkPeerId],
        sendControl: sendControl,
      );
      if (!_isCurrentAccept(
        accept,
        groupGeneration: groupGeneration,
        acceptGeneration: acceptGeneration,
        expectedSinkSessionId: expectedSinkSessionId,
      )) {
        await _ignoreGroupTransportClose(connectedTransport);
        return;
      }
      final next = _session!.markSink(
        accept.sinkPeerId,
        state: AudioGroupSinkState.active,
        sessionId: accept.sessionId,
        channelRole: accept.channelRole,
        host: remoteHost,
        port: remotePort,
      );
      _setSession(next);
      final transport = connectedTransport;
      if (transport != null) {
        _media.attachSink(accept.sinkPeerId, transport);
        _sinkHeardAtMicros[accept.sinkPeerId] = _clockMicros();
      }
    } catch (error) {
      await _ignoreGroupTransportClose(connectedTransport);
      if (!_isCurrentAccept(
        accept,
        groupGeneration: groupGeneration,
        acceptGeneration: acceptGeneration,
        expectedSinkSessionId: expectedSinkSessionId,
      )) {
        return;
      }
      final errorMessage = audioFailureReasonFor(
        error,
        context: AudioFailureContext.transport,
      ).name;
      _setSession(_session!.markSink(
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

  bool _isCurrentAccept(
    AudioGroupControlMessage accept, {
    required int groupGeneration,
    required int acceptGeneration,
    required String expectedSinkSessionId,
  }) {
    final latest = _session;
    final latestSink = latest?.sinks[accept.sinkPeerId];
    return groupGeneration == _groupGeneration &&
        _sinkAcceptGenerations[accept.sinkPeerId] == acceptGeneration &&
        latest?.groupId == accept.groupId &&
        latest?.streamId == accept.streamId &&
        latest?.sourcePeerId == accept.sourcePeerId &&
        latestSink != null &&
        !latestSink.isTerminal &&
        latestSink.sessionId == expectedSinkSessionId;
  }

  Future<void> _ignoreGroupTransportClose(
    AudioGroupSinkLink? transport,
  ) async {
    if (transport == null) {
      return;
    }
    try {
      await _media.closeLink(transport);
    } catch (_) {}
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
    _playback?.updateChannelRole(update.channelRole);
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
    _playback?.updateClockOffset(report.clockOffsetMicros);
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
    _sinkHeardAtMicros[report.sinkPeerId] = _clockMicros();
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

  void _sendPlaybackLatencyReport(AudioGroupPlaybackReport report) {
    _ownPlaybackReport = report;
    _ownPlaybackReportAtMicros = _clockMicros();
    final sendControl = _playbackSendControl;
    final localPeerId = _playbackLocalPeerId;
    final current = _session;
    if (sendControl == null || current == null || localPeerId.isEmpty) {
      return;
    }
    final sink = current.sinks[localPeerId];
    if (sink == null) {
      return;
    }
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
    final groupGeneration = _groupGeneration;
    while (_captureSource == null) {
      final starting = _captureStartFuture;
      if (starting != null) {
        await starting;
        continue;
      }
      final stopping = _captureStopFuture;
      if (stopping != null) {
        try {
          await stopping;
        } catch (_) {}
        continue;
      }
      final generation = _captureGeneration;
      if (!_isCurrentCaptureSession(
        session,
        generation,
        groupGeneration,
      )) {
        return;
      }
      late final Future<void> running;
      running = _startCaptureForSession(
        session,
        generation,
        groupGeneration,
      ).whenComplete(() {
        if (identical(_captureStartFuture, running)) {
          _captureStartFuture = null;
        }
      });
      _captureStartFuture = running;
      await running;
      return;
    }
  }

  Future<void> _startCaptureForSession(
    AudioGroupSession session,
    int generation,
    int groupGeneration,
  ) async {
    late final AudioGroupCapture captureSource;
    captureSource = _media.capture(
      AudioGroupCaptureSpec(
        groupId: session.groupId,
        streamId: session.streamId,
        sourcePeerId: session.sourcePeerId,
        format: session.format,
        targetLatencyMs: session.targetLatencyMs,
      ),
      shouldStart: () =>
          _isCurrentCaptureSession(session, generation, groupGeneration),
      // Native capture gave up after it had started. Shown as a failure, and
      // the next _ensureCaptureStarted may start it again.
      onError: (error) {
        if (!identical(_captureSource, captureSource)) {
          return;
        }
        _captureSource = null;
        _captureGeneration += 1;
        unawaited(_stopCaptureSource(captureSource));
        _noteCaptureFailure(error);
      },
    );
    _captureSource = captureSource;
    _captureStartedAtMicros = _clockMicros();
    _lastQuietAtMicros = _captureStartedAtMicros;
    try {
      await captureSource.start();
    } catch (error) {
      final shouldReport = _isCurrentCaptureSession(
            session,
            generation,
            groupGeneration,
          ) &&
          identical(_captureSource, captureSource);
      if (identical(_captureSource, captureSource)) {
        _captureSource = null;
        _captureGeneration += 1;
        await _stopCaptureSource(captureSource);
      }
      if (shouldReport) {
        _noteCaptureFailure(error);
        rethrow;
      }
      return;
    }
    _captureRetries = 0;
    if (_captureFailure != null) {
      _captureFailure = null;
      notifyListeners();
    }
    if (!_isCurrentCaptureSession(session, generation, groupGeneration) ||
        !identical(_captureSource, captureSource)) {
      if (identical(_captureSource, captureSource)) {
        _captureSource = null;
        _captureGeneration += 1;
        await _stopCaptureSource(captureSource);
      }
    }
  }

  bool _isCurrentCaptureSession(
    AudioGroupSession session,
    int generation,
    int groupGeneration,
  ) {
    final current = _session;
    return groupGeneration == _groupGeneration &&
        generation == _captureGeneration &&
        current?.groupId == session.groupId &&
        current?.streamId == session.streamId &&
        current?.sourcePeerId == session.sourcePeerId &&
        current!.activeSinks.isNotEmpty;
  }

  void _noteCaptureFailure(Object error) {
    final reason = audioFailureReasonFor(
      error,
      context: AudioFailureContext.capture,
    );
    if (reason != _captureFailure) {
      _captureFailure = reason;
      notifyListeners();
    }
    _retryCaptureLater();
  }

  /// Waits before capture is started again after it failed while members
  /// still listen: system audio capture now and then does not open in time,
  /// and nothing else would start it again. Not for a missing permission.
  final List<Duration> captureRetryWaits;
  int _captureRetries = 0;
  Timer? _captureRetry;

  void _retryCaptureLater() {
    if (_captureFailure == AudioFailureReason.permission ||
        _captureRetries >= captureRetryWaits.length) {
      return;
    }
    final wait = captureRetryWaits[_captureRetries++];
    _captureRetry?.cancel();
    _captureRetry = Timer(wait, () {
      _captureRetry = null;
      final current = _session;
      if (current == null ||
          !current.isLive ||
          current.activeSinks.isEmpty ||
          _captureSource != null) {
        return;
      }
      unawaited(_ensureCaptureStarted(current).catchError((Object _) {}));
    });
  }

  Future<void> _stopCaptureSource(AudioGroupCapture? captureSource) {
    if (captureSource == null) {
      return _captureStopFuture ?? Future<void>.value();
    }
    final previous = _captureStopFuture;
    late final Future<void> stopping;
    stopping = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      await captureSource.stop();
    }()
        .whenComplete(() {
      if (identical(_captureStopFuture, stopping)) {
        _captureStopFuture = null;
      }
    });
    _captureStopFuture = stopping;
    return stopping;
  }

  Future<bool> _startPlayback(
    AudioGroupControlMessage offer, {
    required AudioStreamFormat format,
  }) async {
    final priorGeneration = _playbackGeneration;
    await _stopPlaybackOnly();
    if (_playbackGeneration != priorGeneration + 1) {
      return false;
    }
    final generation = ++_playbackGeneration;
    try {
      _playbackGain = _normalizePlaybackGain(await _playbackGainProvider());
    } catch (_) {
      if (generation != _playbackGeneration) {
        return false;
      }
      rethrow;
    }
    if (generation != _playbackGeneration) {
      return false;
    }
    _playbackGroupId = offer.groupId;
    _playbackStreamId = offer.streamId;
    _playbackSourcePeerId = offer.sourcePeerId;
    _playbackSessionId = offer.sessionId;
    _playbackChannelRole = offer.channelRole;
    _playbackTargetLatencyMs = offer.targetLatencyMs;
    late final AudioGroupPlayback playback;
    final AudioGroupPlayback started;
    try {
      started = await _media.startPlayback(
        AudioGroupPlaybackSpec(
          groupId: offer.groupId,
          streamId: offer.streamId,
          sessionId: offer.sessionId,
          sourcePeerId: offer.sourcePeerId,
          format: format,
          channelRole: offer.channelRole,
          gain: _playbackGain,
        ),
        onReport: (report) {
          if (identical(_playback, playback)) {
            _playbackHeardAtMicros = _clockMicros();
            _sendPlaybackLatencyReport(report);
          }
        },
        onFailure: (error) {
          if (identical(_playback, playback)) {
            _failPlaybackAsSink(
              audioFailureReasonFor(
                error,
                context: AudioFailureContext.playback,
              ),
            );
          }
        },
        shouldStart: () => generation == _playbackGeneration,
      );
    } catch (_) {
      if (generation != _playbackGeneration) {
        return false;
      }
      rethrow;
    }
    playback = started;
    if (generation != _playbackGeneration) {
      await playback.stop();
      return false;
    }
    _playback = playback;
    _playbackStartedAtMicros = _clockMicros();
    _playbackHeardAtMicros = 0;
    _checkHealth();
    return true;
  }

  Future<void> _stopPlaybackOnly() async {
    _playbackGeneration += 1;
    final playback = _playback;
    _playback = null;
    _playbackGroupId = '';
    _playbackStreamId = '';
    _playbackSourcePeerId = '';
    _playbackSessionId = '';
    _playbackChannelRole = AudioChannelRole.stereo;
    _playbackTargetLatencyMs = _defaultTargetLatencyMs;
    _checkHealth();
    await playback?.stop();
  }

  /// How long an offered sink has to answer. An offer can go down with a
  /// connection that was being replaced, and nothing would ever say so: the
  /// sink would wait as offered for good.
  final Duration offerAnswerLimit;
  final Map<String, Timer> _offerTimers = <String, Timer>{};

  void _awaitAnswer(String sinkPeerId, String sessionId) {
    _offerTimers.remove(sessionId)?.cancel();
    _offerTimers[sessionId] = Timer(offerAnswerLimit, () {
      _offerTimers.remove(sessionId);
      final current = _session;
      final sink = current?.sinks[sinkPeerId];
      if (current == null ||
          sink == null ||
          sink.sessionId != sessionId ||
          sink.state != AudioGroupSinkState.offered) {
        return;
      }
      final next = current.markSink(
        sinkPeerId,
        state: AudioGroupSinkState.failed,
        lastError: AudioFailureReason.transport.name,
      );
      _setSession(next);
      _stopCaptureIfNoActiveSinks(next);
    });
  }

  void _markSinkFailed(String sinkPeerId, Object error) {
    final current = _session;
    if (current == null) {
      return;
    }
    final next = current.markSink(
      sinkPeerId,
      state: AudioGroupSinkState.failed,
      lastError: audioFailureReasonFor(
        error,
        context: AudioFailureContext.transport,
      ).name,
    );
    _setSession(next);
    _stopCaptureIfNoActiveSinks(next);
  }

  void _stopCaptureIfNoActiveSinks(AudioGroupSession session) {
    if (session.activeSinks.isNotEmpty ||
        (_captureSource == null && _captureStartFuture == null)) {
      return;
    }
    _captureGeneration += 1;
    final captureSource = _captureSource;
    _captureSource = null;
    if (captureSource != null) {
      unawaited(_stopCaptureSource(captureSource).catchError((Object _) {}));
    }
  }

  void _handleMediaChannelClosed(AudioMediaChannelClosedEvent event) {
    if (event.expected || event.claim.namespace != 'audio-group') {
      return;
    }
    final current = _session;
    final localPeerId = _playbackLocalPeerId;
    if (current == null ||
        localPeerId.isEmpty ||
        event.claim.sessionId != _playbackSessionId ||
        event.claim.peerId != _playbackSourcePeerId ||
        current.sourcePeerId != event.claim.peerId ||
        current.sinks[localPeerId]?.sessionId != event.claim.sessionId) {
      return;
    }
    _failPlaybackAsSink(AudioFailureReason.transport);
  }

  void _failPlaybackAsSink(AudioFailureReason failureReason) {
    final current = _session;
    final localPeerId = _playbackLocalPeerId;
    if (current == null ||
        localPeerId.isEmpty ||
        _playbackSessionId.isEmpty ||
        current.sinks[localPeerId]?.sessionId != _playbackSessionId) {
      return;
    }
    final rejoinContext = _resolveSinkControlContext();
    final stoppingPlayback = _stopPlaybackOnly();
    _playbackSendControl = null;
    _playbackLocalPeerId = '';
    _sinkRejoinContext = rejoinContext;
    if (failureReason == AudioFailureReason.transport &&
        rejoinContext != null &&
        _autoRejoinAttempts < _maxAutoRejoinAttempts) {
      _autoRejoinSourcePeerId = rejoinContext.sourcePeerId;
    }
    _setSession(
      current.markSink(
        localPeerId,
        state: AudioGroupSinkState.failed,
        lastError: failureReason.name,
      ),
    );
    unawaited(stoppingPlayback.catchError((Object _) {}));
  }

  void _setSession(AudioGroupSession? session) {
    _session = session;
    notifyListeners();
    _checkHealth();
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _healthTimer = null;
    for (final timer in _offerTimers.values) {
      timer.cancel();
    }
    _offerTimers.clear();
    _captureRetry?.cancel();
    _removeChannelLifecycleListener?.call();
    _removeChannelLifecycleListener = null;
    super.dispose();
  }

  Uri _audioUri({
    required String host,
    required int port,
    required String path,
    required String sessionId,
    required String transportToken,
  }) {
    final normalizedPath = path.isEmpty ? '/audio' : path;
    return buildPeerPacketUri(
      host: host,
      port: port,
      path: normalizedPath,
      queryParameters: <String, String>{
        if (transportToken.isNotEmpty) 'session': sessionId,
        if (transportToken.isNotEmpty) 'token': transportToken,
      },
    );
  }

  /// Takes effect on the next audio written, while this device is playing.
  void updatePlaybackGain(double gain) {
    _playbackGain = _normalizePlaybackGain(gain);
    _playback?.updateGain(_playbackGain);
  }

  double _normalizePlaybackGain(double gain) {
    if (!gain.isFinite) {
      return 1.0;
    }
    return gain.clamp(1.0, 3.0).toDouble();
  }
}

class _SinkRejoinContext {
  const _SinkRejoinContext({
    required this.groupId,
    required this.streamId,
    required this.sessionId,
    required this.sourcePeerId,
    required this.localPeerId,
    required this.channelRole,
    required this.targetLatencyMs,
    required this.sendControl,
  });

  final String groupId;
  final String streamId;
  final String sessionId;
  final String sourcePeerId;
  final String localPeerId;
  final AudioChannelRole channelRole;
  final int targetLatencyMs;
  final AudioGroupControlSender sendControl;
}

int _wallClockMicros() => DateTime.now().microsecondsSinceEpoch;

Future<AudioCodec> createDefaultAudioGroupCodec(
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
