import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/socket/transfer_channel_protocol.dart';
import 'package:whisper/socket/transfer_data_isolate.dart';
import 'package:whisper/socket/whisper_ports.dart';

/// Host callbacks connecting [TransferChannelManager] to `WsSvrManager`.
abstract interface class TransferChannelHost {
  bool get enabled;
  String localPeerIdFor(String peerId);
  bool peerSupportsTransferChannel(String peerId);
  TransferConnectionBinding? currentBinding(String peerId);
  String? dialHostFor(String peerId, int generation);

  /// Runs [action] with local `(sendKey, receiveKey)` for `(peerId, generation)`
  /// if that session is still current and authenticated.
  T? withSessionKeys<T>(
    String peerId,
    int generation,
    T Function(Uint8List sendKey, Uint8List receiveKey) action,
  );

  /// Issues a one-time `/transfer` token bound to `(peerId, generation)` and
  /// [sessionId].
  String? issueTransferToken({
    required String peerId,
    required int generation,
    required String sessionId,
    required bool reverse,
  });

  /// Revokes any outstanding `/transfer` tokens for `(peerId, sessionId)`.
  void revokeTransferToken({required String peerId, required String sessionId});

  /// Sends a `TransferChannelControlMessage` on `/chat`.
  Future<bool> sendControl(
    String peerId,
    TransferChannelControlMessage control,
  );

  /// Sends an encoded frame over `/chat` when `/transfer` is unavailable or
  /// fell back for this connection generation.
  Future<bool> sendFallbackOnChat(
    TransferConnectionBinding binding,
    Object payload,
  );

  /// Delivers a validated inbound `/transfer` frame to the business subsystem.
  FutureOr<void> handleInboundFrame(TransferDataInboundFrame frame);

  /// Notifies the host that an established `/transfer` channel dropped
  /// unexpectedly while `/chat` may still be alive.
  void onUnexpectedChannelDrop(
    String peerId,
    int generation,
    TransferChannelKind kind,
  );
}

enum _SlotState { idle, opening, open, fallback }

final class _PeerKindKey {
  const _PeerKindKey(this.peerId, this.kind);

  final String peerId;
  final TransferChannelKind kind;

  @override
  bool operator ==(Object other) =>
      other is _PeerKindKey && other.peerId == peerId && other.kind == kind;

  @override
  int get hashCode => Object.hash(peerId, kind);
}

final class _PendingTransferClaim {
  const _PendingTransferClaim({
    required this.peerId,
    required this.generation,
    required this.kind,
    required this.sessionId,
    required this.reverse,
  });

  final String peerId;
  final int generation;
  final TransferChannelKind kind;
  final String sessionId;
  final bool reverse;
}

final class _PeerKindSlot {
  _PeerKindSlot(this.generation);

  int generation;
  _SlotState state = _SlotState.idle;
  int? activeChannelId;
  String? pendingSessionId;
  bool pendingIsInitiator = false;
  bool awaitingDialBack = false;
  Completer<int?>? openWaiter;
  Timer? negotiationTimer;

  int inflightSends = 0;
  int inflightBytes = 0;
  final Queue<Completer<void>> sendWaiters = Queue<Completer<void>>();

  void wakeSendWaiters() {
    while (sendWaiters.isNotEmpty) {
      final waiter = sendWaiters.removeFirst();
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}

/// Manages per-peer, per-kind (`bulk` / `browse`) `/transfer` data channels
/// backed by [TransferDataIsolate].
///
/// Enforces:
/// - Independent TCP connections for `bulk` (`fileData`) and `browse`
///   (`browseData` / `browseWrite`) so mount reads never queue behind bulk
///   file data.
/// - Deterministic glare resolution when both sides send `open` concurrently.
/// - Automatic reverse dial-back when the forward worker port is unreachable,
///   and per-generation `/chat` fallback when both sides are unreachable.
/// - Monotonic `channelId` filtering so stale frames from a closed `/transfer`
///   connection under the same `/chat` generation are always discarded.
/// - Bounded in-flight send concurrency (≤ 2 frames when paced) with worker
///   acks delivered strictly after `WebSocket.addStream` completes.
final class TransferChannelManager {
  TransferChannelManager(
    this._host, {
    required TransferClaimBroker Function(TransferChannelManager manager)
    claimBrokerFactory,
    Duration negotiationTimeout = const Duration(seconds: 8),
    Duration dialConnectTimeout = transferChannelConnectTimeout,
  }) : _claimBrokerFactory = claimBrokerFactory,
       _negotiationTimeout = negotiationTimeout,
       _dialConnectTimeout = dialConnectTimeout;

  static const _uuid = Uuid();
  static const int _maxPacedInflightFrames = 2;
  static const int _maxUnpacedInflightFrames = 8;
  static const int _maxUnpacedInflightBytes = 4 * 1024 * 1024;

  final TransferChannelHost _host;
  final TransferClaimBroker Function(TransferChannelManager manager)
  _claimBrokerFactory;
  final Duration _negotiationTimeout;
  final Duration _dialConnectTimeout;

  TransferDataIsolate? _isolate;
  final Map<_PeerKindKey, _PeerKindSlot> _slots =
      <_PeerKindKey, _PeerKindSlot>{};
  final Map<String, _PendingTransferClaim> _pendingClaims =
      <String, _PendingTransferClaim>{};

  int _bulkFramesSent = 0;
  int _browseFramesSent = 0;
  int _bulkFramesReceived = 0;
  int _browseFramesReceived = 0;
  int _staleFramesDropped = 0;

  int get workerPort => _isolate?.port ?? 0;
  bool get isWorkerRunning => _isolate?.isRunning == true;

  /// Diagnostic counters used by tests to verify traffic traveled on
  /// `/transfer` rather than falling back to `/chat`.
  ({
    int bulkSent,
    int browseSent,
    int bulkReceived,
    int browseReceived,
    int staleDropped,
  })
  get stats => (
    bulkSent: _bulkFramesSent,
    browseSent: _browseFramesSent,
    bulkReceived: _bulkFramesReceived,
    browseReceived: _browseFramesReceived,
    staleDropped: _staleFramesDropped,
  );

  /// Starts the transfer worker isolate bound to `WhisperPorts.transferData`
  /// for [mainPort] (or ephemeral port 0 when [mainPort] is 0).
  Future<int> startWorker({required int mainPort}) async {
    if (!_host.enabled) {
      return 0;
    }
    final existing = _isolate;
    if (existing != null && existing.isRunning) {
      return existing.port;
    }
    final isolate = TransferDataIsolate(
      claimBroker: _claimBrokerFactory(this),
      onChannelOpened: _onChannelOpened,
      onChannelClosed: _onChannelClosed,
      onInboundFrame: _onInboundFrame,
    );
    _isolate = isolate;
    final port = await isolate.start(
      preferredPort: WhisperPorts.transferData(mainPort),
    );
    if (port <= 0 && identical(_isolate, isolate)) {
      _isolate = null;
    }
    return port;
  }

  /// Stops the worker isolate and clears all active channel state.
  Future<void> stopWorker() async {
    final isolate = _isolate;
    _isolate = null;
    for (final slot in _slots.values) {
      _resetSlot(slot, newState: _SlotState.idle);
    }
    _slots.clear();
    _pendingClaims.clear();
    await isolate?.close();
  }

  /// Active `channelId` for `(peerId, kind)` if currently open on [generation].
  int? activeChannelIdFor(
    String peerId,
    int generation,
    TransferChannelKind kind,
  ) {
    final slot = _slots[_PeerKindKey(peerId, kind)];
    if (slot == null ||
        slot.generation != generation ||
        slot.state != _SlotState.open) {
      return null;
    }
    return slot.activeChannelId;
  }

  /// Whether `(peerId, generation, kind, channelId)` is still the current
  /// active `/transfer` connection.
  bool isChannelCurrent({
    required String peerId,
    required int generation,
    required TransferChannelKind kind,
    required int channelId,
  }) {
    final active = activeChannelIdFor(peerId, generation, kind);
    return active != null && active == channelId;
  }

  /// Lookup hook called by the main-isolate `TransferClaimBroker` before proof.
  TransferChannelKind? lookupPendingClaimKind(SessionUpgradeClaim claim) {
    final pending = _pendingClaims[claim.sessionId];
    if (pending == null ||
        pending.peerId != claim.peerId ||
        pending.generation != claim.connectionGeneration ||
        pending.reverse != claim.reverse) {
      return null;
    }
    final slot = _slots[_PeerKindKey(claim.peerId, pending.kind)];
    if (slot == null || slot.generation != claim.connectionGeneration) {
      return null;
    }
    if (claim.reverse && !slot.awaitingDialBack) {
      return null;
    }
    return pending.kind;
  }

  /// Consume hook called by `TransferClaimBroker` after proof succeeds.
  bool consumePendingClaim(SessionUpgradeClaim claim) {
    final kind = lookupPendingClaimKind(claim);
    if (kind == null) {
      return false;
    }
    _pendingClaims.remove(claim.sessionId);
    return true;
  }

  /// Sends one encoded `WhisperFrameV3` (`fileData`, `browseData`, or
  /// `browseWrite`) over `(binding.peerId, binding.generation, kind)`.
  ///
  /// Lazily establishes the `/transfer` channel on first use when both peers
  /// support `transferChannelV1`; seamlessly falls back to `/chat` if the peer
  /// does not support it or if both forward dial and reverse dial-back fail.
  Future<bool> sendFrame({
    required TransferConnectionBinding binding,
    required TransferChannelKind kind,
    required Uint8List encodedFrame,
    Object? fallbackPayload,
    bool paced = false,
  }) async {
    if (!_shouldUseTransferChannel(binding)) {
      return _host.sendFallbackOnChat(binding, fallbackPayload ?? encodedFrame);
    }
    final channelId = await _ensureChannel(binding, kind);
    if (channelId == null) {
      if (_host.currentBinding(binding.peerId) != binding) {
        return false;
      }
      return _host.sendFallbackOnChat(binding, fallbackPayload ?? encodedFrame);
    }
    final isolate = _isolate;
    if (isolate == null || !isolate.isRunning) {
      return false;
    }
    final slot = _slotFor(binding.peerId, binding.generation, kind);
    final admitted = await _acquireSendSlot(
      slot,
      channelId: channelId,
      byteLength: encodedFrame.length,
      paced: paced,
    );
    if (!admitted) {
      return false;
    }
    try {
      final sent = await isolate.sendFrame(
        channelId: channelId,
        encodedFrame: encodedFrame,
      );
      if (sent) {
        if (kind == TransferChannelKind.bulk) {
          _bulkFramesSent += 1;
        } else {
          _browseFramesSent += 1;
        }
      }
      return sent;
    } finally {
      slot.inflightSends = slot.inflightSends > 0 ? slot.inflightSends - 1 : 0;
      slot.inflightBytes = slot.inflightBytes >= encodedFrame.length
          ? slot.inflightBytes - encodedFrame.length
          : 0;
      slot.wakeSendWaiters();
    }
  }

  /// Handles an inbound `TransferChannelControlMessage` from `/chat`.
  Future<void> handleControl({
    required String remotePeerId,
    required int localGeneration,
    required TransferChannelControlMessage control,
  }) async {
    if (!_host.enabled) {
      return;
    }
    final binding = _host.currentBinding(remotePeerId);
    if (binding == null || binding.generation != localGeneration) {
      return;
    }
    switch (control.action) {
      case TransferChannelAction.open:
        await _handleOpen(remotePeerId, localGeneration, control);
      case TransferChannelAction.accept:
        await _handleAccept(remotePeerId, localGeneration, control);
      case TransferChannelAction.dialBack:
        await _handleDialBack(remotePeerId, localGeneration, control);
      case TransferChannelAction.reject:
        _handleReject(remotePeerId, localGeneration, control);
      case TransferChannelAction.close:
        _handleRemoteClose(remotePeerId, localGeneration, control);
    }
  }

  /// Closes `/transfer` channels for [peerId] (all generations, or only those
  /// strictly older than [keepGeneration] when supplied).
  void closePeer(
    String peerId, {
    int? keepGeneration,
    TransferChannelKind? kind,
  }) {
    for (final entry in _slots.entries.toList(growable: false)) {
      if (entry.key.peerId != peerId) continue;
      if (kind != null && entry.key.kind != kind) continue;
      final slot = entry.value;
      if (keepGeneration != null && slot.generation == keepGeneration) {
        continue;
      }
      final oldGen = slot.generation;
      final oldChannel = slot.activeChannelId;
      _resetSlot(slot, newState: _SlotState.idle);
      _slots.remove(entry.key);
      if (oldChannel != null) {
        _isolate?.closeChannel(oldChannel, reason: 'peer_closed');
      } else {
        _isolate?.closePeer(
          peerId,
          connectionGeneration: oldGen,
          kind: entry.key.kind,
          reason: 'peer_closed',
        );
      }
    }
    _pendingClaims.removeWhere(
      (_, claim) =>
          claim.peerId == peerId &&
          (kind == null || claim.kind == kind) &&
          (keepGeneration == null || claim.generation != keepGeneration),
    );
  }

  /// Drops a single active `/transfer` channel in tests to simulate an
  /// abrupt mid-transfer `/transfer` disconnect while `/chat` stays alive.
  void debugCloseActiveChannel(String peerId, TransferChannelKind kind) {
    final slot = _slots[_PeerKindKey(peerId, kind)];
    final channelId = slot?.activeChannelId;
    if (channelId != null) {
      _isolate?.closeChannel(channelId, reason: 'debug_drop');
    }
  }

  bool _shouldUseTransferChannel(TransferConnectionBinding binding) {
    if (!_host.enabled || !isWorkerRunning) {
      return false;
    }
    if (_host.currentBinding(binding.peerId) != binding) {
      return false;
    }
    return _host.peerSupportsTransferChannel(binding.peerId);
  }

  _PeerKindSlot _slotFor(
    String peerId,
    int generation,
    TransferChannelKind kind,
  ) {
    final key = _PeerKindKey(peerId, kind);
    final existing = _slots[key];
    if (existing != null && existing.generation == generation) {
      return existing;
    }
    if (existing != null) {
      final staleChannel = existing.activeChannelId;
      _resetSlot(existing, newState: _SlotState.idle);
      if (staleChannel != null) {
        _isolate?.closeChannel(staleChannel, reason: 'superseded');
      }
    }
    final created = _PeerKindSlot(generation);
    _slots[key] = created;
    return created;
  }

  Future<int?> _ensureChannel(
    TransferConnectionBinding binding,
    TransferChannelKind kind,
  ) async {
    final slot = _slotFor(binding.peerId, binding.generation, kind);
    if (slot.state == _SlotState.open && slot.activeChannelId != null) {
      return slot.activeChannelId;
    }
    if (slot.state == _SlotState.fallback) {
      return null;
    }
    if (slot.state == _SlotState.opening && slot.openWaiter != null) {
      return slot.openWaiter!.future;
    }
    final localPeerId = _host.localPeerIdFor(binding.peerId);
    if (localPeerId.isEmpty) {
      return null;
    }
    final sessionId = _uuid.v4();
    final waiter = Completer<int?>();
    slot
      ..state = _SlotState.opening
      ..pendingSessionId = sessionId
      ..pendingIsInitiator = true
      ..awaitingDialBack = false
      ..openWaiter = waiter;
    _armNegotiationTimer(slot, binding.peerId, kind, sessionId);
    final sent = await _host.sendControl(
      binding.peerId,
      TransferChannelControlMessage(
        action: TransferChannelAction.open,
        kind: kind,
        sessionId: sessionId,
        sourcePeerId: localPeerId,
        sinkPeerId: binding.peerId,
      ),
    );
    if (!sent && slot.pendingSessionId == sessionId) {
      _failToFallback(slot, binding.peerId, sessionId);
    }
    return waiter.future;
  }

  Future<void> _handleOpen(
    String peerId,
    int generation,
    TransferChannelControlMessage control,
  ) async {
    final localPeerId = _host.localPeerIdFor(peerId);
    if (control.sourcePeerId != peerId || control.sinkPeerId != localPeerId) {
      return;
    }
    final slot = _slotFor(peerId, generation, control.kind);
    if (slot.state == _SlotState.open && slot.activeChannelId != null) {
      // Already open on this generation; close stale/duplicate request.
      await _host.sendControl(
        peerId,
        TransferChannelControlMessage(
          action: TransferChannelAction.reject,
          kind: control.kind,
          sessionId: control.sessionId,
          sourcePeerId: peerId,
          sinkPeerId: localPeerId,
          reason: 'already_open',
        ),
      );
      return;
    }
    if (slot.state == _SlotState.opening && slot.pendingIsInitiator) {
      // Glare: deterministic tie-breaker by peerId.
      if (localPeerId.compareTo(peerId) < 0) {
        // We win; keep our outgoing open and ignore the peer's open.
        return;
      }
      // Peer wins: abandon our pending open (preserving openWaiter!) and
      // accept the peer's open instead.
      final lostSession = slot.pendingSessionId;
      if (lostSession != null) {
        _pendingClaims.remove(lostSession);
        _host.revokeTransferToken(peerId: peerId, sessionId: lostSession);
      }
      slot.negotiationTimer?.cancel();
      slot.negotiationTimer = null;
    }
    final port = workerPort;
    final token = port > 0
        ? _host.issueTransferToken(
            peerId: peerId,
            generation: generation,
            sessionId: control.sessionId,
            reverse: false,
          )
        : null;
    if (token == null || port <= 0) {
      await _host.sendControl(
        peerId,
        TransferChannelControlMessage(
          action: TransferChannelAction.reject,
          kind: control.kind,
          sessionId: control.sessionId,
          sourcePeerId: peerId,
          sinkPeerId: localPeerId,
          reason: 'unavailable',
        ),
      );
      if (slot.state == _SlotState.opening) {
        _failToFallback(slot, peerId, control.sessionId);
      }
      return;
    }
    slot
      ..state = _SlotState.opening
      ..pendingSessionId = control.sessionId
      ..pendingIsInitiator = false
      ..awaitingDialBack = false
      ..openWaiter ??= Completer<int?>();
    _pendingClaims[control.sessionId] = _PendingTransferClaim(
      peerId: peerId,
      generation: generation,
      kind: control.kind,
      sessionId: control.sessionId,
      reverse: false,
    );
    _armNegotiationTimer(slot, peerId, control.kind, control.sessionId);
    final sent = await _host.sendControl(
      peerId,
      TransferChannelControlMessage(
        action: TransferChannelAction.accept,
        kind: control.kind,
        sessionId: control.sessionId,
        sourcePeerId: peerId,
        sinkPeerId: localPeerId,
        transportToken: token,
        transferPort: port,
      ),
    );
    if (!sent && slot.pendingSessionId == control.sessionId) {
      _failToFallback(slot, peerId, control.sessionId);
    }
  }

  Future<void> _handleAccept(
    String peerId,
    int generation,
    TransferChannelControlMessage control,
  ) async {
    final localPeerId = _host.localPeerIdFor(peerId);
    if (control.sourcePeerId != localPeerId || control.sinkPeerId != peerId) {
      return;
    }
    final slot = _slots[_PeerKindKey(peerId, control.kind)];
    if (slot == null ||
        slot.generation != generation ||
        slot.state != _SlotState.opening ||
        !slot.pendingIsInitiator ||
        slot.pendingSessionId != control.sessionId) {
      return;
    }
    final host = _host.dialHostFor(peerId, generation);
    final isolate = _isolate;
    if (host == null || isolate == null || !isolate.isRunning) {
      _failToFallback(slot, peerId, control.sessionId);
      return;
    }
    final dialFuture = _host.withSessionKeys(
      peerId,
      generation,
      (sendKey, receiveKey) => isolate.dial(
        host: host,
        port: control.transferPort,
        sessionId: control.sessionId,
        token: control.transportToken,
        localPeerId: localPeerId,
        remotePeerId: peerId,
        connectionGeneration: generation,
        kind: control.kind,
        reverse: false,
        sendKey: sendKey,
        receiveKey: receiveKey,
        connectTimeout: _dialConnectTimeout,
      ),
    );
    if (dialFuture == null) {
      _failToFallback(slot, peerId, control.sessionId);
      return;
    }
    final result = await dialFuture;
    if (result.ok && result.channelId != null) {
      // _onChannelOpened handles promotion to open; complete here too in case
      // _DialResult arrived first.
      _promoteOpened(
        peerId: peerId,
        generation: generation,
        kind: control.kind,
        sessionId: control.sessionId,
        channelId: result.channelId!,
      );
      return;
    }
    if (slot.generation != generation ||
        slot.state != _SlotState.opening ||
        slot.pendingSessionId != control.sessionId) {
      return;
    }
    if (result.unreachable && workerPort > 0) {
      await _requestDialBack(
        slot: slot,
        peerId: peerId,
        localPeerId: localPeerId,
        generation: generation,
        kind: control.kind,
        sessionId: control.sessionId,
      );
      return;
    }
    _failToFallback(slot, peerId, control.sessionId);
  }

  Future<void> _requestDialBack({
    required _PeerKindSlot slot,
    required String peerId,
    required String localPeerId,
    required int generation,
    required TransferChannelKind kind,
    required String sessionId,
  }) async {
    final port = workerPort;
    final token = port > 0
        ? _host.issueTransferToken(
            peerId: peerId,
            generation: generation,
            sessionId: sessionId,
            reverse: true,
          )
        : null;
    if (token == null || port <= 0) {
      _failToFallback(slot, peerId, sessionId);
      return;
    }
    slot.awaitingDialBack = true;
    _pendingClaims[sessionId] = _PendingTransferClaim(
      peerId: peerId,
      generation: generation,
      kind: kind,
      sessionId: sessionId,
      reverse: true,
    );
    _armNegotiationTimer(slot, peerId, kind, sessionId);
    final sent = await _host.sendControl(
      peerId,
      TransferChannelControlMessage(
        action: TransferChannelAction.dialBack,
        kind: kind,
        sessionId: sessionId,
        sourcePeerId: localPeerId,
        sinkPeerId: peerId,
        transportToken: token,
        transferPort: port,
      ),
    );
    if (!sent && slot.pendingSessionId == sessionId) {
      _failToFallback(slot, peerId, sessionId);
    }
  }

  Future<void> _handleDialBack(
    String peerId,
    int generation,
    TransferChannelControlMessage control,
  ) async {
    final localPeerId = _host.localPeerIdFor(peerId);
    if (control.sourcePeerId != peerId || control.sinkPeerId != localPeerId) {
      return;
    }
    final slot = _slots[_PeerKindKey(peerId, control.kind)];
    if (slot == null ||
        slot.generation != generation ||
        slot.state != _SlotState.opening ||
        slot.pendingIsInitiator ||
        slot.pendingSessionId != control.sessionId) {
      return;
    }
    // One way in per session: revoke our forward token before dialling back.
    _pendingClaims.remove(control.sessionId);
    _host.revokeTransferToken(peerId: peerId, sessionId: control.sessionId);
    final host = _host.dialHostFor(peerId, generation);
    final isolate = _isolate;
    if (host == null || isolate == null || !isolate.isRunning) {
      _failToFallback(slot, peerId, control.sessionId);
      return;
    }
    final dialFuture = _host.withSessionKeys(
      peerId,
      generation,
      (sendKey, receiveKey) => isolate.dial(
        host: host,
        port: control.transferPort,
        sessionId: control.sessionId,
        token: control.transportToken,
        localPeerId: localPeerId,
        remotePeerId: peerId,
        connectionGeneration: generation,
        kind: control.kind,
        reverse: true,
        sendKey: sendKey,
        receiveKey: receiveKey,
        connectTimeout: _dialConnectTimeout,
      ),
    );
    if (dialFuture == null) {
      _failToFallback(slot, peerId, control.sessionId);
      return;
    }
    final result = await dialFuture;
    if (result.ok && result.channelId != null) {
      _promoteOpened(
        peerId: peerId,
        generation: generation,
        kind: control.kind,
        sessionId: control.sessionId,
        channelId: result.channelId!,
      );
      return;
    }
    if (slot.generation == generation &&
        slot.state == _SlotState.opening &&
        slot.pendingSessionId == control.sessionId) {
      _failToFallback(slot, peerId, control.sessionId);
    }
  }

  void _handleReject(
    String peerId,
    int generation,
    TransferChannelControlMessage control,
  ) {
    final slot = _slots[_PeerKindKey(peerId, control.kind)];
    if (slot == null ||
        slot.generation != generation ||
        slot.pendingSessionId != control.sessionId) {
      return;
    }
    if (control.reason == 'already_open' &&
        slot.state == _SlotState.open &&
        slot.activeChannelId != null) {
      return;
    }
    _failToFallback(slot, peerId, control.sessionId);
  }

  void _handleRemoteClose(
    String peerId,
    int generation,
    TransferChannelControlMessage control,
  ) {
    final slot = _slots[_PeerKindKey(peerId, control.kind)];
    if (slot == null || slot.generation != generation) {
      return;
    }
    final channelId = slot.activeChannelId;
    _resetSlot(slot, newState: _SlotState.idle);
    if (channelId != null) {
      _isolate?.closeChannel(channelId, reason: 'remote_control_close');
    }
  }

  void _onChannelOpened(TransferDataChannelOpened event) {
    _promoteOpened(
      peerId: event.peerId,
      generation: event.connectionGeneration,
      kind: event.kind,
      sessionId: event.sessionId,
      channelId: event.channelId,
    );
  }

  void _promoteOpened({
    required String peerId,
    required int generation,
    required TransferChannelKind kind,
    required String sessionId,
    required int channelId,
  }) {
    final binding = _host.currentBinding(peerId);
    if (binding == null || binding.generation != generation) {
      _isolate?.closeChannel(channelId, reason: 'stale_generation');
      return;
    }
    final slot = _slotFor(peerId, generation, kind);
    if (slot.state == _SlotState.open && slot.activeChannelId == channelId) {
      return;
    }
    final previousChannel = slot.activeChannelId;
    slot.negotiationTimer?.cancel();
    slot.negotiationTimer = null;
    slot
      ..state = _SlotState.open
      ..activeChannelId = channelId
      ..pendingSessionId = null
      ..pendingIsInitiator = false
      ..awaitingDialBack = false;
    _pendingClaims.remove(sessionId);
    final waiter = slot.openWaiter;
    slot.openWaiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(channelId);
    }
    if (previousChannel != null && previousChannel != channelId) {
      _isolate?.closeChannel(previousChannel, reason: 'replaced');
    }
  }

  void _onChannelClosed(TransferDataChannelClosed event) {
    final slot = _slots[_PeerKindKey(event.peerId, event.kind)];
    if (slot == null ||
        slot.generation != event.connectionGeneration ||
        slot.activeChannelId != event.channelId) {
      return;
    }
    // Clear activeChannelId immediately so any queued stale frames from this
    // channelId are dropped before reaching business engines.
    _resetSlot(slot, newState: _SlotState.idle);
    final current = _host.currentBinding(event.peerId);
    if (!event.expected &&
        current != null &&
        current.generation == event.connectionGeneration) {
      _host.onUnexpectedChannelDrop(
        event.peerId,
        event.connectionGeneration,
        event.kind,
      );
    }
  }

  FutureOr<void> _onInboundFrame(TransferDataInboundFrame frame) {
    if (!isChannelCurrent(
      peerId: frame.peerId,
      generation: frame.connectionGeneration,
      kind: frame.kind,
      channelId: frame.channelId,
    )) {
      _staleFramesDropped += 1;
      return null;
    }
    if (frame.kind == TransferChannelKind.bulk) {
      _bulkFramesReceived += 1;
    } else {
      _browseFramesReceived += 1;
    }
    return _host.handleInboundFrame(frame);
  }

  Future<bool> _acquireSendSlot(
    _PeerKindSlot slot, {
    required int channelId,
    required int byteLength,
    required bool paced,
  }) async {
    while (true) {
      if (slot.state != _SlotState.open || slot.activeChannelId != channelId) {
        return false;
      }
      final hasRoom = paced
          ? slot.inflightSends < _maxPacedInflightFrames
          : (slot.inflightSends == 0 ||
                (slot.inflightSends < _maxUnpacedInflightFrames &&
                    slot.inflightBytes + byteLength <=
                        _maxUnpacedInflightBytes));
      if (hasRoom) {
        slot.inflightSends += 1;
        slot.inflightBytes += byteLength;
        return true;
      }
      final waiter = Completer<void>();
      slot.sendWaiters.add(waiter);
      await waiter.future;
    }
  }

  void _armNegotiationTimer(
    _PeerKindSlot slot,
    String peerId,
    TransferChannelKind kind,
    String sessionId,
  ) {
    slot.negotiationTimer?.cancel();
    slot.negotiationTimer = Timer(_negotiationTimeout, () {
      if (slot.state == _SlotState.opening &&
          slot.pendingSessionId == sessionId) {
        _failToFallback(slot, peerId, sessionId);
      }
    });
  }

  void _failToFallback(_PeerKindSlot slot, String peerId, String sessionId) {
    _pendingClaims.remove(sessionId);
    _host.revokeTransferToken(peerId: peerId, sessionId: sessionId);
    _resetSlot(slot, newState: _SlotState.fallback);
  }

  void _resetSlot(_PeerKindSlot slot, {required _SlotState newState}) {
    slot.negotiationTimer?.cancel();
    slot.negotiationTimer = null;
    final pendingSession = slot.pendingSessionId;
    if (pendingSession != null) {
      _pendingClaims.remove(pendingSession);
    }
    slot
      ..state = newState
      ..activeChannelId = null
      ..pendingSessionId = null
      ..pendingIsInitiator = false
      ..awaitingDialBack = false;
    final waiter = slot.openWaiter;
    slot.openWaiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(null);
    }
    slot.wakeSendWaiters();
  }
}
