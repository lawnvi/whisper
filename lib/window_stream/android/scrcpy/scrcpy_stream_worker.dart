import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../core/window_input_event.dart';
import '../../core/window_source.dart';
import '../../core/window_stream_models.dart';
import '../../pipeline/media_sink.dart';
import '../../pipeline/stream_worker.dart';
import '../agent/agent_wire.dart';
import 'scrcpy_input_mapper.dart';
import 'scrcpy_protocol.dart';

/// Runs inside the stream isolate: owns one scrcpy session's sockets, feeds
/// video and audio to the native surface and turns window input into control
/// messages without a round trip through the UI isolate.
class ScrcpyStreamWorker implements StreamWorker {
  ScrcpyStreamWorker({
    required this.surface,
    required this.spec,
    required this.sink,
    required this.emit,
    ScrollMode scrollMode = ScrollMode.wheel,
    Future<Socket> Function(String host, int port)? connect,
  }) : _mapper = ScrcpyInputMapper(scrollMode: scrollMode),
       _connect =
           connect ??
           ((host, port) =>
               Socket.connect(host, port, timeout: const Duration(seconds: 2)));

  final int surface;
  final ScrcpySocketsSpec spec;
  final MediaSink sink;
  final void Function(StreamTransportEvent event) emit;
  final ScrcpyInputMapper _mapper;
  final Future<Socket> Function(String host, int port) _connect;

  Socket? _video;
  Socket? _audio;
  Socket? _control;
  ScrcpyMediaParser? _videoParser;
  ScrcpyMediaParser? _audioParser;
  final _deviceMessages = ScrcpyDeviceMessageParser();
  final _timers = <Timer>{};
  Timer? _statsTimer;
  bool _closed = false;
  bool _endedReported = false;

  int _videoBytes = 0;
  int _audioBytes = 0;
  int _videoFrames = 0;

  static const int _maxConnectAttempts = 100;

  @override
  Future<void> start() async {
    try {
      await _connectVideo();
      if (spec.audio) {
        _audio = await _open(AgentWire.roleAudio);
        _audioParser = ScrcpyMediaParser(_AudioListener(this));
        _listen(_audio!, (chunk) => _audioParser?.add(chunk));
      }
      _control = await _open(AgentWire.roleInput);
      _listen(_control!, _onControlBytes);
    } catch (error) {
      _end(
        WindowStreamFailure(
          WindowStreamFailureReason.connectionFailed,
          '$error',
        ),
      );
      return;
    }
    _statsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _reportStats(),
    );
    emit(const TransportConnected());
  }

  /// Connects one socket; for whisper-agent it starts with the hello.
  Future<Socket> _open(int role) async {
    final socket = await _connect(spec.host, spec.port);
    socket.setOption(SocketOption.tcpNoDelay, true);
    final token = spec.agentToken;
    if (token != null) {
      socket.add(AgentWire.hello(role, spec.agentStream, token));
    }
    return socket;
  }

  /// The forwarded port accepts a connection even before the server listens,
  /// then closes it; the server's dummy byte (the agent's status byte) proves
  /// the session is real.
  Future<void> _connectVideo() async {
    for (
      var attempt = 0;
      attempt < _maxConnectAttempts && !_closed;
      attempt++
    ) {
      Socket? socket;
      try {
        socket = await _open(AgentWire.roleVideo);
        final accepted = Completer<bool>();
        final parser = ScrcpyMediaParser(
          _VideoListener(this),
          expectDummyByte: true,
          onDummyByte: () {
            if (!accepted.isCompleted) accepted.complete(true);
          },
        );
        _listen(
          socket,
          parser.add,
          onDone: () {
            if (!accepted.isCompleted) accepted.complete(false);
          },
        );
        final ok = await accepted.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () => false,
        );
        if (ok) {
          _video = socket;
          _videoParser = parser;
          return;
        }
      } catch (_) {
        // Retry below.
      }
      socket?.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const SocketException('scrcpy server did not accept the connection');
  }

  void _listen(
    Socket socket,
    void Function(Uint8List chunk) onData, {
    void Function()? onDone,
  }) {
    socket.listen(
      onData,
      onError: (Object _) {
        onDone?.call();
        _onSocketClosed(socket);
      },
      onDone: () {
        onDone?.call();
        _onSocketClosed(socket);
      },
      cancelOnError: true,
    );
  }

  void _onSocketClosed(Socket socket) {
    if (_closed) {
      return;
    }
    if (identical(socket, _video) || identical(socket, _control)) {
      _end(null);
    }
  }

  void _onControlBytes(Uint8List chunk) {
    try {
      for (final message in _deviceMessages.add(chunk)) {
        if (message is ScrcpyClipboardMessage) {
          emit(TransportClipboard(message.text));
        }
      }
    } on FormatException {
      // Ignore messages this client does not understand.
    }
  }

  void _reportStats() {
    emit(
      TransportStats(
        videoKbps: _videoBytes * 8 / 1000,
        audioKbps: _audioBytes * 8 / 1000,
        videoFps: _videoFrames.toDouble(),
        droppedBeforeDecode: 0,
      ),
    );
    _videoBytes = 0;
    _audioBytes = 0;
    _videoFrames = 0;
  }

  @override
  void input(WindowInputEvent event) {
    for (final message in _mapper.map(event)) {
      if (message.delay == Duration.zero) {
        control(message.bytes);
      } else {
        late final Timer timer;
        timer = Timer(message.delay, () {
          _timers.remove(timer);
          control(message.bytes);
        });
        _timers.add(timer);
      }
    }
  }

  @override
  void control(Uint8List bytes) {
    final socket = _control;
    if (socket == null || _closed) {
      return;
    }
    socket.add(bytes);
  }

  @override
  void setScrollMode(ScrollMode mode) {
    _mapper.scrollMode = mode;
  }

  void _end(WindowStreamFailure? failure) {
    if (_endedReported) {
      return;
    }
    _endedReported = true;
    emit(TransportEnded(failure: failure));
    close();
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _statsTimer?.cancel();
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _videoParser?.close();
    _audioParser?.close();
    _video?.destroy();
    _audio?.destroy();
    _control?.destroy();
  }
}

class _VideoListener implements ScrcpyMediaListener {
  _VideoListener(this._worker);

  final ScrcpyStreamWorker _worker;

  @override
  void onCodec(int codecId) {
    if (codecId != ScrcpyProtocol.codecH264) {
      _worker._end(
        WindowStreamFailure(
          WindowStreamFailureReason.serverStartFailed,
          'video codec ${codecId.toRadixString(16)}',
        ),
      );
    }
  }

  @override
  void onSession(int width, int height) {
    _worker._mapper.frameWidth = width;
    _worker._mapper.frameHeight = height;
    _worker.emit(TransportVideoSize(width, height));
  }

  @override
  MediaPacketWriter beginPacket(int length) {
    _worker._videoBytes += length;
    return _CountingWriter(
      _worker.sink.beginVideo(_worker.surface, length),
      onCommit: (config) {
        if (!config) _worker._videoFrames++;
      },
    );
  }
}

class _AudioListener implements ScrcpyMediaListener {
  _AudioListener(this._worker);

  final ScrcpyStreamWorker _worker;

  @override
  void onCodec(int codecId) {
    final enabled = codecId == ScrcpyProtocol.codecRaw;
    if (enabled) {
      _worker.sink.configureAudio(
        _worker.surface,
        sampleRate: 48000,
        channels: 2,
      );
    }
    _worker.emit(TransportAudioState(enabled: enabled));
  }

  @override
  void onSession(int width, int height) {}

  @override
  MediaPacketWriter beginPacket(int length) {
    _worker._audioBytes += length;
    return _worker.sink.beginAudio(_worker.surface, length);
  }
}

class _CountingWriter implements MediaPacketWriter {
  _CountingWriter(this._inner, {required this.onCommit});

  final MediaPacketWriter _inner;
  final void Function(bool config) onCommit;

  @override
  void write(Uint8List chunk) => _inner.write(chunk);

  @override
  void commit({required int ptsUs, required bool config, required bool key}) {
    onCommit(config);
    _inner.commit(ptsUs: ptsUs, config: config, key: key);
  }

  @override
  void discard() => _inner.discard();
}
