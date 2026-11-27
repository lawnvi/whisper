import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/socket/auth_handshake_lifecycle.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/peer_link.dart';
import 'package:whisper/socket/peer_profile_refresh.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/socket_events.dart';
import 'package:whisper/socket/transport_close_guard.dart';
import 'package:whisper/socket/wire_input_policy.dart';
import 'package:whisper/state/peer_profile.dart';

/// Ordered cleanup step executed when a peer's active connection terminates.
typedef PeerDisconnectCleanupStep =
    FutureOr<void> Function(String peerId, PeerDisconnectCause cause);

/// Owns the live [PeerLink] map, authenticated per-peer [PeerConnectionRegistry],
/// remote [PeerProfile] cache, and serialized disconnect cleanup lifecycle.
class PeerDirectory {
  PeerDirectory({
    required Duration socketCloseTimeout,
    required int maxPreAuthMessageBytes,
    required int maxAuthenticatedMessageBytes,
    required int authenticatedFrameOverhead,
    required void Function(Future<void> future, {required String context})
    ignoreFuture,
    required void Function(String message) logInfo,
  }) : _socketCloseTimeout = socketCloseTimeout,
       _maxPreAuthMessageBytes = maxPreAuthMessageBytes,
       _maxAuthenticatedMessageBytes = maxAuthenticatedMessageBytes,
       _authenticatedFrameOverhead = authenticatedFrameOverhead,
       _ignoreFuture = ignoreFuture,
       _logInfo = logInfo;

  final Duration _socketCloseTimeout;
  final int _maxPreAuthMessageBytes;
  final int _maxAuthenticatedMessageBytes;
  final int _authenticatedFrameOverhead;
  final void Function(Future<void> future, {required String context})
  _ignoreFuture;
  final void Function(String message) _logInfo;

  final PeerConnectionRegistry connections = PeerConnectionRegistry();
  final PeerProfileRefreshTracker profileRefreshTracker =
      PeerProfileRefreshTracker();

  final Map<WebSocketSink, PeerLink> _linksBySink = <WebSocketSink, PeerLink>{};
  final Map<String, PeerLink> _activeByPeerId = <String, PeerLink>{};
  final Map<String, PeerProfile> _remoteProfilesByPeerId =
      <String, PeerProfile>{};
  final Map<WebSocketSink, Future<void>> _socketCleanups =
      <WebSocketSink, Future<void>>{};
  final Map<WebSocketSink, TransportCloseGuard> _closeGuards =
      <WebSocketSink, TransportCloseGuard>{};

  Set<String> get connectedPeerIds => connections.connectedPeerIds;

  bool get hasAnySessions =>
      _linksBySink.values.any((link) => link.session != null);

  List<PeerLink> get linksSnapshot =>
      _linksBySink.values.toList(growable: false);

  List<Future<void>> get activeCleanupsSnapshot =>
      _socketCleanups.values.toList(growable: false);

  PeerLink ensureLink(WebSocketSink sink) =>
      _linksBySink.putIfAbsent(sink, () => PeerLink(sink: sink));

  PeerLink? linkForSink(WebSocketSink? sink) =>
      sink == null ? null : _linksBySink[sink];

  PeerLink? linkForPeer(String peerId) => _activeByPeerId[peerId];

  PeerLink? removeLink(WebSocketSink sink) => _linksBySink.remove(sink);

  PeerSocketSession? sessionForSink(WebSocketSink? sink) =>
      sink == null ? null : _linksBySink[sink]?.session;

  PeerSocketSession? sessionForPeer(String peerId) =>
      _activeByPeerId[peerId]?.session;

  String? peerIdForSink(WebSocketSink? sink) =>
      sink == null ? null : _linksBySink[sink]?.registeredPeerId;

  ({String host, int port})? endpointForSink(WebSocketSink? sink) =>
      sink == null ? null : _linksBySink[sink]?.endpoint;

  void setEndpoint(WebSocketSink sink, ({String host, int port}) endpoint) {
    ensureLink(sink).endpoint = endpoint;
  }

  void attachSession(WebSocketSink sink, PeerSocketSession session) {
    ensureLink(sink).session = session;
  }

  void setTerminalDisconnectCause(
    WebSocketSink sink,
    PeerDisconnectCause cause,
  ) {
    ensureLink(sink).terminalDisconnectCause = cause;
  }

  PeerLink? findLinkForSession(PeerSocketSession? target) {
    if (target == null) return null;
    for (final link in _linksBySink.values) {
      if (identical(link.session, target)) {
        return link;
      }
    }
    return null;
  }

  WebSocketSink? findSinkForSession(PeerSocketSession? target) =>
      findLinkForSession(target)?.sink;

  WebSocketSink? findSinkForPeer(String peerId) {
    for (final link in _linksBySink.values) {
      if (link.registeredPeerId == peerId) {
        return link.sink;
      }
    }
    return null;
  }

  String? mediaDialHostFor(PeerSocketSession session) =>
      findLinkForSession(session)?.plainHost;

  int? connectionIdOf(String peerId) =>
      connections.currentBinding(peerId)?.generation;

  bool isConnectedTo(String peerId) => connections.isConnectedTo(peerId);

  bool isCurrent(String peerId, int generation) =>
      connections.isCurrent(peerId, generation);

  TransferConnectionBinding? currentBinding(String peerId) =>
      connections.currentBinding(peerId);

  String localPeerIdFor(String peerId) =>
      _activeByPeerId[peerId]?.localPeerId ?? '';

  String? remoteIdentityPublicKeyFor(String peerId) =>
      _activeByPeerId[peerId]?.session?.remoteIdentityPublicKey;

  PeerProfile? remoteProfileFor(
    String peerId, {
    String legacyReceiver = '',
    PeerProfile? legacyProfile,
  }) {
    return _remoteProfilesByPeerId[peerId] ??
        (peerId == legacyReceiver ? legacyProfile : null);
  }

  bool canBrowseFilesOf(
    String peerId, {
    String legacyReceiver = '',
    PeerProfile? legacyProfile,
  }) =>
      sessionForPeer(peerId)?.isAuthenticated == true &&
      remoteProfileFor(
            peerId,
            legacyReceiver: legacyReceiver,
            legacyProfile: legacyProfile,
          )?.capabilities.remoteFilesV1 ==
          true;

  bool supportsRemoteInputFor(
    String peerId, {
    String legacyReceiver = '',
    PeerProfile? legacyProfile,
  }) {
    final profile = remoteProfileFor(
      peerId,
      legacyReceiver: legacyReceiver,
      legacyProfile: legacyProfile,
    );
    return profile?.capabilities.remoteInputSourceV1 == true &&
        profile?.capabilities.remoteInputSinkV1 == true;
  }

  bool supportsManualInputFor(
    String peerId, {
    String legacyReceiver = '',
    PeerProfile? legacyProfile,
  }) {
    final profile = remoteProfileFor(
      peerId,
      legacyReceiver: legacyReceiver,
      legacyProfile: legacyProfile,
    );
    return profile?.capabilities.remoteInputManualSinkV1 == true;
  }

  bool supportsRemoteInputTopologyFor(
    String peerId, {
    String legacyReceiver = '',
    PeerProfile? legacyProfile,
  }) {
    final profile = remoteProfileFor(
      peerId,
      legacyReceiver: legacyReceiver,
      legacyProfile: legacyProfile,
    );
    return supportsRemoteInputFor(
          peerId,
          legacyReceiver: legacyReceiver,
          legacyProfile: legacyProfile,
        ) &&
        profile?.capabilities.remoteInputTopologyV1 == true &&
        profile?.displayTopology?.isNotEmpty == true;
  }

  bool supportsRemoteInputWorkspaceGraphFor(
    String peerId, {
    String legacyReceiver = '',
    PeerProfile? legacyProfile,
  }) {
    final profile = remoteProfileFor(
      peerId,
      legacyReceiver: legacyReceiver,
      legacyProfile: legacyProfile,
    );
    return supportsRemoteInputTopologyFor(
          peerId,
          legacyReceiver: legacyReceiver,
          legacyProfile: legacyProfile,
        ) &&
        profile?.capabilities.remoteInputWorkspaceGraphV1 == true;
  }

  RemoteInputTopology? remoteDisplayTopologyFor(
    String peerId, {
    String legacyReceiver = '',
    PeerProfile? legacyProfile,
  }) => remoteProfileFor(
    peerId,
    legacyReceiver: legacyReceiver,
    legacyProfile: legacyProfile,
  )?.displayTopology;

  List<DeviceData> connectedAudioGroupSinkDevices({
    String preferredPeerId = '',
    String legacyReceiver = '',
    PeerProfile? legacyProfile,
  }) {
    final devices = <DeviceData>[];
    for (final peerId in connectedPeerIds) {
      final profile = remoteProfileFor(
        peerId,
        legacyReceiver: legacyReceiver,
        legacyProfile: legacyProfile,
      );
      final device = profile?.device;
      if (device != null) {
        devices.add(device);
      }
    }
    _sortConnectedDevices(devices, preferredPeerId: preferredPeerId);
    return devices;
  }

  List<DeviceData> connectedRemoteInputDevices({
    String preferredPeerId = '',
    String legacyReceiver = '',
    PeerProfile? legacyProfile,
  }) {
    final devices = <DeviceData>[];
    for (final peerId in connectedPeerIds) {
      if (!supportsRemoteInputFor(
        peerId,
        legacyReceiver: legacyReceiver,
        legacyProfile: legacyProfile,
      )) {
        continue;
      }
      final profile = remoteProfileFor(
        peerId,
        legacyReceiver: legacyReceiver,
        legacyProfile: legacyProfile,
      );
      final device = profile?.device;
      if (device != null) {
        devices.add(device);
      }
    }
    _sortConnectedDevices(devices, preferredPeerId: preferredPeerId);
    return devices;
  }

  void _sortConnectedDevices(
    List<DeviceData> devices, {
    required String preferredPeerId,
  }) {
    devices.sort((left, right) {
      if (left.uid == preferredPeerId) return -1;
      if (right.uid == preferredPeerId) return 1;
      return left.name.compareTo(right.name);
    });
  }

  void setStoredRemoteProfile(String peerId, PeerProfile? profile) {
    if (profile == null) {
      _remoteProfilesByPeerId.remove(peerId);
    } else {
      _remoteProfilesByPeerId[peerId] = profile;
    }
  }

  void clearStoredRemoteProfiles() {
    _remoteProfilesByPeerId.clear();
  }

  void removeStoredRemoteProfile(String peerId) {
    _remoteProfilesByPeerId.remove(peerId);
  }

  void completeProfileRefreshWaiters({
    String? peerId,
    required PeerProfile? Function(String peerId) currentProfile,
  }) {
    profileRefreshTracker.complete(
      peerId: peerId,
      currentProfile: currentProfile,
    );
  }

  Future<void> closeSink(WebSocketSink sink) {
    final guard = _closeGuards.putIfAbsent(
      sink,
      () => TransportCloseGuard(
        close: () async {
          await sink.close();
        },
        timeout: _socketCloseTimeout,
      ),
    );
    return guard.close();
  }

  void closeDeferredSupersededSink(PeerSocketSession session) {
    final deferred = findLinkForSession(session)?.takeDeferredSupersededSink();
    if (deferred != null) {
      _ignoreFuture(closeSink(deferred), context: 'close superseded');
    }
  }

  void closeDeferredSupersededSinkOnLink(PeerLink link) {
    final deferred = link.takeDeferredSupersededSink();
    if (deferred != null) {
      _ignoreFuture(closeSink(deferred), context: 'close superseded');
    }
  }

  Future<bool> sendBytesOnSink(
    WebSocketSink sink,
    Object message, {
    bool rawAuth = false,
  }) {
    final link = _linksBySink[sink];
    if (link == null) {
      return closeSink(sink).then((_) => false);
    }
    return link.sendBytes(
      message,
      rawAuth: rawAuth,
      maxPreAuthBytes: _maxPreAuthMessageBytes,
      maxAuthenticatedBytes: _maxAuthenticatedMessageBytes,
      authenticatedFrameOverhead: _authenticatedFrameOverhead,
      closeTransport: () => closeSink(sink),
    );
  }

  Future<bool> sendToAwaited(String peerId, Object payload) =>
      connections.sendToAwaited(peerId, payload);

  Future<bool> sendToAwaitedIfCurrent(
    TransferConnectionBinding binding,
    Object payload,
  ) => connections.sendToAwaitedIfCurrent(binding, payload);

  Future<bool> sendTargetedOrDefault({
    required String? peerId,
    required Object message,
    required Future<bool> Function() sendDefault,
  }) => connections.sendTargetedOrDefault(
    peerId: peerId,
    message: message,
    sendDefault: sendDefault,
  );

  Future<bool> registerConnection({
    required String peerId,
    required WebSocketSink sink,
    required PeerSocketSession session,
    required Future<void> Function(String peerId) onSupersededPreRegister,
    required void Function(TransferConnectionBinding binding) onRegistered,
  }) async {
    if (peerId.isEmpty || !session.isAuthenticationReady) return false;
    final link = ensureLink(sink)..session = session;
    var superseded = false;
    final deferredOldLink = session.role == PeerSocketRole.server
        ? _activeByPeerId[peerId]
        : null;
    if (deferredOldLink != null) {
      deferredOldLink.deferCloseForSuperseded = true;
    }
    try {
      await connections.register(
        PeerConnection(
          peerId: peerId,
          connectionId: session.connectionGeneration,
          send: (message) {
            if (session.isAuthenticated) {
              _ignoreFuture(
                sendBytesOnSink(sink, message).then<void>((_) {}),
                context: 'send peer message',
              );
            }
          },
          sendAsync: (message) => session.isAuthenticated
              ? sendBytesOnSink(sink, message)
              : Future<bool>.value(false),
          close: () async {
            link.registeredPeerId = null;
            session.close();
            if (link.takeDeferCloseForSuperseded()) return;
            await closeSink(sink);
          },
        ),
        afterRemove: (binding) async {
          superseded = true;
          final previous = _activeByPeerId[peerId];
          if (previous?.generation == binding.generation) {
            _activeByPeerId.remove(peerId);
          }
          await onSupersededPreRegister(peerId);
        },
        afterRegister: (binding) {
          if (binding.generation != session.connectionGeneration ||
              !session.isAuthenticationReady) {
            throw StateError('stale peer registration');
          }
          _activeByPeerId[peerId] = link;
          link.registeredPeerId = peerId;
          onRegistered(binding);
        },
      );
      if (deferredOldLink != null &&
          !deferredOldLink.takeDeferCloseForSuperseded()) {
        link.deferredSupersededSink = deferredOldLink.sink;
      }
    } catch (_) {
      if (deferredOldLink != null &&
          !deferredOldLink.takeDeferCloseForSuperseded()) {
        _ignoreFuture(
          closeSink(deferredOldLink.sink),
          context: 'close superseded',
        );
      }
      rethrow;
    }
    return superseded;
  }

  Future<void> runSocketCleanupQueued(
    WebSocketSink sink,
    Future<void> Function() onDone,
  ) {
    final existing = _socketCleanups[sink];
    if (existing != null) {
      return existing;
    }
    late final Future<void> cleanup;
    cleanup = () async {
      try {
        await _linksBySink[sink]?.session?.stopReceivingAndDrain();
      } catch (error, stackTrace) {
        _logInfo('停止 websocket 接收失败: $error\n$stackTrace');
      }
      try {
        await onDone();
      } catch (error, stackTrace) {
        _logInfo('处理 websocket 关闭失败: $error\n$stackTrace');
      } finally {
        if (identical(_socketCleanups[sink], cleanup)) {
          unawaited(_socketCleanups.remove(sink));
        }
        _closeGuards.remove(sink);
      }
    }();
    _socketCleanups[sink] = cleanup;
    return cleanup;
  }

  bool removedBindingOwnsPeerState(TransferConnectionBinding binding) {
    if (connections.currentBinding(binding.peerId) != null) {
      return false;
    }
    final active = _activeByPeerId[binding.peerId];
    return active == null || active.generation == binding.generation;
  }

  Future<void> removePeerConnection(
    String peerId,
    PeerDisconnectCause cause, {
    required Future<void> Function(
      TransferConnectionBinding removed,
      PeerSocketSession? closingSession,
      PeerDisconnectCause cause,
    )
    afterRemove,
  }) async {
    final binding = connections.currentBinding(peerId);
    if (binding == null) {
      return;
    }
    await connections.removeIfCurrent(
      binding,
      afterRemove: (removed) =>
          afterRemove(removed, sessionForPeer(peerId), cause),
    );
  }

  Future<bool> removeUnresponsivePeerIfCurrent(
    TransferConnectionBinding binding, {
    required Future<void> Function(
      TransferConnectionBinding removed,
      PeerSocketSession? closingSession,
      PeerDisconnectCause cause,
    )
    afterRemove,
  }) {
    return connections.removeIfCurrent(
      binding,
      afterRemove: (removed) => afterRemove(
        removed,
        sessionForPeer(removed.peerId),
        PeerDisconnectCause.watchdog,
      ),
    );
  }

  Future<bool> removeConnectionIfCurrentForDone({
    required String peerId,
    required PeerSocketSession? closingSession,
    required PeerDisconnectCause cause,
    required Future<void> Function(
      TransferConnectionBinding removed,
      PeerSocketSession? closingSession,
      PeerDisconnectCause cause,
    )
    afterRemove,
  }) {
    return AuthSocketLifecycle.removeConnectionIfCurrent(
      connections: connections,
      peerId: peerId,
      closingSession: closingSession,
      currentSession: sessionForPeer(peerId),
      afterRemove: (binding) => afterRemove(binding, closingSession, cause),
    );
  }

  /// Drops the active-peer pointer if it still belongs to [binding] (and
  /// [closingSession] when provided), then runs the ordered [cleanupSteps]
  /// as long as [binding] still owns the peer's state.
  Future<bool> releaseActivePeerAndRunCleanup(
    TransferConnectionBinding binding, {
    PeerSocketSession? closingSession,
    required PeerDisconnectCause cause,
    required List<PeerDisconnectCleanupStep> cleanupSteps,
  }) async {
    final peerId = binding.peerId;
    final current = _activeByPeerId[peerId];
    if (current != null &&
        current.generation == binding.generation &&
        (closingSession == null ||
            identical(current.session, closingSession))) {
      _activeByPeerId.remove(peerId);
    }
    if (!removedBindingOwnsPeerState(binding)) {
      return false;
    }
    for (final step in cleanupSteps) {
      if (!removedBindingOwnsPeerState(binding)) {
        return false;
      }
      await step(peerId, cause);
    }
    if (!removedBindingOwnsPeerState(binding)) {
      return false;
    }
    _remoteProfilesByPeerId.remove(peerId);
    return removedBindingOwnsPeerState(binding);
  }

  void validateBusinessSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    final peerId = session.remotePeerId;
    WireInputPolicy.validateSessionBinding(
      isAuthenticated: session.isAuthenticated,
      sessionPeerId: peerId,
      sinkPeerId: peerIdForSink(sink) ?? '',
      sessionGeneration: generation,
      isCurrentSession: identical(sessionForPeer(peerId), session),
      isCurrentConnection: connections.isCurrent(peerId, generation),
    ).requireAccepted();
  }

  PeerProfile requireRemoteProfileForSession(PeerSocketSession session) {
    final peerId = session.remotePeerId;
    final profile = _remoteProfilesByPeerId[peerId];
    if (profile == null || profile.device.uid != peerId) {
      throw const WireInputRejected(WireInputReason.sessionNotCurrent);
    }
    return profile;
  }

  bool debugSendMalformedTransportFrame(String peerId) {
    final sink = findSinkForPeer(peerId);
    if (sink == null) return false;
    sink.add(Uint8List.fromList(const <int>[0]));
    return true;
  }

  Future<bool> debugDropPeerTransport(String peerId) async {
    final sink = findSinkForPeer(peerId);
    if (sink == null) return false;
    await sink.close();
    return true;
  }

  void clearAllAfterClose() {
    _linksBySink.clear();
    _activeByPeerId.clear();
    _remoteProfilesByPeerId.clear();
  }
}
