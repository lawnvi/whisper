import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:whisper/audio/audio_capture_source.dart';
import 'package:whisper/audio/audio_codec.dart';
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
            playbackGainProvider ?? LocalSetting().audioSharePlaybackGain;

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

  AudioShareRuntimeState _state = const AudioShareRuntimeState.idle();
  AudioCaptureSource? _captureSource;
  AudioPlaybackSink? _playbackSink;
  AudioPacketTransport? _transport;

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
          await stopLocal();
          _setState(
            AudioShareRuntimeState(
              status: AudioShareRuntimeStatus.failed,
              role: AudioShareRuntimeRole.none,
              sessionId: message.sessionId,
              peerId: _state.peerId,
              errorMessage: message.errorMessage,
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
    _manager.stopSession(_state.sessionId);
    _setState(const AudioShareRuntimeState.idle());
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
          errorMessage: 'Another audio session is already active',
        ),
      );
      return;
    }

    final accept = _manager.acceptOffer(offer);
    if (accept.action == AudioControlAction.error) {
      sendControl(accept);
      return;
    }

    try {
      await _startPlayback(accept);
      sendControl(accept);
    } catch (error) {
      final failedPeerId = offer.sourcePeerId;
      await stopLocal();
      _setState(
        AudioShareRuntimeState(
          status: AudioShareRuntimeStatus.failed,
          role: AudioShareRuntimeRole.sink,
          sessionId: offer.sessionId,
          peerId: failedPeerId,
          errorMessage: _friendlyErrorMessage(error),
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
      await _startCapture(
        accept,
        remoteHost: remoteHost,
        remotePort: remotePort,
        mediaSendKey: mediaSendKey,
      );
    } catch (error) {
      final failedPeerId = accept.sinkPeerId;
      await stopLocal();
      _setState(
        AudioShareRuntimeState(
          status: AudioShareRuntimeStatus.failed,
          role: AudioShareRuntimeRole.source,
          sessionId: accept.sessionId,
          peerId: failedPeerId,
          errorMessage: _friendlyErrorMessage(error),
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

  Future<void> _startPlayback(AudioControlMessage message) async {
    final format = message.format;
    if (format == null) {
      return;
    }
    await stopLocal();
    _setState(
      AudioShareRuntimeState(
        status: AudioShareRuntimeStatus.connecting,
        role: AudioShareRuntimeRole.sink,
        sessionId: message.sessionId,
        peerId: message.sourcePeerId,
      ),
    );
    final codec = await _codecFactory(format);
    final playbackGain = await _playbackGainProvider();
    final sink = AudioPlaybackSink(
      codec: codec,
      platform: _platform,
      playbackGain: playbackGain,
    );
    await sink.start(
      sessionId: message.sessionId,
      format: format,
    );
    _playbackSink = sink;
    _manager.onPacket = (packet) {
      unawaited(_playbackSink?.handlePacket(packet));
    };
    _setState(
      AudioShareRuntimeState(
        status: AudioShareRuntimeStatus.active,
        role: AudioShareRuntimeRole.sink,
        sessionId: message.sessionId,
        peerId: message.sourcePeerId,
      ),
    );
  }

  Future<void> _startCapture(
    AudioControlMessage message, {
    required String remoteHost,
    required int remotePort,
    Uint8List? mediaSendKey,
  }) async {
    final format = message.format;
    if (format == null) {
      return;
    }
    _setState(
      AudioShareRuntimeState(
        status: AudioShareRuntimeStatus.connecting,
        role: AudioShareRuntimeRole.source,
        sessionId: message.sessionId,
        peerId: message.sinkPeerId,
      ),
    );
    final codec = await _codecFactory(format);
    final uri = _audioUri(
      host: remoteHost,
      port: remotePort,
      path: message.path,
      sessionId: message.sessionId,
      transportToken: message.transportToken,
    );
    final transportFactory = _transportFactory;
    final AudioPacketTransport transport;
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
    final captureSource = AudioCaptureSource(
      codec: codec,
      platform: _platform,
      onPacket: transport.send,
    );
    _transport = transport;
    _captureSource = captureSource;
    await captureSource.start(
      sessionId: message.sessionId,
      format: format,
    );
    _setState(
      AudioShareRuntimeState(
        status: AudioShareRuntimeStatus.active,
        role: AudioShareRuntimeRole.source,
        sessionId: message.sessionId,
        peerId: message.sinkPeerId,
      ),
    );
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

Future<AudioCodec> createDefaultAudioCodec(AudioStreamFormat format) async {
  final config = AudioCodecConfig.fromStreamFormat(format);
  switch (format.codec) {
    case AudioCodecKind.opus:
      return OpusAudioCodec.create(config);
    case AudioCodecKind.pcmS16le:
      return PcmPassthroughAudioCodec(config);
  }
}
