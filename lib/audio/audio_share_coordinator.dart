import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:whisper/audio/audio_capture_source.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_failure_reason.dart';
import 'package:whisper/audio/audio_packet_transport.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_playback_sink.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

typedef AudioControlSender = void Function(AudioControlMessage control);
typedef AudioCodecFactory = Future<AudioCodec> Function(
  AudioStreamFormat format,
);
typedef AudioTransportFactory = Future<AudioPacketTransport> Function(Uri uri);
typedef AudioPlaybackGainProvider = Future<double> Function();

enum AudioShareRuntimeRole {
  none,
  source,
  sink,
}

enum AudioShareRuntimeStatus {
  idle,
  offering,
  connecting,
  active,
  failed,
}

class AudioShareRuntimeState {
  const AudioShareRuntimeState({
    required this.status,
    required this.role,
    this.sessionId = '',
    this.peerId = '',
    this.errorMessage = '',
  });

  const AudioShareRuntimeState.idle()
      : status = AudioShareRuntimeStatus.idle,
        role = AudioShareRuntimeRole.none,
        sessionId = '',
        peerId = '',
        errorMessage = '';

  final AudioShareRuntimeStatus status;
  final AudioShareRuntimeRole role;
  final String sessionId;
  final String peerId;
  final String errorMessage;

  bool get isActive => status == AudioShareRuntimeStatus.active;
  bool get isBusy =>
      status == AudioShareRuntimeStatus.offering ||
      status == AudioShareRuntimeStatus.connecting;

  bool isForPeer(String peerId) {
    return this.peerId == peerId && status != AudioShareRuntimeStatus.idle;
  }
}

class AudioShareCoordinator extends ChangeNotifier {
  AudioShareCoordinator({
    AudioShareManager? manager,
    AudioPlatform? platform,
    AudioCodecFactory? codecFactory,
    AudioTransportFactory? transportFactory,
    AudioPlaybackGainProvider? playbackGainProvider,
  })  : _manager = manager ?? AudioShareManager.shared,
        _platform = platform ?? AudioPlatform(),
        _codecFactory = codecFactory ?? createDefaultAudioCodec,
        _transportFactory = transportFactory,
        _playbackGainProvider =
            playbackGainProvider ?? LocalSetting().audioSharePlaybackGain {
    _removeChannelLifecycleListener =
        _manager.addChannelLifecycleListener(_handleMediaChannelClosed);
  }

  static final AudioShareCoordinator shared = AudioShareCoordinator(
    platform: AudioPlatform.shared,
  );

  static const AudioStreamFormat defaultFormat = AudioStreamFormat(
    codec: AudioCodecKind.opus,
    sampleRate: 48000,
    channels: 2,
    frameDurationMs: 20,
    bitRate: 128000,
  );

  final AudioShareManager _manager;
  final AudioPlatform _platform;
  final AudioCodecFactory _codecFactory;
  final AudioTransportFactory? _transportFactory;
  final AudioPlaybackGainProvider _playbackGainProvider;
  late final VoidCallback _removeChannelLifecycleListener;

  AudioShareRuntimeState _state = const AudioShareRuntimeState.idle();
  AudioCaptureSource? _captureSource;
  AudioPlaybackSink? _playbackSink;
  AudioPacketTransport? _transport;
  Future<bool>? _captureStartFuture;
  String _captureStartSessionId = '';
  Future<void>? _terminalCleanupFuture;
  int _lifecycleGeneration = 0;

  AudioShareRuntimeState get state => _state;

  bool get _hasLiveSession =>
      _state.status != AudioShareRuntimeStatus.idle &&
      _state.status != AudioShareRuntimeStatus.failed;

  Future<void> startSharingToConnectedPeer({
    required String sourcePeerId,
    required String sinkPeerId,
    required String sinkHost,
    required int sinkPort,
    required AudioControlSender sendControl,
    AudioStreamFormat format = defaultFormat,
  }) async {
    await _waitForTerminalCleanup();
    if (_hasLiveSession) {
      throw StateError('An audio session is already active');
    }
    final offer = _manager.createOffer(
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      format: format,
    );
    _setState(
      AudioShareRuntimeState(
        status: AudioShareRuntimeStatus.offering,
        role: AudioShareRuntimeRole.source,
        sessionId: offer.sessionId,
        peerId: sinkPeerId,
      ),
    );
    sendControl(offer);
  }

  Future<void> handleControlMessage(
    AudioControlMessage message, {
    required String localPeerId,
    required String remoteHost,
    required int remotePort,
    required AudioControlSender sendControl,
    Uint8List? mediaSendKey,
  }) async {
    switch (message.action) {
      case AudioControlAction.offer:
        await _handleOffer(
          message,
          localPeerId: localPeerId,
          sendControl: sendControl,
        );
        break;
      case AudioControlAction.accept:
        await _handleAccept(
          message,
          localPeerId: localPeerId,
          remoteHost: remoteHost,
          remotePort: remotePort,
          sendControl: sendControl,
          mediaSendKey: mediaSendKey,
        );
        break;
      case AudioControlAction.stop:
      case AudioControlAction.reject:
        _manager.handleControlMessage(message);
        if (_state.sessionId == message.sessionId) {
          await stopLocal();
        }
        break;
      case AudioControlAction.error:
        _manager.handleControlMessage(message);
        if (_state.sessionId == message.sessionId) {
          final current = _state;
          final generation = _lifecycleGeneration;
          final failureReason =
              audioFailureReasonFromWire(message.errorMessage);
          await stopLocal();
          if (_lifecycleGeneration != generation + 1) {
            break;
          }
          _setState(
            AudioShareRuntimeState(
              status: AudioShareRuntimeStatus.failed,
              role: AudioShareRuntimeRole.none,
              sessionId: message.sessionId,
              peerId: current.peerId,
              errorMessage: failureReason.name,
            ),
          );
        }
        break;
    }
  }

  Future<void> stopSharing({
    required AudioControlSender sendControl,
  }) async {
    final current = _state;
    if (current.status == AudioShareRuntimeStatus.idle ||
        current.sessionId.isEmpty) {
      return;
    }
    final session = _manager.session(current.sessionId);
    if (session != null) {
      sendControl(
        AudioControlMessage(
          action: AudioControlAction.stop,
          sessionId: session.sessionId,
          sourcePeerId: session.sourcePeerId,
          sinkPeerId: session.sinkPeerId,
        ),
      );
    }
    await stopLocal();
  }

  void updatePlaybackGain(double gain) {
    _playbackSink?.updatePlaybackGain(gain);
  }

  Future<void> stopLocal() async {
    final generation = ++_lifecycleGeneration;
    final sessionId = _state.sessionId;
    final captureSource = _captureSource;
    final playbackSink = _playbackSink;
    final transport = _transport;
    _captureSource = null;
    _playbackSink = null;
    _transport = null;
    if (_manager.onPacket != null) {
      _manager.onPacket = null;
    }
    await captureSource?.stop();
    await playbackSink?.stop();
    await transport?.close();
    _manager.stopSession(sessionId);
    if (generation == _lifecycleGeneration) {
      _setState(const AudioShareRuntimeState.idle());
    }
  }

  Future<void> _handleOffer(
    AudioControlMessage offer, {
    required String localPeerId,
    required AudioControlSender sendControl,
  }) async {
    if (offer.sinkPeerId != localPeerId) {
      _manager.handleControlMessage(offer);
      return;
    }
    if (_hasLiveSession && _state.sessionId != offer.sessionId) {
      sendControl(
        AudioControlMessage(
          action: AudioControlAction.reject,
          sessionId: offer.sessionId,
          sourcePeerId: offer.sourcePeerId,
          sinkPeerId: offer.sinkPeerId,
          errorMessage: AudioFailureReason.busy.name,
        ),
      );
      return;
    }

    final accept = _manager.acceptOffer(offer);
    if (accept.action == AudioControlAction.error) {
      sendControl(
        AudioControlMessage(
          action: AudioControlAction.error,
          sessionId: accept.sessionId,
          sourcePeerId: accept.sourcePeerId,
          sinkPeerId: accept.sinkPeerId,
          errorMessage: AudioFailureReason.protocol.name,
        ),
      );
      return;
    }

    try {
      if (!await _startPlayback(accept)) {
        return;
      }
      sendControl(accept);
    } catch (error) {
      if (_state.sessionId != offer.sessionId ||
          _state.role != AudioShareRuntimeRole.sink) {
        return;
      }
      final generation = _lifecycleGeneration;
      final failedPeerId = offer.sourcePeerId;
      final failureReason = audioFailureReasonFor(
        error,
        context: AudioFailureContext.playback,
      );
      await stopLocal();
      if (_lifecycleGeneration != generation + 1) {
        return;
      }
      _manager.failSession(offer.sessionId);
      _setState(
        AudioShareRuntimeState(
          status: AudioShareRuntimeStatus.failed,
          role: AudioShareRuntimeRole.sink,
          sessionId: offer.sessionId,
          peerId: failedPeerId,
          errorMessage: failureReason.name,
        ),
      );
      sendControl(
        AudioControlMessage(
          action: AudioControlAction.error,
          sessionId: offer.sessionId,
          sourcePeerId: offer.sourcePeerId,
          sinkPeerId: offer.sinkPeerId,
          errorMessage: _state.errorMessage,
        ),
      );
    }
  }

  Future<void> _handleAccept(
    AudioControlMessage accept, {
    required String localPeerId,
    required String remoteHost,
    required int remotePort,
    required AudioControlSender sendControl,
    Uint8List? mediaSendKey,
  }) async {
    _manager.handleControlMessage(accept);
    if (accept.sourcePeerId != localPeerId) {
      return;
    }
    if (_hasLiveSession && _state.sessionId != accept.sessionId) {
      return;
    }
    try {
      if (!await _startCapture(
        accept,
        remoteHost: remoteHost,
        remotePort: remotePort,
        mediaSendKey: mediaSendKey,
      )) {
        return;
      }
    } catch (error) {
      if (_state.sessionId != accept.sessionId ||
          _state.role != AudioShareRuntimeRole.source) {
        return;
      }
      final generation = _lifecycleGeneration;
      final failedPeerId = accept.sinkPeerId;
      final failureReason = audioFailureReasonFor(
        error,
        context: AudioFailureContext.capture,
      );
      await stopLocal();
      if (_lifecycleGeneration != generation + 1) {
        return;
      }
      _manager.failSession(accept.sessionId);
      _setState(
        AudioShareRuntimeState(
          status: AudioShareRuntimeStatus.failed,
          role: AudioShareRuntimeRole.source,
          sessionId: accept.sessionId,
          peerId: failedPeerId,
          errorMessage: failureReason.name,
        ),
      );
      sendControl(
        AudioControlMessage(
          action: AudioControlAction.error,
          sessionId: accept.sessionId,
          sourcePeerId: accept.sourcePeerId,
          sinkPeerId: accept.sinkPeerId,
          errorMessage: _state.errorMessage,
        ),
      );
    }
  }

  Future<bool> _startPlayback(AudioControlMessage message) async {
    final format = message.format;
    if (format == null) {
      return false;
    }
    await _waitForTerminalCleanup();
    if (_hasLiveSession && _state.sessionId != message.sessionId) {
      return false;
    }
    final priorGeneration = _lifecycleGeneration;
    await stopLocal();
    if (_lifecycleGeneration != priorGeneration + 1) {
      return false;
    }
    final generation = ++_lifecycleGeneration;
    _setState(
      AudioShareRuntimeState(
        status: AudioShareRuntimeStatus.connecting,
        role: AudioShareRuntimeRole.sink,
        sessionId: message.sessionId,
        peerId: message.sourcePeerId,
      ),
    );
    final AudioCodec codec;
    try {
      codec = await _codecFactory(format);
    } catch (_) {
      if (generation != _lifecycleGeneration) {
        return false;
      }
      rethrow;
    }
    if (generation != _lifecycleGeneration) {
      codec.dispose();
      return false;
    }
    final double playbackGain;
    try {
      playbackGain = await _playbackGainProvider();
    } catch (_) {
      codec.dispose();
      if (generation != _lifecycleGeneration) {
        return false;
      }
      rethrow;
    }
    if (generation != _lifecycleGeneration) {
      codec.dispose();
      return false;
    }
    final sink = AudioPlaybackSink(
      codec: codec,
      platform: _platform,
      playbackGain: playbackGain,
      onWriteFailure: (error, _) {
        _beginUnexpectedFailure(
          generation: generation,
          sessionId: message.sessionId,
          peerId: message.sourcePeerId,
          role: AudioShareRuntimeRole.sink,
          failureReason: audioFailureReasonFor(
            error,
            context: AudioFailureContext.playback,
          ),
        );
      },
    );
    _playbackSink = sink;
    try {
      await sink.start(
        sessionId: message.sessionId,
        format: format,
      );
    } catch (_) {
      if (generation != _lifecycleGeneration ||
          !identical(_playbackSink, sink)) {
        return false;
      }
      rethrow;
    }
    if (generation != _lifecycleGeneration || !identical(_playbackSink, sink)) {
      return false;
    }
    _manager.onPacket = (packet) {
      if (identical(_playbackSink, sink)) {
        sink.enqueuePacket(packet);
      }
    };
    _setState(
      AudioShareRuntimeState(
        status: AudioShareRuntimeStatus.active,
        role: AudioShareRuntimeRole.sink,
        sessionId: message.sessionId,
        peerId: message.sourcePeerId,
      ),
    );
    return true;
  }

  Future<bool> _startCapture(
    AudioControlMessage message, {
    required String remoteHost,
    required int remotePort,
    Uint8List? mediaSendKey,
  }) {
    if (_state.status == AudioShareRuntimeStatus.active &&
        _state.role == AudioShareRuntimeRole.source &&
        _state.sessionId == message.sessionId &&
        _captureSource != null &&
        _transport != null) {
      return Future<bool>.value(true);
    }
    final existing = _captureStartFuture;
    if (existing != null) {
      if (_captureStartSessionId == message.sessionId) {
        return existing;
      }
      return existing.then(
        (_) => _startCapture(
          message,
          remoteHost: remoteHost,
          remotePort: remotePort,
          mediaSendKey: mediaSendKey,
        ),
        onError: (Object _, StackTrace __) => _startCapture(
          message,
          remoteHost: remoteHost,
          remotePort: remotePort,
          mediaSendKey: mediaSendKey,
        ),
      );
    }
    late final Future<bool> running;
    running = _startCaptureOperation(
      message,
      remoteHost: remoteHost,
      remotePort: remotePort,
      mediaSendKey: mediaSendKey,
    ).whenComplete(() {
      if (identical(_captureStartFuture, running)) {
        _captureStartFuture = null;
        _captureStartSessionId = '';
      }
    });
    _captureStartFuture = running;
    _captureStartSessionId = message.sessionId;
    return running;
  }

  Future<bool> _startCaptureOperation(
    AudioControlMessage message, {
    required String remoteHost,
    required int remotePort,
    Uint8List? mediaSendKey,
  }) async {
    final format = message.format;
    if (format == null) {
      return false;
    }
    await _waitForTerminalCleanup();
    if (_state.sessionId != message.sessionId ||
        _state.role != AudioShareRuntimeRole.source) {
      return false;
    }
    final generation = ++_lifecycleGeneration;
    _setState(
      AudioShareRuntimeState(
        status: AudioShareRuntimeStatus.connecting,
        role: AudioShareRuntimeRole.source,
        sessionId: message.sessionId,
        peerId: message.sinkPeerId,
      ),
    );
    final AudioCodec codec;
    try {
      codec = await _codecFactory(format);
    } catch (_) {
      if (generation != _lifecycleGeneration) {
        return false;
      }
      rethrow;
    }
    if (generation != _lifecycleGeneration) {
      codec.dispose();
      return false;
    }
    final uri = _audioUri(
      host: remoteHost,
      port: remotePort,
      path: message.path,
      sessionId: message.sessionId,
      transportToken: message.transportToken,
    );
    final transportFactory = _transportFactory;
    final AudioPacketTransport transport;
    try {
      if (transportFactory != null) {
        transport = await transportFactory(uri);
      } else {
        if (message.transportToken.isEmpty || mediaSendKey == null) {
          throw StateError('authenticated audio transport context missing');
        }
        transport = await AudioWebSocketPacketTransport.connect(
          uri,
          mediaMacKey: mediaSendKey,
          sessionId: message.sessionId,
        );
      }
    } catch (_) {
      codec.dispose();
      if (generation != _lifecycleGeneration) {
        return false;
      }
      rethrow;
    }
    if (generation != _lifecycleGeneration) {
      codec.dispose();
      await transport.close();
      return false;
    }
    final captureSource = AudioCaptureSource(
      codec: codec,
      platform: _platform,
      onPacket: transport.send,
    );
    _transport = transport;
    _captureSource = captureSource;
    try {
      await captureSource.start(
        sessionId: message.sessionId,
        format: format,
      );
    } catch (_) {
      if (generation != _lifecycleGeneration ||
          !identical(_captureSource, captureSource) ||
          !identical(_transport, transport)) {
        if (identical(_captureSource, captureSource) &&
            identical(_transport, transport)) {
          _captureSource = null;
          _transport = null;
          await _ignoreCleanupError(captureSource.stop());
          await _ignoreCleanupError(transport.close());
        }
        return false;
      }
      rethrow;
    }
    if (generation != _lifecycleGeneration ||
        !identical(_captureSource, captureSource) ||
        !identical(_transport, transport)) {
      if (identical(_captureSource, captureSource) &&
          identical(_transport, transport)) {
        _captureSource = null;
        _transport = null;
        await _ignoreCleanupError(captureSource.stop());
        await _ignoreCleanupError(transport.close());
      }
      return false;
    }
    _observeTransport(
      transport,
      generation: generation,
      sessionId: message.sessionId,
      peerId: message.sinkPeerId,
    );
    _setState(
      AudioShareRuntimeState(
        status: AudioShareRuntimeStatus.active,
        role: AudioShareRuntimeRole.source,
        sessionId: message.sessionId,
        peerId: message.sinkPeerId,
      ),
    );
    return true;
  }

  void _observeTransport(
    AudioPacketTransport transport, {
    required int generation,
    required String sessionId,
    required String peerId,
  }) {
    if (transport is! AudioObservablePacketTransport) {
      return;
    }
    unawaited(transport.done.then((termination) {
      if (!termination.isUnexpected) {
        return;
      }
      _beginUnexpectedFailure(
        generation: generation,
        sessionId: sessionId,
        peerId: peerId,
        role: AudioShareRuntimeRole.source,
        expectedTransport: transport,
      );
    }));
  }

  void _handleMediaChannelClosed(AudioMediaChannelClosedEvent event) {
    if (event.expected || event.claim.namespace != 'audio') {
      return;
    }
    final current = _state;
    if (current.role != AudioShareRuntimeRole.sink ||
        _playbackSink == null ||
        current.sessionId != event.claim.sessionId ||
        current.peerId != event.claim.peerId) {
      return;
    }
    _beginUnexpectedFailure(
      generation: _lifecycleGeneration,
      sessionId: current.sessionId,
      peerId: current.peerId,
      role: AudioShareRuntimeRole.sink,
    );
  }

  void _beginUnexpectedFailure({
    required int generation,
    required String sessionId,
    required String peerId,
    required AudioShareRuntimeRole role,
    AudioPacketTransport? expectedTransport,
    AudioFailureReason failureReason = AudioFailureReason.transport,
  }) {
    if (generation != _lifecycleGeneration ||
        _state.sessionId != sessionId ||
        _state.role != role ||
        _state.status == AudioShareRuntimeStatus.idle ||
        _state.status == AudioShareRuntimeStatus.failed ||
        (expectedTransport != null &&
            !identical(_transport, expectedTransport))) {
      return;
    }
    _lifecycleGeneration += 1;
    final captureSource = _captureSource;
    final playbackSink = _playbackSink;
    final transport = _transport;
    _captureSource = null;
    _playbackSink = null;
    _transport = null;
    _manager.onPacket = null;
    _manager.failSession(sessionId);
    _setState(
      AudioShareRuntimeState(
        status: AudioShareRuntimeStatus.failed,
        role: role,
        sessionId: sessionId,
        peerId: peerId,
        errorMessage: failureReason.name,
      ),
    );
    late final Future<void> cleanup;
    cleanup = _finishUnexpectedFailure(
      captureSource: captureSource,
      playbackSink: playbackSink,
      transport: transport,
    ).whenComplete(() {
      if (identical(_terminalCleanupFuture, cleanup)) {
        _terminalCleanupFuture = null;
      }
    });
    _terminalCleanupFuture = cleanup;
    unawaited(cleanup);
  }

  Future<void> _finishUnexpectedFailure({
    required AudioCaptureSource? captureSource,
    required AudioPlaybackSink? playbackSink,
    required AudioPacketTransport? transport,
  }) async {
    await _ignoreCleanupError(captureSource?.stop());
    await _ignoreCleanupError(playbackSink?.stop());
    await _ignoreCleanupError(transport?.close());
  }

  Future<void> _ignoreCleanupError(Future<void>? operation) async {
    try {
      await operation;
    } catch (_) {}
  }

  Future<void> _waitForTerminalCleanup() async {
    final cleanup = _terminalCleanupFuture;
    if (cleanup == null) {
      return;
    }
    try {
      await cleanup;
    } catch (_) {}
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

  void _setState(AudioShareRuntimeState state) {
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _removeChannelLifecycleListener();
    super.dispose();
  }
}

Future<AudioCodec> createDefaultAudioCodec(AudioStreamFormat format) async {
  final config = AudioCodecConfig.fromStreamFormat(format);
  switch (format.codec) {
    case AudioCodecKind.opus:
      return OpusAudioCodec.create(config);
    case AudioCodecKind.pcmS16le:
      return PcmPassthroughAudioCodec(config);
  }
}
