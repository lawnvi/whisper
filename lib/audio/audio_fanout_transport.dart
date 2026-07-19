import 'dart:async';
import 'dart:typed_data';

import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/socket/media_upgrade_proof.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

typedef AudioGroupSinkFailure = void Function(String sinkPeerId, Object error);

abstract class AudioGroupPacketTransport {
  Future<PacketSendResult> send(AudioGroupPacketFrame packet);

  Future<void> close();
}

abstract class AudioGroupObservablePacketTransport
    implements AudioGroupPacketTransport {
  Future<PacketTransportTermination> get done;
}

class AudioGroupPacketByteTransport
    implements AudioGroupObservablePacketTransport {
  AudioGroupPacketByteTransport({
    required void Function(Uint8List bytes) sendBytes,
    Future<void> Function()? closeSink,
  }) : _inner = PacketByteTransport(
         sendBytes: (bytes) => sendBytes(bytes as Uint8List),
         closeSink: closeSink ?? () async {},
       );

  AudioGroupPacketByteTransport.withTransport(this._inner);

  final PacketByteTransport _inner;

  @override
  Future<PacketTransportTermination> get done => _inner.done;

  @override
  Future<PacketSendResult> send(AudioGroupPacketFrame packet) {
    if (_inner.isClosed) {
      return Future<PacketSendResult>.value(PacketSendResult.closed);
    }
    return _inner.send(packet.encode());
  }

  @override
  Future<void> close() => _inner.close();
}

class AudioGroupWebSocketPacketTransport extends AudioGroupPacketByteTransport {
  AudioGroupWebSocketPacketTransport._(PacketByteTransport channelTransport)
    : super.withTransport(channelTransport);

  static Future<AudioGroupWebSocketPacketTransport> connect(
    Uri uri, {
    required Uint8List mediaMacKey,
    required String sessionId,
    required String peerId,
  }) async {
    final channelTransport = await connectPacketWebSocket(
      uri,
      mediaUpgradeContext: MediaUpgradeClientContext(
        namespace: 'audio-group',
        sessionId: sessionId,
        peerId: peerId,
        mediaMacKey: mediaMacKey,
      ),
      packetEncoder: AuthenticatedMediaPacketEncoder(
        route: '/audio',
        namespace: 'audio-group',
        sessionId: sessionId,
        mediaMacKey: mediaMacKey,
        channelBinding: mediaPacketChannelBindingFromUri(uri),
        maxPayloadBytes: 256 * 1024,
      ),
    );
    return AudioGroupWebSocketPacketTransport._(channelTransport);
  }
}

class AudioFanoutTransport {
  AudioFanoutTransport({required AudioGroupSinkFailure onSinkFailure})
    : _onSinkFailure = onSinkFailure;

  final AudioGroupSinkFailure _onSinkFailure;
  final Map<String, AudioGroupPacketTransport> _transports =
      <String, AudioGroupPacketTransport>{};

  Set<String> get sinkPeerIds => Set<String>.unmodifiable(_transports.keys);

  void attach(String sinkPeerId, AudioGroupPacketTransport transport) {
    if (sinkPeerId.isEmpty) {
      return;
    }
    _transports[sinkPeerId] = transport;
    if (transport is AudioGroupObservablePacketTransport) {
      unawaited(
        transport.done.then((termination) {
          if (termination.isUnexpected) {
            _failSink(
              sinkPeerId,
              transport,
              termination.error ??
                  StateError('audio group packet transport closed'),
            );
          }
        }),
      );
    }
  }

  void detach(String sinkPeerId) {
    _transports.remove(sinkPeerId);
  }

  Future<void> detachAndClose(String sinkPeerId) async {
    final transport = _transports.remove(sinkPeerId);
    await transport?.close();
  }

  void send(AudioGroupPacketFrame packet) {
    final entries = _transports.entries.toList(growable: false);
    for (final entry in entries) {
      try {
        final delivery = entry.value.send(packet);
        unawaited(
          delivery.then(
            (result) {
              if (result != PacketSendResult.transportFailure) {
                return;
              }
              _failSink(
                entry.key,
                entry.value,
                StateError('audio group packet transport failed'),
              );
            },
            onError: (Object error, StackTrace _) {
              _failSink(entry.key, entry.value, error);
            },
          ),
        );
      } catch (error) {
        _failSink(entry.key, entry.value, error);
      }
    }
  }

  void _failSink(
    String sinkPeerId,
    AudioGroupPacketTransport transport,
    Object error,
  ) {
    if (!identical(_transports[sinkPeerId], transport)) {
      return;
    }
    _transports.remove(sinkPeerId);
    unawaited(transport.close().catchError((Object _) {}));
    _onSinkFailure(sinkPeerId, error);
  }

  Future<void> closeAll() async {
    final transports = _transports.values.toList(growable: false);
    _transports.clear();
    for (final transport in transports) {
      await transport.close();
    }
  }
}
