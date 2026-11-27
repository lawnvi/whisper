import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../socket/bounded_binary_websocket_session.dart';
import '../../socket/bounded_outbound_queue.dart';
import '../../socket/media_channel_dial.dart';
import '../../socket/packet_byte_transport.dart';
import '../core/window_input_event.dart';
import '../core/window_source.dart';
import '../core/window_stream_models.dart';
import '../pipeline/media_sink.dart';
import '../pipeline/native_input_decoder.dart';
import '../pipeline/stream_worker.dart';
import '../pipeline/worker_opus.dart';
import 'inbound_window_relay.dart';
import 'window_stream_control.dart';

export 'inbound_window_relay.dart' show InboundWindowRelay;

/// A `/window` stream the host dials (see [WindowStreamMediaDial]): the
/// connection reaches this device's Whisper server in the UI isolate, which
/// relays its still-encrypted packets through [port]. [uri] only carries
/// the token this device issued (the packets' channel binding).
class InboundWhisperWindowSpec extends WhisperWindowSpec {
  InboundWhisperWindowSpec({
    required super.uri,
    required super.sessionId,
    required super.viewerPeerId,
    required super.sendKey,
    required super.receiveKey,
    required this.port,
  });

  /// The UI isolate's end of the relay ([InboundWindowRelay]).
  final SendPort port;

  /// How long the host has to dial and prove its token.
  static const Duration connectTimeout = Duration(seconds: 10);
}

/// Viewer side of a `/window` stream, run in the stream isolate: dials the
/// host, proves the token, decrypts video into the local decoder and sends
/// encrypted input back. When the host dials instead, the authenticated
/// socket arrives through [InboundWhisperWindowSpec.port].
class RemoteWindowWorker implements StreamWorker {
  RemoteWindowWorker({
    required this.surface,
    required this.spec,
    required this.sink,
    required this.emit,
  });

  final int surface;
  final WhisperWindowSpec spec;
  final MediaSink sink;
  final void Function(StreamTransportEvent event) emit;

  WebSocketChannel? _channel;
  BoundedBinaryWebSocketSession? _receiver;
  AuthenticatedMediaPacketDecoder? _decoder;
  PacketByteTransport? _input;
  Timer? _statsTimer;
  bool _closed = false;
  bool _ended = false;
  int _videoBytes = 0;
  int _videoFrames = 0;
  int _audioBytes = 0;

  /// The window's sound, once the host said how it is coded.
  WorkerAudioDecoder? _audio;
  final _clock = Stopwatch()..start();
  double? _rttMs;

  @override
  Future<void> start() async {
    final spec = this.spec;
    final uri = spec.uri;
    try {
      final WebSocketChannel channel;
      if (spec is InboundWhisperWindowSpec) {
        // The host dials this device; the UI isolate checked its proof.
        final relay = InboundWindowRelayChannel(spec.port);
        _channel = relay;
        await relay.connected.timeout(InboundWhisperWindowSpec.connectTimeout);
        channel = relay;
      } else {
        channel = await dialMediaChannel(
          uri,
          MediaRoute.window,
          sessionId: spec.sessionId,
          proverPeerId: spec.viewerPeerId,
          proofKey: spec.sendKey,
        );
      }
      _channel = channel;
      _decoder = MediaRoute.window.decoder(
        uri,
        sessionId: spec.sessionId,
        receiveKey: spec.receiveKey,
        maxPayloadBytes:
            WindowStreamPacket.headerBytes + WindowStreamPacket.maxVideoPayload,
      );
      _input = PacketByteTransport.remoteInput(
        addStream: channel.sink.addStream,
        closeSink: () => channel.sink.close(),
        packetEncoder: MediaRoute.window.encoder(
          uri,
          sessionId: spec.sessionId,
          sendKey: spec.sendKey,
          maxPayloadBytes: 8 * 1024,
        ),
      );
      _receiver = BoundedBinaryWebSocketSession(
        channel: channel,
        maxMessageBytes:
            WindowStreamPacket.headerBytes +
            WindowStreamPacket.maxVideoPayload +
            AuthenticatedMediaPacketEnvelope.overheadBytes,
        maxQueuedItems: 96,
        maxQueuedBytes: 48 * 1024 * 1024,
        onMessage: _onMessage,
        onClosed: () => _end(null),
      );
    } catch (error) {
      _end(
        WindowStreamFailure(
          WindowStreamFailureReason.connectionFailed,
          '$error',
        ),
      );
      return;
    } finally {
      spec.destroyKeys();
    }
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      emit(
        TransportStats(
          videoKbps: _videoBytes * 8 / 1000,
          audioKbps: _audioBytes * 8 / 1000,
          videoFps: _videoFrames.toDouble(),
          droppedBeforeDecode: 0,
          rttMs: _rttMs,
        ),
      );
      _videoBytes = 0;
      _videoFrames = 0;
      _audioBytes = 0;
      // How long the connection itself takes there and back.
      final input = _input;
      if (input != null && !_closed) {
        unawaited(
          input.send(
            WindowStreamPacket.ping(_clock.elapsedMicroseconds),
            kind: OutboundPacketKind.key,
          ),
        );
      }
    });
    emit(const TransportConnected());
  }

  void _onMessage(Uint8List bytes) {
    final decoder = _decoder;
    if (decoder == null || _closed) {
      return;
    }
    final packet = WindowStreamPacket.decode(decoder.decode(bytes));
    switch (packet) {
      case WindowStreamVideo():
        _videoBytes += packet.payload.length;
        if (!packet.isConfig) {
          _videoFrames++;
        }
        final writer = sink.beginVideo(surface, packet.payload.length);
        writer.write(packet.payload);
        writer.commit(
          ptsUs: packet.ptsUs,
          config: packet.isConfig,
          key: packet.isKey,
        );
      case WindowStreamAudioFormat():
        _audio?.dispose();
        _audio = WorkerAudioDecoder.open(
          opusCodec: packet.codec == WindowStreamPacket.audioOpus,
          sampleRate: packet.sampleRate,
          channels: packet.channels,
        );
        if (_audio != null) {
          sink.configureAudio(
            surface,
            sampleRate: packet.sampleRate,
            channels: packet.channels,
          );
        }
      case WindowStreamAudio(:final payload, :final ptsUs):
        _audioBytes += payload.length;
        final pcm = _audio?.decode(payload);
        if (pcm != null && pcm.isNotEmpty) {
          final writer = sink.beginAudio(surface, pcm.length);
          writer.write(pcm);
          writer.commit(ptsUs: ptsUs, config: false, key: false);
        }
      case WindowStreamSize(:final width, :final height):
        emit(TransportVideoSize(width, height));
      case WindowStreamTextFocus(:final typing):
        emit(TransportTextFocus(typing: typing));
      case WindowStreamPong(:final clockUs):
        final rtt = (_clock.elapsedMicroseconds - clockUs) / 1000;
        _rttMs = _rttMs == null ? rtt : _rttMs! * 0.7 + rtt * 0.3;
      case WindowStreamTick():
      case WindowStreamPing():
      case WindowStreamInput():
        // Ticks only keep the radio awake; viewers never receive input.
        break;
    }
  }

  @override
  void input(WindowInputEvent event) {
    final encoded = EncodedInput.of(event);
    final transport = _input;
    if (encoded == null || transport == null || _closed) {
      return;
    }
    unawaited(
      transport.send(
        WindowStreamPacket.input(
          kind: encoded.kind,
          code: encoded.code,
          modifiers: encoded.modifiers,
          phase: encoded.phase,
          x: encoded.x,
          y: encoded.y,
          dx: encoded.dx,
          dy: encoded.dy,
          text: encoded.text,
        ),
        kind: switch (event) {
          PointerInput(action: PointerAction.move) =>
            OutboundPacketKind.mouseMove,
          PointerInput() => OutboundPacketKind.button,
          ScrollInput() => OutboundPacketKind.scroll,
          _ => OutboundPacketKind.key,
        },
      ),
    );
  }

  @override
  void control(Uint8List bytes) {}

  @override
  void setScrollMode(ScrollMode mode) {}

  void _end(WindowStreamFailure? failure) {
    if (_ended) {
      return;
    }
    _ended = true;
    emit(TransportEnded(failure: failure));
    unawaited(close());
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _statsTimer?.cancel();
    _audio?.dispose();
    _audio = null;
    await _input?.close();
    await _receiver?.close();
    _decoder?.destroy();
    final channel = _channel;
    await channel?.sink.close().catchError((Object _) {});
    if (channel is InboundWindowRelayChannel) {
      channel.shutdown();
    }
  }
}
