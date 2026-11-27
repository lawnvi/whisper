import 'dart:async';
import 'dart:typed_data';

import '../../socket/bounded_outbound_queue.dart';
import '../../socket/media_channel_dial.dart';
import '../../socket/packet_byte_transport.dart';
import 'host_audio.dart';
import 'window_stream_control.dart';

/// One hosted stream's media as the host drives it: in this isolate
/// ([HostStreamMedia]) or in the host media isolate, which takes video and
/// sound from the capture itself.
abstract interface class HostMediaPlane {
  /// The capture [capture] runs: its packets go out from now on.
  void start(int capture);

  void video(
    Uint8List payload, {
    required int ptsUs,
    required bool config,
    required bool key,
  });

  void audio(
    Uint8List pcm, {
    required int ptsUs,
    required int rate,
    required int channels,
  });

  /// A small packet that must arrive (size, text focus, pong).
  void control(Uint8List packet);

  /// The viewer gets the window's sound (asked for, and not paused).
  set audioOpen(bool open);

  HostMediaCounts get counts;

  Future<void> close();
}

/// A stream's media counters, for diagnostics.
final class HostMediaCounts {
  const HostMediaCounts({
    this.videoInFlight = 0,
    this.busy = false,
    this.audioIn = 0,
    this.audioHeld = 0,
    this.audioOut = 0,
  });

  /// Video packets handed to the socket and not yet written.
  final int videoInFlight;

  /// The encoder was told to skip frames until the socket catches up.
  final bool busy;

  /// Sound chunks from the capture, those held back (sound off or paused)
  /// and packets sent.
  final int audioIn;
  final int audioHeld;
  final int audioOut;
}

/// The keys that seal a stream's packets for its viewer, carried to where
/// they are sealed: this isolate or the host media isolate. Holds its own
/// copies; [build] and [wipe] clear them.
final class HostMediaSeal {
  HostMediaSeal({
    required this.sessionId,
    required Uint8List sendKey,
    required Uint8List channelBinding,
    required this.maxPayloadBytes,
  }) : _key = Uint8List.fromList(sendKey),
       _binding = Uint8List.fromList(channelBinding);

  final String sessionId;
  final int maxPayloadBytes;
  final Uint8List _key;
  final Uint8List _binding;

  AuthenticatedMediaPacketEncoder build() {
    try {
      return AuthenticatedMediaPacketEncoder(
        route: MediaRoute.window.path,
        namespace: MediaRoute.window.namespace,
        sessionId: sessionId,
        mediaMacKey: _key,
        channelBinding: _binding,
        maxPayloadBytes: maxPayloadBytes,
      );
    } finally {
      wipe();
    }
  }

  void wipe() {
    _key.fillRange(0, _key.length, 0);
    _binding.fillRange(0, _binding.length, 0);
  }
}

/// One hosted stream's media on its way to the viewer, all over one ordered
/// transport: video packets, the window's sound (coded to Opus here), the
/// picture's size and text focus, pongs, and a tick every 30 ms while
/// nothing else went (the viewer's radio stays awake). It runs wherever its
/// transport does.
class HostStreamMedia implements HostMediaPlane {
  HostStreamMedia(
    this._transport, {
    required void Function(bool busy) setBusy,
    required void Function() askKeyframe,
    required void Function(String reason) onEnded,
  }) : _setBusy = setBusy,
       _askKeyframe = askKeyframe {
    // A viewer that stopped reading (overflow, a write that never finished)
    // still holds the socket open: the stream ends on that alone.
    unawaited(
      _transport.done.then((end) {
        if (end.isUnexpected) onEnded(end.reason.name);
      }),
    );
  }

  /// Sealed with [seal] and written by [addStream].
  factory HostStreamMedia.sealed({
    required Future<void> Function(Stream<Object>) addStream,
    required Future<void> Function() closeSink,
    required HostMediaSeal seal,
    required void Function(bool busy) setBusy,
    required void Function() askKeyframe,
    required void Function(String reason) onEnded,
  }) => HostStreamMedia(
    PacketByteTransport.video(
      addStream: addStream,
      closeSink: closeSink,
      packetEncoder: seal.build(),
      onKeyframeNeeded: askKeyframe,
    ),
    setBusy: setBusy,
    askKeyframe: askKeyframe,
    onEnded: onEnded,
  );

  final PacketByteTransport _transport;
  final void Function(bool busy) _setBusy;
  final void Function() _askKeyframe;
  HostAudioEncoder? _audio;
  Timer? _tick;
  final _sinceSent = Stopwatch();
  int _videoInFlight = 0;
  bool _busyNow = false;
  bool _keyed = false;
  int _audioIn = 0;
  int _audioHeld = 0;
  int _audioOut = 0;

  @override
  bool audioOpen = false;

  @override
  HostMediaCounts get counts => HostMediaCounts(
    videoInFlight: _videoInFlight,
    busy: _busyNow,
    audioIn: _audioIn,
    audioHeld: _audioHeld,
    audioOut: _audioOut,
  );

  /// Ticks keep the viewer's radio awake while the picture is still.
  @override
  void start(int capture) {
    _sinceSent.start();
    _tick ??= Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (_sinceSent.elapsedMilliseconds >= 30) {
        _sinceSent.reset();
        unawaited(
          _transport.send(
            WindowStreamPacket.tick(),
            kind: OutboundPacketKind.control,
          ),
        );
      }
    });
  }

  @override
  void video(
    Uint8List payload, {
    required int ptsUs,
    required bool config,
    required bool key,
  }) {
    // Nothing decodes before a keyframe: the first ones may have gone
    // before this stream took the capture's packets.
    if (!_keyed) {
      if (!config && !key) {
        _askKeyframe();
        return;
      }
      _keyed = true;
    }
    _sinceSent.reset();
    // Two frames waiting is enough: beyond that every frame only adds
    // delay. The encoder then skips frames until the socket catches up.
    _videoInFlight++;
    _busy(_videoInFlight >= 2);
    final sent = _transport.send(
      WindowStreamPacket.video(
        payload,
        ptsUs: ptsUs,
        flags:
            (config ? WindowStreamPacket.flagConfig : 0) |
            (key ? WindowStreamPacket.flagKey : 0),
      ),
      kind: config
          ? OutboundPacketKind.videoConfig
          : key
          ? OutboundPacketKind.videoKey
          : OutboundPacketKind.videoDelta,
    );
    unawaited(
      sent.whenComplete(() {
        _videoInFlight--;
        if (_videoInFlight == 0) _busy(false);
      }),
    );
  }

  @override
  void audio(
    Uint8List pcm, {
    required int ptsUs,
    required int rate,
    required int channels,
  }) {
    _audioIn++;
    if (!audioOpen) {
      _audioHeld++;
      return;
    }
    final encoder = _audio ??= HostAudioEncoder(
      send: (packet) {
        _audioOut++;
        unawaited(_transport.send(packet, kind: OutboundPacketKind.audio));
      },
    );
    encoder.add(pcm, ptsUs: ptsUs, sampleRate: rate, channels: channels);
  }

  @override
  void control(Uint8List packet) =>
      unawaited(_transport.send(packet, kind: OutboundPacketKind.control));

  void _busy(bool value) {
    if (_busyNow == value) return;
    _busyNow = value;
    _setBusy(value);
  }

  @override
  Future<void> close() async {
    _tick?.cancel();
    _audio?.close();
    await _transport.close();
  }
}
