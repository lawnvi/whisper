import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:sodium/sodium.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_capture_source.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_failure_reason.dart';
import 'package:whisper/audio/audio_fanout_transport.dart';
import 'package:whisper/audio/audio_group_media.dart';
import 'package:whisper/audio/audio_group_playback_scheduler.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_diagnostics.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/socket/aead_engine.dart';
import 'package:whisper/socket/bounded_binary_websocket_session.dart';
import 'package:whisper/socket/media_upgrade_proof.dart';
import 'package:whisper/socket/no_delay_socket.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';

/// The sound's data on its own isolate, so it keeps going while the main
/// thread is stopped (on macOS, for half a second whenever a window is
/// minimized or restored). Sessions and control stay with the coordinator.
///
/// Falls back to [LocalAudioGroupMedia] when the native side has no direct
/// entry points or the isolate can't start.
class DesktopAudioGroupMedia implements AudioGroupMedia {
  DesktopAudioGroupMedia({
    required AudioPlatform platform,
    required AudioShareManager manager,
    required LocalAudioGroupMedia fallback,
  }) : _platform = platform,
       _manager = manager,
       _fallback = fallback;

  final AudioPlatform _platform;
  final AudioShareManager _manager;
  final LocalAudioGroupMedia _fallback;
  Future<_IsolateClient?>? _clientFuture;
  _IsolateClient? _client;
  AudioGroupSinkFailure? _onSinkFailure;

  @override
  AudioGroupSinkFailure? get onSinkFailure => _onSinkFailure;

  @override
  set onSinkFailure(AudioGroupSinkFailure? value) {
    _onSinkFailure = value;
    _fallback.onSinkFailure = value;
  }

  Future<_IsolateClient?> _isolate() => _clientFuture ??= _spawn();

  Future<_IsolateClient?> _spawn() async {
    try {
      final entry = await _platform.nativeEntryPoints();
      if (entry == null) {
        return null;
      }
      // Unpacks libopus where the isolate opens it (Windows, Linux).
      await OpusAudioCodec.warmUp();
      final client = await _IsolateClient.spawn(entry, this);
      _client = client;
      _manager.remoteChannels = client;
      return client;
    } catch (_) {
      // Played and captured as before, on this isolate.
      return null;
    }
  }

  @override
  Future<AudioGroupSinkLink> connectSink(AudioGroupSinkDial dial) async {
    final client = await _isolate();
    if (client == null) {
      return _fallback.connectSink(dial);
    }
    final linkId = await client.request<int>(
      (id) => _ConnectSink(
        id,
        sourcePeerId: dial.sourcePeerId,
        sessionId: dial.sessionId,
        uri: dial.uri,
        mediaUri: dial.mediaUri,
        transportToken: dial.transportToken,
        mediaSendKey: dial.mediaSendKey,
      ),
    );
    return _IsolateSinkLink(client, linkId);
  }

  @override
  void attachSink(String sinkPeerId, AudioGroupSinkLink link) {
    if (link is _IsolateSinkLink) {
      link.client.send(_AttachSink(sinkPeerId, link.linkId));
      return;
    }
    _fallback.attachSink(sinkPeerId, link);
  }

  @override
  Future<void> closeLink(AudioGroupSinkLink link) {
    if (link is _IsolateSinkLink) {
      return link.client.request<void>((id) => _CloseLink(id, link.linkId));
    }
    return _fallback.closeLink(link);
  }

  @override
  Future<void> disconnectSink(String sinkPeerId) async {
    await _fallback.disconnectSink(sinkPeerId);
    await _client?.request<void>((id) => _DisconnectSink(id, sinkPeerId));
  }

  @override
  Future<void> disconnectAllSinks() async {
    await _fallback.disconnectAllSinks();
    await _client?.request<void>(_DisconnectAll.new);
  }

  @override
  AudioGroupCapture capture(
    AudioGroupCaptureSpec spec, {
    required void Function(Object error) onError,
    bool Function()? shouldStart,
  }) {
    return _DesktopCapture(this, spec, onError, shouldStart);
  }

  @override
  Future<AudioGroupPlayback> startPlayback(
    AudioGroupPlaybackSpec spec, {
    required AudioGroupPlaybackReportSink onReport,
    required void Function(Object error) onFailure,
    bool Function()? shouldStart,
  }) async {
    final client = await _isolate();
    if (client == null) {
      return _fallback.startPlayback(
        spec,
        onReport: onReport,
        onFailure: onFailure,
        shouldStart: shouldStart,
      );
    }
    if (shouldStart?.call() == false) {
      throw const AudioGroupStartCancelled();
    }
    final handle = await _platform.startPlayback(
      sessionId: spec.streamId,
      format: spec.format,
    );
    if (handle == 0) {
      // This native side can't take direct writes for it.
      await _platform.stopPlayback(sessionId: spec.streamId);
      return _fallback.startPlayback(
        spec,
        onReport: onReport,
        onFailure: onFailure,
        shouldStart: shouldStart,
      );
    }
    final playbackId = client.nextId();
    client.playbackListeners[playbackId] = _PlaybackListener(
      onReport: onReport,
      onFailure: onFailure,
    );
    try {
      final mediaPort = await client.request<int>(
        (id) => _StartPlayback(id, playbackId, spec, handle),
      );
      return _DesktopPlayback(this, client, playbackId, spec, mediaPort);
    } catch (_) {
      client.playbackListeners.remove(playbackId);
      await _platform.stopPlayback(sessionId: spec.streamId);
      rethrow;
    }
  }

  void _log(String line) => PrivacyLog.forward(line);
}

class _IsolateSinkLink implements AudioGroupSinkLink {
  _IsolateSinkLink(this.client, this.linkId);

  final _IsolateClient client;
  final int linkId;
}

class _DesktopCapture implements AudioGroupCapture {
  _DesktopCapture(this._media, this._spec, this._onError, this._shouldStart);

  final DesktopAudioGroupMedia _media;
  final AudioGroupCaptureSpec _spec;
  final void Function(Object error) _onError;
  final bool Function()? _shouldStart;
  AudioGroupCapture? _local;
  _IsolateClient? _client;
  int _captureId = 0;
  StreamSubscription<PlatformAudioError>? _errors;
  Future<void>? _nativeStart;
  bool _stopped = false;
  Future<void>? _stopFuture;
  int _lastSentAtMicros = 0;

  @override
  int get lastSentAtMicros => _local?.lastSentAtMicros ?? _lastSentAtMicros;

  @override
  Future<void> start() async {
    final client = await _media._isolate();
    if (_stopped) {
      return;
    }
    if (client == null) {
      final local = _local = _media._fallback.capture(
        _spec,
        onError: _onError,
        shouldStart: _shouldStart,
      );
      await local.start();
      return;
    }
    if (_shouldStart?.call() == false) {
      return;
    }
    _client = client;
    final captureId = _captureId = client.nextId();
    client.captureListeners[captureId] = (sentAtMicros) {
      _lastSentAtMicros = sentAtMicros;
    };
    await client.request<void>((id) => _PrepareCapture(id, captureId, _spec));
    if (_stopped) {
      return;
    }
    // Native capture errors still come through the MethodChannel.
    _errors = _media._platform.captureErrors.listen((error) {
      if (!_stopped && error.sessionId == _spec.streamId) {
        _onError(error);
      }
    });
    final starting = _nativeStart = _media._platform.startCapture(
      sessionId: _spec.streamId,
      format: _spec.format,
    );
    await starting;
  }

  @override
  Future<void> stop() => _stopFuture ??= _stop();

  Future<void> _stop() async {
    _stopped = true;
    final local = _local;
    if (local != null) {
      await local.stop();
      return;
    }
    await _errors?.cancel();
    _errors = null;
    Object? failure;
    StackTrace? failureStack;
    final starting = _nativeStart;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {
        // A partly started native capture still needs the stop below.
      }
      try {
        await _media._platform.stopCapture(sessionId: _spec.streamId);
      } catch (error, stackTrace) {
        failure = error;
        failureStack = stackTrace;
      }
    }
    final client = _client;
    if (client != null && _captureId != 0) {
      client.captureListeners.remove(_captureId);
      await client.request<void>((id) => _StopCapture(id, _captureId));
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
  }
}

class _DesktopPlayback implements AudioGroupPlayback {
  _DesktopPlayback(
    this._media,
    this._client,
    this._playbackId,
    this._spec,
    this.mediaPort,
  );

  final DesktopAudioGroupMedia _media;
  final _IsolateClient _client;
  final int _playbackId;
  final AudioGroupPlaybackSpec _spec;
  Future<void>? _stopFuture;

  @override
  final int mediaPort;

  @override
  void deliver(AudioGroupPacketFrame packet) {
    if (_stopFuture != null) {
      return;
    }
    _client.send(_DeliverPacket(_playbackId, packet.encode()));
  }

  @override
  void updateClockOffset(int clockOffsetMicros) {
    _client.send(_PlaybackClock(_playbackId, clockOffsetMicros));
  }

  @override
  void updateChannelRole(AudioChannelRole channelRole) {
    _client.send(_PlaybackRole(_playbackId, channelRole));
  }

  @override
  void updateGain(double gain) {
    _client.send(_PlaybackGain(_playbackId, gain));
  }

  @override
  Future<void> stop() => _stopFuture ??= _stop();

  Future<void> _stop() async {
    _client.playbackListeners.remove(_playbackId);
    // Writes stop before the native player does.
    await _client.request<void>((id) => _StopPlayback(id, _playbackId));
    await _media._platform.stopPlayback(sessionId: _spec.streamId);
  }
}

class _PlaybackListener {
  _PlaybackListener({required this.onReport, required this.onFailure});

  final AudioGroupPlaybackReportSink onReport;
  final void Function(Object error) onFailure;
}

class _PendingClaim {
  _PendingClaim(this.claim, this.sessionId, this.token, this.expires);

  final SessionUpgradeClaim claim;
  final String sessionId;
  final String token;
  final Timer expires;
}

/// The main isolate's side of the audio isolate.
class _IsolateClient implements AudioRemoteMediaChannels {
  _IsolateClient._(this._isolate, this._commands, this._receive, this._media);

  static Future<_IsolateClient> spawn(
    AudioNativeEntryPoints entry,
    DesktopAudioGroupMedia media,
  ) async {
    final receive = ReceivePort('audio');
    final ready = Completer<SendPort>();
    late final _IsolateClient client;
    receive.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      if (ready.isCompleted) {
        client._handle(message);
      }
    });
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _audioIsolateMain,
        _IsolateStart(receive.sendPort, entry),
        debugName: 'audio',
        errorsAreFatal: false,
      );
    } catch (_) {
      receive.close();
      rethrow;
    }
    final commands = await ready.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        isolate.kill(priority: Isolate.immediate);
        receive.close();
        throw TimeoutException('audio isolate did not start');
      },
    );
    client = _IsolateClient._(isolate, commands, receive, media);
    return client;
  }

  // ignore: unused_field
  final Isolate _isolate;
  final SendPort _commands;
  // ignore: unused_field
  final ReceivePort _receive;
  final DesktopAudioGroupMedia _media;
  final Map<int, Completer<Object?>> _requests = <int, Completer<Object?>>{};
  final Map<int, _PlaybackListener> playbackListeners =
      <int, _PlaybackListener>{};
  final Map<int, void Function(int sentAtMicros)> captureListeners =
      <int, void Function(int sentAtMicros)>{};
  final Map<int, _PendingClaim> _claims = <int, _PendingClaim>{};
  int _nextId = 0;

  int nextId() => ++_nextId;

  void send(Object command) => _commands.send(command);

  Future<T> request<T>(Object Function(int id) command) {
    final id = nextId();
    final completer = Completer<Object?>();
    _requests[id] = completer;
    _commands.send(command(id));
    return completer.future.then((value) => value as T);
  }

  @override
  Future<void> closeChannels({
    String? sessionId,
    String? peerId,
    String? namespace,
    Uint8List? keepMediaMacKey,
    bool expected = false,
  }) {
    return request<void>(
      (id) => _CloseChannels(
        id,
        sessionId: sessionId,
        peerId: peerId,
        namespace: namespace,
        keepMediaMacKey: keepMediaMacKey,
        expected: expected,
      ),
    );
  }

  void _handle(Object? message) {
    switch (message) {
      case _Reply():
        final completer = _requests.remove(message.id);
        if (completer == null) {
          return;
        }
        final reason = message.failure;
        if (reason != null) {
          completer.completeError(AudioFailureError(reason));
        } else {
          completer.complete(message.value);
        }
      case _SinkFailed():
        _media._onSinkFailure?.call(
          message.sinkPeerId,
          AudioFailureError(message.reason),
        );
      case _CaptureSent():
        captureListeners[message.captureId]?.call(message.sentAtMicros);
      case _PlaybackReported():
        playbackListeners[message.playbackId]?.onReport(message.report);
      case _PlaybackFailed():
        playbackListeners
            .remove(message.playbackId)
            ?.onFailure(AudioFailureError(message.reason));
      case _ClaimLookup():
        _lookupClaim(message);
      case _ClaimConsume():
        _consumeClaim(message.requestId);
      case _ClaimRelease():
        _claims.remove(message.requestId)?._release();
      case _Log():
        _media._log(message.line);
    }
  }

  void _lookupClaim(_ClaimLookup lookup) {
    final broker = _media._manager.claimBroker;
    final claim = broker?.lookup(
      sessionId: lookup.sessionId,
      token: lookup.token,
      remoteAddress: lookup.remoteAddress,
    );
    if (claim == null) {
      send(_ClaimAnswer(lookup.requestId, null));
      return;
    }
    // Released if the proof never comes.
    final expires = Timer(const Duration(seconds: 10), () {
      _claims.remove(lookup.requestId)?._release();
    });
    _claims[lookup.requestId] = _PendingClaim(
      claim,
      lookup.sessionId,
      lookup.token,
      expires,
    );
    send(
      _ClaimAnswer(
        lookup.requestId,
        claim.withMediaPacketContext(
          (mediaMacKey, channelBinding) => _ClaimData(
            namespace: claim.namespace,
            sessionId: claim.sessionId,
            peerId: claim.peerId,
            connectionGeneration: claim.connectionGeneration,
            mediaMacKey: Uint8List.fromList(mediaMacKey),
            channelBinding: Uint8List.fromList(channelBinding),
          ),
        ),
      ),
    );
  }

  void _consumeClaim(int requestId) {
    final pending = _claims.remove(requestId);
    if (pending == null) {
      send(_ConsumeAnswer(requestId, false));
      return;
    }
    final consumed = _media._manager.claimBroker?.consume(
      sessionId: pending.sessionId,
      token: pending.token,
      expected: pending.claim,
    );
    pending._release();
    consumed?.destroy();
    send(_ConsumeAnswer(requestId, consumed != null));
  }
}

extension on _PendingClaim {
  void _release() {
    expires.cancel();
    claim.destroy();
  }
}

// ---- Messages ----

class _IsolateStart {
  const _IsolateStart(this.main, this.entry);

  final SendPort main;
  final AudioNativeEntryPoints entry;
}

class _ConnectSink {
  const _ConnectSink(
    this.id, {
    required this.sourcePeerId,
    required this.sessionId,
    required this.uri,
    required this.mediaUri,
    required this.transportToken,
    required this.mediaSendKey,
  });

  final int id;
  final String sourcePeerId;
  final String sessionId;
  final Uri uri;
  final Uri? mediaUri;
  final String transportToken;
  final Uint8List? mediaSendKey;
}

class _AttachSink {
  const _AttachSink(this.sinkPeerId, this.linkId);

  final String sinkPeerId;
  final int linkId;
}

class _CloseLink {
  const _CloseLink(this.id, this.linkId);

  final int id;
  final int linkId;
}

class _DisconnectSink {
  const _DisconnectSink(this.id, this.sinkPeerId);

  final int id;
  final String sinkPeerId;
}

class _DisconnectAll {
  const _DisconnectAll(this.id);

  final int id;
}

class _PrepareCapture {
  const _PrepareCapture(this.id, this.captureId, this.spec);

  final int id;
  final int captureId;
  final AudioGroupCaptureSpec spec;
}

class _StopCapture {
  const _StopCapture(this.id, this.captureId);

  final int id;
  final int captureId;
}

class _StartPlayback {
  const _StartPlayback(this.id, this.playbackId, this.spec, this.handle);

  final int id;
  final int playbackId;
  final AudioGroupPlaybackSpec spec;
  final int handle;
}

class _DeliverPacket {
  const _DeliverPacket(this.playbackId, this.bytes);

  final int playbackId;
  final Uint8List bytes;
}

class _PlaybackClock {
  const _PlaybackClock(this.playbackId, this.clockOffsetMicros);

  final int playbackId;
  final int clockOffsetMicros;
}

class _PlaybackRole {
  const _PlaybackRole(this.playbackId, this.channelRole);

  final int playbackId;
  final AudioChannelRole channelRole;
}

class _PlaybackGain {
  const _PlaybackGain(this.playbackId, this.gain);

  final int playbackId;
  final double gain;
}

class _StopPlayback {
  const _StopPlayback(this.id, this.playbackId);

  final int id;
  final int playbackId;
}

class _CloseChannels {
  const _CloseChannels(
    this.id, {
    this.sessionId,
    this.peerId,
    this.namespace,
    this.keepMediaMacKey,
    required this.expected,
  });

  final int id;
  final String? sessionId;
  final String? peerId;
  final String? namespace;
  final Uint8List? keepMediaMacKey;
  final bool expected;
}

class _ClaimData {
  const _ClaimData({
    required this.namespace,
    required this.sessionId,
    required this.peerId,
    required this.connectionGeneration,
    required this.mediaMacKey,
    required this.channelBinding,
  });

  final String namespace;
  final String sessionId;
  final String peerId;
  final int connectionGeneration;
  final Uint8List mediaMacKey;
  final Uint8List channelBinding;
}

class _ClaimAnswer {
  const _ClaimAnswer(this.requestId, this.claim);

  final int requestId;
  final _ClaimData? claim;
}

class _ConsumeAnswer {
  const _ConsumeAnswer(this.requestId, this.consumed);

  final int requestId;
  final bool consumed;
}

class _Reply {
  const _Reply(this.id, {this.value, this.failure});

  final int id;
  final Object? value;
  final AudioFailureReason? failure;
}

class _SinkFailed {
  const _SinkFailed(this.sinkPeerId, this.reason);

  final String sinkPeerId;
  final AudioFailureReason reason;
}

/// A capture is sending: at most every [_IsolateCapture.sentReportMicros].
class _CaptureSent {
  const _CaptureSent(this.captureId, this.sentAtMicros);

  final int captureId;
  final int sentAtMicros;
}

class _PlaybackReported {
  const _PlaybackReported(this.playbackId, this.report);

  final int playbackId;
  final AudioGroupPlaybackReport report;
}

class _PlaybackFailed {
  const _PlaybackFailed(this.playbackId, this.reason);

  final int playbackId;
  final AudioFailureReason reason;
}

class _ClaimLookup {
  const _ClaimLookup(
    this.requestId,
    this.sessionId,
    this.token,
    this.remoteAddress,
  );

  final int requestId;
  final String sessionId;
  final String token;
  final String remoteAddress;
}

class _ClaimConsume {
  const _ClaimConsume(this.requestId);

  final int requestId;
}

class _ClaimRelease {
  const _ClaimRelease(this.requestId);

  final int requestId;
}

class _Log {
  const _Log(this.line);

  final String line;
}

// ---- The audio isolate ----

Future<void> _audioIsolateMain(_IsolateStart start) async {
  try {
    // AEAD acceleration is per isolate; without it the packets go through
    // the much slower pure-Dart cipher.
    WhisperAead.installNativeAcceleration(await SodiumInit.init());
  } catch (_) {
    // Pure-Dart fallback still works.
  }
  final runtime = _AudioRuntime(start.main, _NativeAudio(start.entry));
  final receive = ReceivePort();
  start.main.send(receive.sendPort);
  receive.listen(runtime.handle);
}

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

class _AudioRuntime {
  _AudioRuntime(this._main, this._native)
    : _diagnostics = AudioShareDiagnostics(
        sink: (line) => _main.send(_Log(line)),
      );

  final SendPort _main;
  final _NativeAudio _native;
  final AudioShareDiagnostics _diagnostics;
  final Map<int, AudioGroupPacketTransport> _links =
      <int, AudioGroupPacketTransport>{};
  late final AudioFanoutTransport _fanout = AudioFanoutTransport(
    onSinkFailure: (sinkPeerId, error) => _main.send(
      _SinkFailed(
        sinkPeerId,
        audioFailureReasonFor(error, context: AudioFailureContext.transport),
      ),
    ),
  );
  final Map<int, _IsolateCapture> _captures = <int, _IsolateCapture>{};
  int _activeCaptureId = 0;
  final Map<int, _IsolatePlayback> _playbacks = <int, _IsolatePlayback>{};
  _MediaServer? _server;
  Future<_MediaServer>? _serverStart;
  final Map<int, Completer<_ClaimData?>> _claimLookups =
      <int, Completer<_ClaimData?>>{};
  final Map<int, Completer<bool>> _claimConsumes = <int, Completer<bool>>{};
  int _nextLinkId = 0;
  int _nextClaimId = 0;

  void handle(Object? message) {
    switch (message) {
      case _ConnectSink():
        _reply(message.id, () => _connect(message));
      case _AttachSink():
        final transport = _links.remove(message.linkId);
        if (transport != null) {
          _fanout.attach(message.sinkPeerId, transport);
        }
      case _CloseLink():
        _reply(message.id, () async {
          await _links.remove(message.linkId)?.close();
          return null;
        });
      case _DisconnectSink():
        _reply(message.id, () async {
          await _fanout.detachAndClose(message.sinkPeerId);
          return null;
        });
      case _DisconnectAll():
        _reply(message.id, () async {
          await _fanout.closeAll();
          return null;
        });
      case _PrepareCapture():
        _reply(
          message.id,
          () => _prepareCapture(message),
          context: AudioFailureContext.capture,
        );
      case _StopCapture():
        _reply(message.id, () => _stopCapture(message.captureId));
      case _StartPlayback():
        _reply(
          message.id,
          () => _startPlayback(message),
          context: AudioFailureContext.playback,
        );
      case _DeliverPacket():
        final playback = _playbacks[message.playbackId];
        if (playback != null) {
          try {
            playback.pipeline.deliver(
              AudioGroupPacketFrame.decode(message.bytes),
            );
          } on FormatException {
            // Checked already on the main isolate; nothing to do.
          }
        }
      case _PlaybackClock():
        _playbacks[message.playbackId]?.pipeline.updateClockOffset(
          message.clockOffsetMicros,
        );
      case _PlaybackRole():
        _playbacks[message.playbackId]?.pipeline.updateChannelRole(
          message.channelRole,
        );
      case _PlaybackGain():
        _playbacks[message.playbackId]?.pipeline.updateGain(message.gain);
      case _StopPlayback():
        _reply(message.id, () async {
          await _playbacks.remove(message.playbackId)?.close(expected: true);
          return null;
        });
      case _CloseChannels():
        _reply(message.id, () async {
          await _closeChannels(message);
          return null;
        });
      case _ClaimAnswer():
        _claimLookups.remove(message.requestId)?.complete(message.claim);
      case _ConsumeAnswer():
        _claimConsumes.remove(message.requestId)?.complete(message.consumed);
    }
  }

  void _reply(
    int id,
    Future<Object?> Function() action, {
    AudioFailureContext context = AudioFailureContext.transport,
  }) {
    unawaited(
      action().then(
        (value) => _main.send(_Reply(id, value: value)),
        onError: (Object error) => _main.send(
          _Reply(id, failure: audioFailureReasonFor(error, context: context)),
        ),
      ),
    );
  }

  Future<Object?> _connect(_ConnectSink command) async {
    final transport = await connectAudioGroupSinkTransport(
      uri: command.uri,
      mediaUri: command.mediaUri,
      connect: (uri) {
        final mediaSendKey = command.mediaSendKey;
        if (command.transportToken.isEmpty || mediaSendKey == null) {
          throw StateError('authenticated audio group context missing');
        }
        return AudioGroupWebSocketPacketTransport.connect(
          uri,
          mediaMacKey: mediaSendKey,
          sessionId: command.sessionId,
          peerId: command.sourcePeerId,
        );
      },
    );
    final linkId = ++_nextLinkId;
    _links[linkId] = transport;
    return linkId;
  }

  Future<Object?> _prepareCapture(_PrepareCapture command) async {
    final previous = _captures[_activeCaptureId];
    if (previous != null) {
      await previous.stop(_native, clearCallback: false);
      _captures.remove(_activeCaptureId);
    }
    final capture = _IsolateCapture(
      command.spec,
      codec: _createCodec(command.spec.format),
      diagnostics: _diagnostics,
      send: _fanout.send,
      onSent: (sentAtMicros) =>
          _main.send(_CaptureSent(command.captureId, sentAtMicros)),
    );
    _captures[command.captureId] = capture;
    _activeCaptureId = command.captureId;
    await capture.start(_native);
    return null;
  }

  Future<Object?> _stopCapture(int captureId) async {
    final capture = _captures.remove(captureId);
    if (capture == null) {
      return null;
    }
    final active = _activeCaptureId == captureId;
    if (active) {
      _activeCaptureId = 0;
    }
    await capture.stop(_native, clearCallback: active);
    return null;
  }

  Future<Object?> _startPlayback(_StartPlayback command) async {
    final server = await _ensureServer();
    final playbackId = command.playbackId;
    final codec = _createCodec(command.spec.format);
    late final _IsolatePlayback playback;
    final pipeline = AudioGroupPlaybackPipeline(
      spec: command.spec,
      codec: codec,
      clockMicros: _wallClockMicros,
      writePcm: (pcm, _) async {
        // False only once the native player is no longer this one: the main
        // isolate stops this playback right after.
        _native.write(command.handle, pcm);
      },
      onReport: (report) => _main.send(_PlaybackReported(playbackId, report)),
      onFailure: (error) => playback.fail(
        audioFailureReasonFor(error, context: AudioFailureContext.playback),
      ),
    );
    playback = _IsolatePlayback(
      playbackId,
      pipeline,
      onFailed: (reason) => _main.send(_PlaybackFailed(playbackId, reason)),
    );
    _playbacks[playbackId] = playback;
    return server?.port ?? 0;
  }

  /// Null when this device can't listen on another port; the sources then
  /// use the main one.
  Future<_MediaServer?> _ensureServer() async {
    final existing = _server;
    if (existing != null) {
      return existing;
    }
    try {
      return _server = await (_serverStart ??= _MediaServer.bind(this));
    } catch (_) {
      _serverStart = null;
      return null;
    }
  }

  _IsolatePlayback? playbackFor(_ClaimData claim) {
    for (final playback in _playbacks.values) {
      final spec = playback.pipeline.spec;
      if (spec.sessionId == claim.sessionId &&
          spec.sourcePeerId == claim.peerId) {
        return playback;
      }
    }
    return null;
  }

  Future<_ClaimData?> lookupClaim(
    String sessionId,
    String token,
    String remoteAddress,
  ) {
    final requestId = ++_nextClaimId;
    final completer = Completer<_ClaimData?>();
    _claimLookups[requestId] = completer;
    _main.send(_ClaimLookup(requestId, sessionId, token, remoteAddress));
    return completer.future
        .timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            _claimLookups.remove(requestId);
            _main.send(_ClaimRelease(requestId));
            return null;
          },
        )
        .then((claim) {
          if (claim != null) {
            _claimIds[claim] = requestId;
          }
          return claim;
        });
  }

  final Map<_ClaimData, int> _claimIds = Map<_ClaimData, int>.identity();

  Future<bool> consumeClaim(_ClaimData claim) {
    final requestId = _claimIds.remove(claim);
    if (requestId == null) {
      return Future<bool>.value(false);
    }
    final completer = Completer<bool>();
    _claimConsumes[requestId] = completer;
    _main.send(_ClaimConsume(requestId));
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _claimConsumes.remove(requestId);
        return false;
      },
    );
  }

  void releaseClaim(_ClaimData claim) {
    final requestId = _claimIds.remove(claim);
    if (requestId != null) {
      _main.send(_ClaimRelease(requestId));
    }
    claim.mediaMacKey.fillRange(0, claim.mediaMacKey.length, 0);
    claim.channelBinding.fillRange(0, claim.channelBinding.length, 0);
  }

  Future<void> _closeChannels(_CloseChannels command) async {
    final closing = <Future<void>>[];
    for (final playback in _playbacks.values) {
      for (final channel in playback.channels.toList(growable: false)) {
        final claim = channel.claim;
        final keep = command.keepMediaMacKey;
        if ((command.sessionId == null ||
                claim.sessionId == command.sessionId) &&
            (command.peerId == null || claim.peerId == command.peerId) &&
            (command.namespace == null ||
                claim.namespace == command.namespace) &&
            (keep == null ||
                !constantTimeBytesEqual(claim.mediaMacKey, keep))) {
          closing.add(channel.close(expected: command.expected));
        }
      }
    }
    await Future.wait(closing);
  }

  AudioShareDiagnostics get diagnostics => _diagnostics;
}

int _wallClockMicros() => DateTime.now().microsecondsSinceEpoch;

AudioCodec _createCodec(AudioStreamFormat format) {
  final config = AudioCodecConfig.fromStreamFormat(format);
  switch (format.codec) {
    case AudioCodecKind.opus:
      final codec = OpusAudioCodec.createInWorker(config);
      if (codec == null) {
        throw UnsupportedError('libopus is not available in the audio isolate');
      }
      return codec;
    case AudioCodecKind.pcmS16le:
      return PcmPassthroughAudioCodec(config);
  }
}

/// Frames from the native capture callback, for an [AudioCaptureSource].
class _CallbackFrames implements AudioCaptureFrames {
  final StreamController<PlatformPcmFrame> _frames =
      StreamController<PlatformPcmFrame>.broadcast(sync: true);

  void add(PlatformPcmFrame frame) => _frames.add(frame);

  @override
  Stream<PlatformPcmFrame> get captureFrames => _frames.stream;

  // Native errors go to the main isolate through the MethodChannel.
  @override
  Stream<PlatformAudioError> get captureErrors =>
      const Stream<PlatformAudioError>.empty();

  // The main isolate starts and stops the native capture.
  @override
  Future<void> startCapture({
    required String sessionId,
    required AudioStreamFormat format,
  }) async {}

  @override
  Future<void> stopCapture({required String sessionId}) async {}

  Future<void> close() => _frames.close();
}

class _IsolateCapture {
  _IsolateCapture(
    this._spec, {
    required AudioCodec codec,
    required AudioShareDiagnostics diagnostics,
    required void Function(AudioGroupPacketFrame packet) send,
    required void Function(int sentAtMicros) onSent,
  }) {
    var reportedAtMicros = 0;
    final schedule = AudioGroupSourceSchedule(
      clockMicros: _wallClockMicros,
      targetLatencyMs: _spec.targetLatencyMs,
      frameDurationMs: _spec.format.frameDurationMs,
    );
    _source = AudioCaptureSource(
      codec: codec,
      platform: _frames,
      diagnostics: diagnostics,
      onPacket: (packet) {
        if (_stopped) {
          return;
        }
        final target = schedule.next();
        if (target == null) {
          return;
        }
        send(
          audioGroupPacketFrame(
            _spec,
            packet,
            targetPlaybackTimeMicros: target,
            durationMicros: schedule.durationMicros,
          ),
        );
        final now = _wallClockMicros();
        if (now - reportedAtMicros >= sentReportMicros) {
          reportedAtMicros = now;
          onSent(now);
        }
      },
    );
  }

  /// How often the main isolate hears that packets are going out.
  static const int sentReportMicros = 400000;

  final AudioGroupCaptureSpec _spec;
  final _CallbackFrames _frames = _CallbackFrames();
  late final AudioCaptureSource _source;
  NativeCallable<AudioCaptureCallbackNative>? _callback;
  _NativeAudio? _native;
  bool _stopped = false;

  Future<void> start(_NativeAudio native) async {
    _native = native;
    await _source.start(sessionId: _spec.streamId, format: _spec.format);
    final callback = NativeCallable<AudioCaptureCallbackNative>.listener(
      _onFrame,
    );
    _callback = callback;
    native.setCaptureCallback(callback.nativeFunction);
  }

  void _onFrame(
    int sequence,
    int captureTimeMicros,
    int sampleRate,
    int channels,
    Pointer<Int16> pcm,
    int sampleCount,
  ) {
    final native = _native;
    if (native == null) {
      return;
    }
    final samples = native.take(pcm, sampleCount);
    if (_stopped || samples.isEmpty) {
      return;
    }
    _frames.add(
      PlatformPcmFrame(
        sessionId: _spec.streamId,
        sequence: sequence,
        captureTimeMicros: captureTimeMicros,
        sampleRate: sampleRate,
        channels: channels.clamp(1, 64),
        pcm: samples,
      ),
    );
  }

  /// [clearCallback] false when a newer capture already set its own.
  Future<void> stop(_NativeAudio native, {required bool clearCallback}) async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    if (clearCallback) {
      // After this returns the native side calls it no more.
      native.setCaptureCallback(nullptr);
    }
    // Buffers already posted to it still arrive and are freed; the native
    // side holds its lock while it posts, so none is posted after this.
    final callback = _callback;
    _callback = null;
    if (callback != null) {
      // Let the posted calls run first, so their buffers are freed.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      callback.close();
    }
    await _source.stop();
    await _frames.close();
  }
}

class _IsolatePlayback {
  _IsolatePlayback(
    this.id,
    this.pipeline, {
    required void Function(AudioFailureReason reason) onFailed,
  }) : _onFailed = onFailed;

  final int id;
  final AudioGroupPlaybackPipeline pipeline;
  final void Function(AudioFailureReason reason) _onFailed;
  final Set<_MediaChannel> channels = <_MediaChannel>{};
  bool _failed = false;

  void fail(AudioFailureReason reason) {
    if (_failed || pipeline.isClosed) {
      return;
    }
    _failed = true;
    _onFailed(reason);
  }

  Future<void> close({required bool expected}) async {
    pipeline.close();
    await Future.wait(
      channels
          .toList(growable: false)
          .map((channel) => channel.close(expected: expected)),
    );
  }
}

/// A source's packets arriving at this isolate's own port.
class _MediaChannel {
  _MediaChannel(this.claim, this.playback);

  final _ClaimData claim;
  final _IsolatePlayback playback;
  BoundedBinaryWebSocketSession? session;
  AuthenticatedMediaPacketDecoder? decoder;
  bool active = false;
  bool _expectedClose = false;

  Future<void> close({required bool expected}) async {
    _expectedClose = _expectedClose || expected;
    await session?.close();
  }

  void handleBytes(Uint8List bytes, AudioShareDiagnostics diagnostics) {
    final packet = AudioGroupPacketFrame.decode(decoder!.decode(bytes));
    final spec = playback.pipeline.spec;
    // Fanned out as is to every sink: sessionId is the shared streamId.
    if (packet.sourcePeerId != claim.peerId ||
        packet.groupId != spec.groupId ||
        packet.streamId != spec.streamId ||
        packet.sessionId != spec.streamId) {
      throw const FormatException('audio group packet claim mismatch');
    }
    if (!active) {
      return;
    }
    diagnostics.groupPacketDelivered(
      groupId: packet.groupId,
      streamId: packet.streamId,
      sequence: packet.sequence,
      payloadBytes: packet.payload.length,
    );
    playback.pipeline.deliver(packet);
  }

  void closed() {
    decoder?.destroy();
    decoder = null;
    playback.channels.remove(this);
    if (!_expectedClose && active) {
      playback.fail(AudioFailureReason.transport);
    }
  }
}

/// The audio isolate's own port, for sources that know it (`mediaPort` in
/// the accept). Same rules as the main port's /audio: a one-time token the
/// main isolate issued and checks, the media proof, one channel per token,
/// and every packet checked against the playback it belongs to.
class _MediaServer {
  _MediaServer._(this._runtime, this._listening, this._server);

  static const int _maxProvisional = 8;
  static const Duration _proofTimeout = Duration(seconds: 3);
  static const Duration _pingInterval = Duration(seconds: 45);

  static Future<_MediaServer> bind(_AudioRuntime runtime) async {
    final listening = await ServerSocket.bind('0.0.0.0', 0);
    final server = HttpServer.listenOn(NoDelayServerSocket(listening));
    server.idleTimeout = const Duration(seconds: 10);
    final media = _MediaServer._(runtime, listening, server);
    server.listen(
      (request) => unawaited(media._handle(request)),
      onError: (Object _) {},
    );
    return media;
  }

  final _AudioRuntime _runtime;
  final ServerSocket _listening;
  final HttpServer _server;
  final Random _random = Random.secure();
  int _provisional = 0;

  int get port => _listening.port;

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path != '/audio' ||
        request.method != 'GET' ||
        !WebSocketTransformer.isUpgradeRequest(request) ||
        (request.headers.value('origin')?.trim().isNotEmpty ?? false) ||
        request.headers.value('sec-websocket-version')?.trim() != '13') {
      await _refuse(request, HttpStatus.badRequest);
      return;
    }
    final sessions = request.uri.queryParametersAll['session'];
    final tokens = request.uri.queryParametersAll['token'];
    if (sessions == null ||
        sessions.length != 1 ||
        sessions.single.isEmpty ||
        tokens == null ||
        tokens.length != 1 ||
        tokens.single.isEmpty) {
      await _refuse(request, HttpStatus.unauthorized);
      return;
    }
    if (_provisional >= _maxProvisional) {
      await _refuse(request, HttpStatus.tooManyRequests);
      return;
    }
    _provisional += 1;
    var released = false;
    void release() {
      if (!released) {
        released = true;
        _provisional -= 1;
      }
    }

    final sessionId = sessions.single;
    final token = tokens.single;
    final claim = await _runtime.lookupClaim(
      sessionId,
      token,
      request.connectionInfo?.remoteAddress.address ?? '',
    );
    final playback = claim == null ? null : _runtime.playbackFor(claim);
    if (claim == null || playback == null || claim.namespace != 'audio-group') {
      if (claim != null) {
        _runtime.releaseClaim(claim);
      }
      release();
      await _refuse(request, HttpStatus.unauthorized);
      return;
    }
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } catch (_) {
      _runtime.releaseClaim(claim);
      release();
      return;
    }
    socket.pingInterval = _pingInterval;
    final channel = IOWebSocketChannel(socket);
    final media = _MediaChannel(claim, playback);
    final nonce = Uint8List.fromList(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    );
    try {
      MediaUpgradeServerSession(
        channel: channel,
        challenge: MediaUpgradeChallenge(
          route: '/audio',
          namespace: claim.namespace,
          sessionId: claim.sessionId,
          tokenHash: mediaUpgradeTokenHash(token),
          nonce: base64Url.encode(nonce).replaceAll('=', ''),
          peerId: claim.peerId,
          connectionGeneration: claim.connectionGeneration,
        ),
        mediaMacKey: claim.mediaMacKey,
        timeout: _proofTimeout,
        onAuthenticated: (authenticated) {
          if (playback.pipeline.isClosed) {
            return false;
          }
          _attach(media, authenticated);
          unawaited(_confirm(media));
          return true;
        },
        onProvisionalFinished: () {
          release();
          if (media.session == null) {
            _runtime.releaseClaim(claim);
          }
        },
      );
    } catch (_) {
      release();
      _runtime.releaseClaim(claim);
      unawaited(socket.close(4001, 'media_auth_failed'));
    }
  }

  void _attach(_MediaChannel media, WebSocketChannel authenticated) {
    media.decoder = AuthenticatedMediaPacketDecoder(
      route: '/audio',
      namespace: media.claim.namespace,
      sessionId: media.claim.sessionId,
      mediaMacKey: media.claim.mediaMacKey,
      channelBinding: media.claim.channelBinding,
      maxPayloadBytes: AudioShareManager.maxPacketPayloadBytes,
    );
    media.playback.channels.add(media);
    final diagnostics = _runtime.diagnostics..audioChannelAttached();
    media.session = BoundedBinaryWebSocketSession(
      channel: authenticated,
      maxMessageBytes: AudioShareManager.maxChannelMessageBytes,
      onMessage: (bytes) {
        diagnostics.audioChannelMessageBytes(bytes.length);
        media.handleBytes(bytes, diagnostics);
      },
      onError: diagnostics.audioChannelError,
      onClosed: media.closed,
    );
  }

  /// The token is used up only after the proof, as on the main port.
  Future<void> _confirm(_MediaChannel media) async {
    final consumed = await _runtime.consumeClaim(media.claim);
    if (!consumed) {
      await media.close(expected: true);
      return;
    }
    media.active = true;
  }

  Future<void> _refuse(HttpRequest request, int status) async {
    try {
      request.response.statusCode = status;
      await request.response.close();
    } catch (_) {}
  }

  Future<void> close() async {
    await _server.close(force: true);
    await _listening.close();
  }
}
