import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_diagnostics.dart';
import 'package:whisper/socket/media_channel_dial.dart';
import 'package:whisper/socket/media_channel_registry.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';

typedef AudioGroupPacketCallback = void Function(AudioGroupPacketFrame packet);
typedef AudioGroupPacketClaimValidator =
    bool Function(SessionUpgradeClaim claim, AudioGroupPacketFrame packet);
typedef AudioMediaChannelLifecycleListener =
    void Function(AudioMediaChannelClosedEvent event);

typedef AudioMediaChannelClosedEvent = MediaChannelClosed;

/// Checks and uses up the token of a media connection that came to the audio
/// isolate's own port, with the main port's rules.
abstract interface class AudioMediaClaimBroker {
  /// The claim, still unused, or null when the connection is not accepted.
  SessionUpgradeClaim? lookup({
    required String sessionId,
    required String token,
    required Object remoteAddress,
  });

  /// Uses the token up; null when it is no longer valid.
  SessionUpgradeClaim? consume({
    required String sessionId,
    required String token,
    required SessionUpgradeClaim expected,
  });

  /// For a token this device issued for a sink to dial back on: this
  /// device's send key of that token's connection, to send the sound with.
  /// Null once that connection is gone or replaced.
  Uint8List? sendKeyFor(SessionUpgradeClaim claim);
}

/// Media channels the audio isolate holds, closed along with this manager's.
abstract interface class AudioRemoteMediaChannels {
  /// Those matching every filter given; with [keepMediaMacKey], those whose
  /// key is a different one.
  Future<void> closeChannels({
    String? sessionId,
    String? peerId,
    String? namespace,
    Uint8List? keepMediaMacKey,
    bool expected = false,
  });
}

class AudioShareManager {
  static const int maxPacketPayloadBytes = 256 * 1024;
  static const int maxChannelMessageBytes =
      maxPacketPayloadBytes + AuthenticatedMediaPacketEnvelope.overheadBytes;

  AudioShareManager({
    this.onGroupPacket,
    AudioShareDiagnostics? diagnostics,
  }) : _diagnostics = diagnostics ?? AudioShareDiagnostics.shared;

  static final AudioShareManager shared = AudioShareManager();

  AudioGroupPacketCallback? onGroupPacket;

  /// Set by the socket manager while its server runs.
  AudioMediaClaimBroker? claimBroker;

  /// Set while the audio isolate listens on its own port.
  AudioRemoteMediaChannels? remoteChannels;
  final AudioShareDiagnostics _diagnostics;
  final MediaChannelRegistry _channels = MediaChannelRegistry(
    MediaRoute.audio,
    maxPayloadBytes: maxPacketPayloadBytes,
  );
  final Set<AudioMediaChannelLifecycleListener> _channelLifecycleListeners =
      <AudioMediaChannelLifecycleListener>{};

  int get activeChannelCount => _channels.activeCount;
  bool get hasActiveChannels => _channels.activeCount > 0;
  bool get isClosingChannels => _channels.isClosing;

  void Function() addChannelLifecycleListener(
    AudioMediaChannelLifecycleListener listener,
  ) {
    _channelLifecycleListeners.add(listener);
    return () => _channelLifecycleListeners.remove(listener);
  }

  Future<void> closeSessionChannels(
    String sessionId, {
    String? peerId,
    String? namespace,
  }) async {
    await Future.wait(<Future<void>>[
      _channels.closeSession(sessionId, peerId: peerId, namespace: namespace),
      ?remoteChannels?.closeChannels(
        sessionId: sessionId,
        peerId: peerId,
        namespace: namespace,
        expected: true,
      ),
    ]);
  }

  Future<void> closePeerChannels(String peerId) async {
    await Future.wait(<Future<void>>[
      _channels.closePeer(peerId),
      ?remoteChannels?.closeChannels(peerId: peerId),
    ]);
  }

  Future<void> closeSupersededPeerChannels(
    String peerId, {
    required Uint8List mediaMacKey,
  }) async {
    await Future.wait(<Future<void>>[
      _channels.closeSuperseded(peerId, mediaMacKey: mediaMacKey),
      ?remoteChannels?.closeChannels(
        peerId: peerId,
        keepMediaMacKey: mediaMacKey,
      ),
    ]);
  }

  void handlePacketBytes(Uint8List bytes) {
    try {
      _deliverGroupPacket(AudioGroupPacketFrame.decode(bytes));
    } on FormatException catch (error) {
      _diagnostics.packetDecodeFailed(
        bytes: bytes.length,
        legacyError: error,
        groupError: error,
      );
      rethrow;
    }
  }

  void _deliverGroupPacket(AudioGroupPacketFrame packet) {
    _diagnostics.groupPacketDelivered(
      groupId: packet.groupId,
      streamId: packet.streamId,
      sequence: packet.sequence,
      payloadBytes: packet.payload.length,
    );
    onGroupPacket?.call(packet);
  }

  void _handleClaimPacketBytes(
    Uint8List bytes, {
    required SessionUpgradeClaim claim,
    AudioGroupPacketClaimValidator? groupPacketValidator,
  }) {
    final packet = AudioGroupPacketFrame.decode(bytes);
    // 组播协议约定:同一帧原样 fanout 给全部 sink,packet.sessionId 是共享
    // streamId 而非 claim 绑定的每-sink sessionId,由 groupPacketValidator
    // 按组会话校验。
    if (packet.sourcePeerId != claim.peerId ||
        groupPacketValidator?.call(claim, packet) != true) {
      throw const FormatException('audio group packet claim mismatch');
    }
    _deliverGroupPacket(packet);
  }

  bool canAttachClaim(
    SessionUpgradeClaim claim, {
    bool Function(SessionUpgradeClaim claim)? additionalValidator,
    bool Function(SessionUpgradeClaim claim)? claimValidator,
  }) {
    return _channels.isForRoute(claim) &&
        claimValidator?.call(claim) != false &&
        !_channels.hasChannelFor(claim) &&
        (additionalValidator?.call(claim) ?? false);
  }

  bool attachChannel(
    WebSocketChannel channel, {
    required SessionUpgradeClaim claim,
    bool Function(SessionUpgradeClaim claim)? additionalValidator,
    AudioGroupPacketClaimValidator? groupPacketValidator,
    bool Function(SessionUpgradeClaim claim)? claimValidator,
  }) {
    if (claimValidator?.call(claim) == false ||
        !(additionalValidator?.call(claim) ?? false)) {
      unawaited(channel.sink.close().catchError((Object _) {}));
      return false;
    }
    final attached = _channels.attach(
      channel,
      claim: claim,
      onPacket: (payload) {
        _diagnostics.audioChannelMessageBytes(payload.length);
        _handleClaimPacketBytes(
          payload,
          claim: claim,
          groupPacketValidator: groupPacketValidator,
        );
      },
      onError: _diagnostics.audioChannelError,
      onClosed: _handleChannelClosed,
    );
    if (attached) _diagnostics.audioChannelAttached();
    return attached;
  }

  void _handleChannelClosed(AudioMediaChannelClosedEvent event) {
    _diagnostics.audioChannelClosed();
    for (final listener in _channelLifecycleListeners.toList(growable: false)) {
      try {
        listener(event);
      } catch (_) {}
    }
  }

  Future<void> closeChannels() {
    final remote = remoteChannels?.closeChannels(expected: true);
    if (remote != null) {
      unawaited(remote.catchError((Object _) {}));
    }
    return _channels.closeAll();
  }
}
