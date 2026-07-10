import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_failure_reason.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

typedef RemoteInputPeerControlSender = void Function(
  String peerId,
  RemoteInputControlMessage control,
);
typedef RemoteInputWorkspaceSessionIdFactory = String Function();

enum RemoteInputWorkspaceRole {
  idle,
  controller,
  controlled,
}

enum RemoteInputWorkspaceStatus {
  idle,
  offering,
  armed,
  active,
  failed,
}

enum RemoteInputWorkspaceTargetStatus {
  offering,
  connected,
  failed,
  stopped,
}

enum RemoteInputWorkspaceDiagnosticKind {
  transportClosed,
  platformDiagnostic,
  platformError,
}

class RemoteInputWorkspaceTargetRequest {
  const RemoteInputWorkspaceTargetRequest({
    required this.peerId,
    required this.peerName,
    required this.host,
    required this.port,
    required this.layoutEdge,
    required this.releaseHotkey,
    required this.isMutuallyTrusted,
    required this.remoteCanInject,
    this.path = '/input',
    this.sourceDisplayId = '',
    this.sourceEdge,
    this.sourceSegmentStart = 0,
    this.sourceSegmentEnd = 0,
    this.sinkDisplayId = '',
    this.sinkEdge,
    this.sinkSegmentStart = 0,
    this.sinkSegmentEnd = 0,
    this.edgeMappings = const <RemoteInputEdgeMapping>[],
  });

  final String peerId;
  final String peerName;
  final String host;
  final int port;
  final RemoteInputEdge layoutEdge;
  final String releaseHotkey;
  final bool isMutuallyTrusted;
  final bool remoteCanInject;
  final String path;
  final String sourceDisplayId;
  final RemoteInputEdge? sourceEdge;
  final int sourceSegmentStart;
  final int sourceSegmentEnd;
  final String sinkDisplayId;
  final RemoteInputEdge? sinkEdge;
  final int sinkSegmentStart;
  final int sinkSegmentEnd;
  final List<RemoteInputEdgeMapping> edgeMappings;
}

class RemoteInputWorkspaceTargetSnapshot {
  const RemoteInputWorkspaceTargetSnapshot({
    required this.peerId,
    required this.peerName,
    required this.sessionId,
    required this.status,
    this.errorMessage = '',
  });

  final String peerId;
  final String peerName;
  final String sessionId;
  final RemoteInputWorkspaceTargetStatus status;
  final String errorMessage;

  bool get isLive =>
      status == RemoteInputWorkspaceTargetStatus.offering ||
      status == RemoteInputWorkspaceTargetStatus.connected;

  bool get isConnected => status == RemoteInputWorkspaceTargetStatus.connected;

  RemoteInputWorkspaceTargetSnapshot copyWith({
    String? sessionId,
    RemoteInputWorkspaceTargetStatus? status,
    String? errorMessage,
  }) {
    return RemoteInputWorkspaceTargetSnapshot(
      peerId: peerId,
      peerName: peerName,
      sessionId: sessionId ?? this.sessionId,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class RemoteInputWorkspaceSnapshot {
  const RemoteInputWorkspaceSnapshot({
    required this.role,
    required this.status,
    this.workspaceSessionId = '',
    this.sourcePeerId = '',
    this.controllerPeerId = '',
    this.activePeerId = '',
    this.errorMessage = '',
    this.targets = const <String, RemoteInputWorkspaceTargetSnapshot>{},
  });

  const RemoteInputWorkspaceSnapshot.idle()
      : role = RemoteInputWorkspaceRole.idle,
        status = RemoteInputWorkspaceStatus.idle,
        workspaceSessionId = '',
        sourcePeerId = '',
        controllerPeerId = '',
        activePeerId = '',
        errorMessage = '',
        targets = const <String, RemoteInputWorkspaceTargetSnapshot>{};

  final RemoteInputWorkspaceRole role;
  final RemoteInputWorkspaceStatus status;
  final String workspaceSessionId;
  final String sourcePeerId;
  final String controllerPeerId;
  final String activePeerId;
  final String errorMessage;
  final Map<String, RemoteInputWorkspaceTargetSnapshot> targets;

  bool get isControllerLive =>
      role == RemoteInputWorkspaceRole.controller &&
      status != RemoteInputWorkspaceStatus.idle &&
      status != RemoteInputWorkspaceStatus.failed;

  bool get isControlledLive =>
      role == RemoteInputWorkspaceRole.controlled &&
      status != RemoteInputWorkspaceStatus.idle &&
      status != RemoteInputWorkspaceStatus.failed;

  Iterable<String> get connectedTargetPeerIds => targets.values
      .where((target) => target.isConnected)
      .map((target) => target.peerId);

  Iterable<String> get liveTargetPeerIds => targets.values
      .where((target) => target.isLive)
      .map((target) => target.peerId);

  RemoteInputWorkspaceSnapshot copyWith({
    RemoteInputWorkspaceRole? role,
    RemoteInputWorkspaceStatus? status,
    String? workspaceSessionId,
    String? sourcePeerId,
    String? controllerPeerId,
    String? activePeerId,
    String? errorMessage,
    Map<String, RemoteInputWorkspaceTargetSnapshot>? targets,
  }) {
    return RemoteInputWorkspaceSnapshot(
      role: role ?? this.role,
      status: status ?? this.status,
      workspaceSessionId: workspaceSessionId ?? this.workspaceSessionId,
      sourcePeerId: sourcePeerId ?? this.sourcePeerId,
      controllerPeerId: controllerPeerId ?? this.controllerPeerId,
      activePeerId: activePeerId ?? this.activePeerId,
      errorMessage: errorMessage ?? this.errorMessage,
      targets: targets ?? this.targets,
    );
  }
}

class RemoteInputWorkspaceLayoutValidationResult {
  const RemoteInputWorkspaceLayoutValidationResult({
    this.conflictingPeerIds = const <String>{},
  });

  final Set<String> conflictingPeerIds;
  bool get hasConflict => conflictingPeerIds.isNotEmpty;
}

class RemoteInputWorkspaceLayoutValidator {
  const RemoteInputWorkspaceLayoutValidator._();

  static RemoteInputWorkspaceLayoutValidationResult validateTargets(
    List<RemoteInputWorkspaceTargetRequest> targets,
  ) {
    final segments = <_WorkspaceLayoutSegment>[];
    for (final target in targets) {
      for (final mapping in _mappingsForTarget(target)) {
        segments.add(
          _WorkspaceLayoutSegment(
            peerId: target.peerId,
            displayId: mapping.sourceDisplayId,
            edge: mapping.sourceEdge,
            start: mapping.sourceSegmentStart,
            end: mapping.sourceSegmentEnd,
          ),
        );
      }
    }
    final conflicts = <String>{};
    final grouped = <String, List<_WorkspaceLayoutSegment>>{};
    for (final segment in segments) {
      grouped.putIfAbsent(segment.key, () => []).add(segment);
    }
    for (final group in grouped.values) {
      group.sort((left, right) => left.start.compareTo(right.start));
      for (var i = 1; i < group.length; i++) {
        final previous = group[i - 1];
        final current = group[i];
        if (current.start < previous.end) {
          conflicts
            ..add(previous.peerId)
            ..add(current.peerId);
        }
      }
    }
    return RemoteInputWorkspaceLayoutValidationResult(
      conflictingPeerIds: conflicts,
    );
  }

  static List<RemoteInputEdgeMapping> _mappingsForTarget(
    RemoteInputWorkspaceTargetRequest target,
  ) {
    if (target.edgeMappings.isNotEmpty) {
      return target.edgeMappings;
    }
    if (target.sourceSegmentEnd <= target.sourceSegmentStart) {
      return const <RemoteInputEdgeMapping>[];
    }
    return [
      RemoteInputEdgeMapping(
        sourceDisplayId: target.sourceDisplayId,
        sourceEdge: target.sourceEdge ?? target.layoutEdge,
        sourceSegmentStart: target.sourceSegmentStart,
        sourceSegmentEnd: target.sourceSegmentEnd,
        sinkDisplayId: target.sinkDisplayId,
        sinkEdge: target.sinkEdge ?? _oppositeEdge(target.layoutEdge),
        sinkSegmentStart: target.sinkSegmentStart,
        sinkSegmentEnd: target.sinkSegmentEnd,
      ),
    ];
  }

  static RemoteInputEdge _oppositeEdge(RemoteInputEdge edge) {
    switch (edge) {
      case RemoteInputEdge.left:
        return RemoteInputEdge.right;
      case RemoteInputEdge.right:
        return RemoteInputEdge.left;
      case RemoteInputEdge.top:
        return RemoteInputEdge.bottom;
      case RemoteInputEdge.bottom:
        return RemoteInputEdge.top;
    }
  }
}

class RemoteInputWorkspaceException implements Exception {
  const RemoteInputWorkspaceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class RemoteInputWorkspaceCoordinator extends ChangeNotifier {
  RemoteInputWorkspaceCoordinator({
    RemoteInputManager? manager,
    RemoteInputPlatform? platform,
    RemoteInputTransportFactory? transportFactory,
    RemoteInputWorkspaceSessionIdFactory? workspaceSessionIdFactory,
  })  : _manager = manager ?? RemoteInputManager(),
        _platform = platform ?? RemoteInputCoordinator.shared.platform,
        _transportFactory = transportFactory,
        _workspaceSessionIdFactory =
            workspaceSessionIdFactory ?? const Uuid().v4;

  static final RemoteInputWorkspaceCoordinator shared =
      RemoteInputWorkspaceCoordinator(
    platform: RemoteInputCoordinator.shared.platform,
  );

  final RemoteInputManager _manager;
  final RemoteInputPlatform _platform;
  final RemoteInputTransportFactory? _transportFactory;
  final RemoteInputWorkspaceSessionIdFactory _workspaceSessionIdFactory;

  RemoteInputWorkspaceSnapshot _snapshot =
      const RemoteInputWorkspaceSnapshot.idle();
  final Map<String, _RemoteInputWorkspaceTargetRuntime> _targets =
      <String, _RemoteInputWorkspaceTargetRuntime>{};
  StreamSubscription<RemoteInputPacketFrame>? _inputSubscription;
  StreamSubscription<PlatformRemoteInputRelease>? _releaseSubscription;
  StreamSubscription<PlatformRemoteInputError>? _errorSubscription;
  StreamSubscription<PlatformRemoteInputDiagnostic>? _diagnosticSubscription;
  RemoteInputPeerControlSender? _sendControlTo;

  RemoteInputWorkspaceSnapshot get snapshot => _snapshot;

  bool get isControllerLive => _snapshot.isControllerLive;

  void _traceWorkspace(
    RemoteInputWorkspaceDiagnosticKind kind, {
    RemoteInputFailureReason? reason,
  }) {
    if (kReleaseMode &&
        Platform.environment['WHISPER_REMOTE_INPUT_TRACE'] != '1') {
      return;
    }
    privacyLog.event(
      PrivacyEvent.remoteInputDiagnostic,
      <PrivacyField, Object>{
        PrivacyField.kind: kind,
        if (reason != null) PrivacyField.reason: reason,
      },
    );
  }

  Future<void> startControllerWorkspace({
    required String sourcePeerId,
    required List<RemoteInputWorkspaceTargetRequest> targets,
    required RemoteInputPeerControlSender sendControlTo,
  }) async {
    if (targets.isEmpty) {
      throw const RemoteInputWorkspaceException(
        'Select at least one remote input target',
      );
    }
    final invalidTarget = targets.where((target) {
      return !target.isMutuallyTrusted || !target.remoteCanInject;
    }).firstOrNull;
    if (invalidTarget != null) {
      throw RemoteInputWorkspaceException(
        !invalidTarget.isMutuallyTrusted
            ? 'Remote input requires mutual trust'
            : 'Peer does not support remote input',
      );
    }
    final validation =
        RemoteInputWorkspaceLayoutValidator.validateTargets(targets);
    if (validation.hasConflict) {
      throw RemoteInputWorkspaceException(
        'Remote input target edges overlap: '
        '${validation.conflictingPeerIds.join(', ')}',
      );
    }

    await stopControllerWorkspace(
      sendControlTo: _sendControlTo ?? sendControlTo,
    );
    final workspaceSessionId = _workspaceSessionIdFactory();
    _sendControlTo = sendControlTo;
    _targets.clear();
    final snapshots = <String, RemoteInputWorkspaceTargetSnapshot>{};
    for (final target in targets) {
      final routedMappings = _routedMappings(
        workspaceSessionId: workspaceSessionId,
        target: target,
      );
      final primaryMapping =
          routedMappings.isNotEmpty ? routedMappings.first : null;
      final offer = _manager.createOffer(
        sourcePeerId: sourcePeerId,
        sinkPeerId: target.peerId,
        layoutEdge: primaryMapping?.sourceEdge ?? target.layoutEdge,
        releaseHotkey: target.releaseHotkey,
        sourceDisplayId:
            primaryMapping?.sourceDisplayId ?? target.sourceDisplayId,
        sourceEdge: primaryMapping?.sourceEdge ?? target.sourceEdge,
        sourceSegmentStart:
            primaryMapping?.sourceSegmentStart ?? target.sourceSegmentStart,
        sourceSegmentEnd:
            primaryMapping?.sourceSegmentEnd ?? target.sourceSegmentEnd,
        sinkDisplayId: primaryMapping?.sinkDisplayId ?? target.sinkDisplayId,
        sinkEdge: primaryMapping?.sinkEdge ?? target.sinkEdge,
        sinkSegmentStart:
            primaryMapping?.sinkSegmentStart ?? target.sinkSegmentStart,
        sinkSegmentEnd: primaryMapping?.sinkSegmentEnd ?? target.sinkSegmentEnd,
        edgeMappings: routedMappings,
      );
      _targets[target.peerId] = _RemoteInputWorkspaceTargetRuntime(
        request: target,
        offer: offer,
        routedMappings: routedMappings,
      );
      snapshots[target.peerId] = RemoteInputWorkspaceTargetSnapshot(
        peerId: target.peerId,
        peerName: target.peerName,
        sessionId: offer.sessionId,
        status: RemoteInputWorkspaceTargetStatus.offering,
      );
      sendControlTo(target.peerId, offer);
    }
    _setSnapshot(
      RemoteInputWorkspaceSnapshot(
        role: RemoteInputWorkspaceRole.controller,
        status: RemoteInputWorkspaceStatus.offering,
        workspaceSessionId: workspaceSessionId,
        sourcePeerId: sourcePeerId,
        targets: snapshots,
      ),
    );
  }

  Future<bool> handleIncomingOfferIfBusy(
    RemoteInputControlMessage offer, {
    required String localPeerId,
    required RemoteInputPeerControlSender sendControlTo,
  }) async {
    if (offer.action != RemoteInputControlAction.offer ||
        offer.sinkPeerId != localPeerId ||
        !_snapshot.isControllerLive) {
      return false;
    }
    sendControlTo(
      offer.sourcePeerId,
      RemoteInputControlMessage(
        action: RemoteInputControlAction.reject,
        sessionId: offer.sessionId,
        sourcePeerId: offer.sourcePeerId,
        sinkPeerId: offer.sinkPeerId,
        errorMessage: RemoteInputFailureReason.busy.name,
      ),
    );
    return true;
  }

  Future<bool> handleControlMessage(
    RemoteInputControlMessage message, {
    required String localPeerId,
    required String remoteHost,
    required int remotePort,
    required RemoteInputPeerControlSender sendControlTo,
    Uint8List? mediaSendKey,
  }) async {
    _sendControlTo = sendControlTo;
    switch (message.action) {
      case RemoteInputControlAction.accept:
        return _handleAccept(
          message,
          localPeerId: localPeerId,
          remoteHost: remoteHost,
          remotePort: remotePort,
          mediaSendKey: mediaSendKey,
        );
      case RemoteInputControlAction.release:
        return _handleRelease(message);
      case RemoteInputControlAction.stop:
      case RemoteInputControlAction.reject:
        return _handleStopOrReject(message);
      case RemoteInputControlAction.error:
        return _handleError(message);
      case RemoteInputControlAction.offer:
        return false;
    }
  }

  Future<void> handlePeerDisconnected(String peerId) async {
    if (peerId.isEmpty ||
        _snapshot.role != RemoteInputWorkspaceRole.controller) {
      return;
    }
    final target = _targets[peerId];
    if (target == null) {
      return;
    }
    await _closeControllerTarget(
      target,
      terminalStatus: RemoteInputWorkspaceStatus.idle,
      errorMessage: RemoteInputFailureReason.transport.name,
    );
  }

  Future<void> stopControllerWorkspace({
    RemoteInputPeerControlSender? sendControlTo,
  }) async {
    final sender = sendControlTo ?? _sendControlTo;
    final currentWorkspaceSessionId = _snapshot.workspaceSessionId;
    if (_snapshot.role == RemoteInputWorkspaceRole.controller) {
      for (final target in _targets.values) {
        if (target.snapshot.isLive && sender != null) {
          sender(
            target.request.peerId,
            RemoteInputControlMessage(
              action: RemoteInputControlAction.stop,
              sessionId: target.offer.sessionId,
              sourcePeerId: target.offer.sourcePeerId,
              sinkPeerId: target.offer.sinkPeerId,
            ),
          );
        }
      }
    }
    await _disposeControllerRuntime(
      workspaceSessionId: currentWorkspaceSessionId,
    );
    _setSnapshot(const RemoteInputWorkspaceSnapshot.idle());
  }

  Future<bool> _handleAccept(
    RemoteInputControlMessage accept, {
    required String localPeerId,
    required String remoteHost,
    required int remotePort,
    Uint8List? mediaSendKey,
  }) async {
    if (accept.sourcePeerId != localPeerId ||
        _snapshot.role != RemoteInputWorkspaceRole.controller) {
      return false;
    }
    final target = _targetForSession(accept.sessionId);
    if (target == null) {
      return false;
    }
    _manager.handleControlMessage(accept);
    final path = accept.path.isNotEmpty ? accept.path : target.offer.path;
    final uri = buildPeerPacketUri(
      host: remoteHost.isNotEmpty ? remoteHost : target.request.host,
      port: remotePort > 0 ? remotePort : target.request.port,
      path: path,
      queryParameters: <String, String>{
        if (accept.transportToken.isNotEmpty) 'session': accept.sessionId,
        if (accept.transportToken.isNotEmpty) 'token': accept.transportToken,
      },
    );
    final transportFactory = _transportFactory;
    if (transportFactory != null) {
      target.transport = await transportFactory(uri);
    } else {
      if (accept.transportToken.isEmpty || mediaSendKey == null) {
        throw StateError(
            'authenticated remote input workspace context missing');
      }
      target.transport = await RemoteInputWebSocketPacketTransport.connect(
        uri,
        mediaMacKey: mediaSendKey,
        sessionId: accept.sessionId,
      );
    }
    target.transportDoneSubscription = _listenForTargetTransportDone(target);
    target.snapshot = target.snapshot.copyWith(
      status: RemoteInputWorkspaceTargetStatus.connected,
      errorMessage: '',
    );
    await _refreshCapture();
    _publishTargets(statusFallback: RemoteInputWorkspaceStatus.armed);
    return true;
  }

  Future<bool> _handleRelease(RemoteInputControlMessage message) async {
    final target = _targetForSession(message.sessionId);
    if (target == null ||
        _snapshot.role != RemoteInputWorkspaceRole.controller ||
        message.releaseReason != 'edge') {
      return false;
    }
    await _platform.pauseCapture(
      sessionId: _snapshot.workspaceSessionId,
      releaseSequence: message.releaseSequence,
      releaseActivationSequence: message.releaseActivationSequence,
      releaseEdgeUnit: message.releaseEdgeUnit,
      displayId: message.sourceDisplayId,
      edge: message.sourceEdge,
      segmentStart: message.sourceSegmentStart,
      segmentEnd: message.sourceSegmentEnd,
      routeId: message.routeId,
    );
    _setSnapshot(
      _snapshot.copyWith(
        status: RemoteInputWorkspaceStatus.armed,
        activePeerId: '',
      ),
    );
    return true;
  }

  Future<bool> _handleStopOrReject(RemoteInputControlMessage message) async {
    final target = _targetForSession(message.sessionId);
    if (target == null) {
      return false;
    }
    await _releaseCaptureForActiveTargetIfNeeded(target);
    await target.transportDoneSubscription?.cancel();
    target.transportDoneSubscription = null;
    await target.transport?.close();
    target.transport = null;
    _manager.stopSession(message.sessionId);
    final stableError = message.action == RemoteInputControlAction.reject
        ? remoteInputFailureReasonFromWire(message.errorMessage).name
        : '';
    target.snapshot = target.snapshot.copyWith(
      status: RemoteInputWorkspaceTargetStatus.stopped,
      errorMessage: stableError,
    );
    await _publishAfterTargetClosed(
      terminalStatus: RemoteInputWorkspaceStatus.idle,
      errorMessage: stableError,
    );
    return true;
  }

  Future<bool> _handleError(RemoteInputControlMessage message) async {
    final target = _targetForSession(message.sessionId);
    if (target == null) {
      return false;
    }
    final failureReason =
        remoteInputFailureReasonFromWire(message.errorMessage);
    await _releaseCaptureForActiveTargetIfNeeded(target);
    await target.transportDoneSubscription?.cancel();
    target.transportDoneSubscription = null;
    await target.transport?.close();
    target.transport = null;
    target.snapshot = target.snapshot.copyWith(
      status: RemoteInputWorkspaceTargetStatus.failed,
      errorMessage: failureReason.name,
    );
    await _publishAfterTargetClosed(
      terminalStatus: RemoteInputWorkspaceStatus.failed,
      errorMessage: failureReason.name,
    );
    return true;
  }

  Future<void> _publishAfterTargetClosed({
    required RemoteInputWorkspaceStatus terminalStatus,
    String errorMessage = '',
  }) async {
    final hasConnectedTarget =
        _targets.values.any((target) => target.snapshot.isConnected);
    final hasLiveTarget =
        _targets.values.any((target) => target.snapshot.isLive);
    if (!hasLiveTarget) {
      final terminalSnapshot = terminalStatus == RemoteInputWorkspaceStatus.idle
          ? const RemoteInputWorkspaceSnapshot.idle()
          : _snapshot.copyWith(
              status: terminalStatus,
              activePeerId: '',
              errorMessage: errorMessage,
              targets: _snapshotTargets(),
            );
      await _disposeControllerRuntime(
        workspaceSessionId: _snapshot.workspaceSessionId,
      );
      _setSnapshot(terminalSnapshot);
      return;
    }
    if (!hasConnectedTarget) {
      await _platform.stopCapture(sessionId: _snapshot.workspaceSessionId);
      _setSnapshot(
        _snapshot.copyWith(
          status: RemoteInputWorkspaceStatus.offering,
          activePeerId: '',
          errorMessage: errorMessage,
          targets: _snapshotTargets(),
        ),
      );
      return;
    }
    await _refreshCapture();
    _publishTargets(
      statusFallback: RemoteInputWorkspaceStatus.armed,
      errorMessage: errorMessage,
    );
  }

  Future<void> _refreshCapture() async {
    final connectedTargets = _targets.values
        .where((target) => target.snapshot.isConnected)
        .toList(growable: false);
    if (connectedTargets.isEmpty) {
      return;
    }
    _ensureSubscriptions();
    final mappings = connectedTargets
        .expand((target) => target.routedMappings)
        .toList(growable: false);
    final primaryMapping = mappings.isNotEmpty ? mappings.first : null;
    final primaryTarget = connectedTargets.first;
    await _platform.startCapture(
      sessionId: _snapshot.workspaceSessionId,
      edge: primaryMapping?.sourceEdge ?? primaryTarget.request.layoutEdge,
      releaseHotkey: primaryTarget.request.releaseHotkey,
      displayId: primaryMapping?.sourceDisplayId ??
          primaryTarget.request.sourceDisplayId,
      segmentStart: primaryMapping?.sourceSegmentStart ??
          primaryTarget.request.sourceSegmentStart,
      segmentEnd: primaryMapping?.sourceSegmentEnd ??
          primaryTarget.request.sourceSegmentEnd,
      edgeMappings: mappings,
    );
  }

  StreamSubscription<void>? _listenForTargetTransportDone(
    _RemoteInputWorkspaceTargetRuntime target,
  ) {
    final transport = target.transport;
    if (transport is! RemoteInputObservablePacketTransport) {
      return null;
    }
    return transport.done.listen((_) {
      if (_snapshot.role != RemoteInputWorkspaceRole.controller ||
          _targets[target.request.peerId] != target ||
          !target.snapshot.isConnected) {
        return;
      }
      _traceWorkspace(RemoteInputWorkspaceDiagnosticKind.transportClosed);
      unawaited(_handleTargetTransportClosed(target));
    });
  }

  Future<void> _handleTargetTransportClosed(
    _RemoteInputWorkspaceTargetRuntime target,
  ) async {
    await _closeControllerTarget(
      target,
      terminalStatus: RemoteInputWorkspaceStatus.idle,
      errorMessage: RemoteInputFailureReason.transport.name,
    );
  }

  Future<void> _closeControllerTarget(
    _RemoteInputWorkspaceTargetRuntime target, {
    required RemoteInputWorkspaceStatus terminalStatus,
    required String errorMessage,
  }) async {
    await _releaseCaptureForActiveTargetIfNeeded(target);
    await target.transportDoneSubscription?.cancel();
    target.transportDoneSubscription = null;
    await target.transport?.close();
    target.transport = null;
    _manager.stopSession(target.offer.sessionId);
    target.snapshot = target.snapshot.copyWith(
      status: RemoteInputWorkspaceTargetStatus.stopped,
      errorMessage: errorMessage,
    );
    await _publishAfterTargetClosed(
      terminalStatus: terminalStatus,
      errorMessage: errorMessage,
    );
  }

  Future<void> _releaseCaptureForActiveTargetIfNeeded(
    _RemoteInputWorkspaceTargetRuntime target,
  ) async {
    if (_snapshot.activePeerId != target.request.peerId ||
        _snapshot.workspaceSessionId.isEmpty) {
      return;
    }
    final hasOtherConnectedTarget = _targets.values.any(
      (candidate) => candidate != target && candidate.snapshot.isConnected,
    );
    if (!hasOtherConnectedTarget) {
      return;
    }
    await _platform.stopCapture(sessionId: _snapshot.workspaceSessionId);
  }

  void _ensureSubscriptions() {
    _inputSubscription ??= _platform.inputEvents.listen(_handleInputEvent);
    _releaseSubscription ??= _platform.releases.listen((release) {
      if (release.sessionId == _snapshot.workspaceSessionId) {
        unawaited(stopControllerWorkspace());
      }
    });
    _errorSubscription ??= _platform.errors.listen((error) {
      if (error.sessionId == _snapshot.workspaceSessionId) {
        _setSnapshot(
          _snapshot.copyWith(
            status: RemoteInputWorkspaceStatus.failed,
            errorMessage: RemoteInputFailureReason.capture.name,
          ),
        );
        _traceWorkspace(
          RemoteInputWorkspaceDiagnosticKind.platformError,
          reason: RemoteInputFailureReason.capture,
        );
        unawaited(_disposeControllerRuntime(
          workspaceSessionId: _snapshot.workspaceSessionId,
        ));
      }
    });
    _diagnosticSubscription ??= _platform.diagnostics.listen((diagnostic) {
      if (diagnostic.sessionId == _snapshot.workspaceSessionId) {
        _traceWorkspace(RemoteInputWorkspaceDiagnosticKind.platformDiagnostic);
      }
    });
  }

  void _handleInputEvent(RemoteInputPacketFrame event) {
    if (event.sessionId != _snapshot.workspaceSessionId ||
        _snapshot.role != RemoteInputWorkspaceRole.controller) {
      return;
    }
    final target = _targetForPacket(event);
    if (target == null || target.transport == null) {
      return;
    }
    final routed = RemoteInputPacketFrame(
      sessionId: target.offer.sessionId,
      sequence: event.sequence,
      timestampMicros: event.timestampMicros,
      eventType: event.eventType,
      payload: event.payload,
    );
    target.transport!.send(routed);
    final isActiveStart = _isActivationStartPacket(event);
    if (isActiveStart || _snapshot.status == RemoteInputWorkspaceStatus.armed) {
      _setSnapshot(
        _snapshot.copyWith(
          status: RemoteInputWorkspaceStatus.active,
          activePeerId: target.request.peerId,
          targets: _snapshotTargets(),
        ),
      );
    }
  }

  _RemoteInputWorkspaceTargetRuntime? _targetForPacket(
    RemoteInputPacketFrame event,
  ) {
    final payload = _jsonPayload(event);
    if (payload != null && payload['activeStart'] == true) {
      final routeId = payload['routeId'] as String? ?? '';
      final byRoute = routeId.isNotEmpty ? _targetForRouteId(routeId) : null;
      if (byRoute != null) {
        return byRoute;
      }
    }
    if (_snapshot.activePeerId.isNotEmpty) {
      final active = _targets[_snapshot.activePeerId];
      if (active?.snapshot.isConnected == true) {
        return active;
      }
    }
    return null;
  }

  _RemoteInputWorkspaceTargetRuntime? _targetForRouteId(String routeId) {
    for (final target in _targets.values) {
      for (final mapping in target.routedMappings) {
        if (mapping.effectiveRouteId == routeId) {
          return target;
        }
      }
    }
    return null;
  }

  _RemoteInputWorkspaceTargetRuntime? _targetForSession(String sessionId) {
    for (final target in _targets.values) {
      if (target.offer.sessionId == sessionId) {
        return target;
      }
    }
    return null;
  }

  bool _isActivationStartPacket(RemoteInputPacketFrame packet) {
    if (packet.eventType != RemoteInputEventType.mouseMove) {
      return false;
    }
    final payload = _jsonPayload(packet);
    return payload != null && payload['activeStart'] == true;
  }

  Map<String, dynamic>? _jsonPayload(RemoteInputPacketFrame packet) {
    try {
      final payload = jsonDecode(utf8.decode(packet.payload));
      if (payload is Map<String, dynamic>) {
        return payload;
      }
      if (payload is Map) {
        return Map<String, dynamic>.from(payload);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  List<RemoteInputEdgeMapping> _routedMappings({
    required String workspaceSessionId,
    required RemoteInputWorkspaceTargetRequest target,
  }) {
    final mappings =
        RemoteInputWorkspaceLayoutValidator._mappingsForTarget(target);
    return mappings
        .map(
          (mapping) => RemoteInputEdgeMapping(
            routeId: [
              workspaceSessionId,
              target.peerId,
              mapping.effectiveRouteId,
            ].join('|'),
            sourceDisplayId: mapping.sourceDisplayId,
            sourceEdge: mapping.sourceEdge,
            sourceSegmentStart: mapping.sourceSegmentStart,
            sourceSegmentEnd: mapping.sourceSegmentEnd,
            sinkDisplayId: mapping.sinkDisplayId,
            sinkEdge: mapping.sinkEdge,
            sinkSegmentStart: mapping.sinkSegmentStart,
            sinkSegmentEnd: mapping.sinkSegmentEnd,
          ),
        )
        .toList(growable: false);
  }

  void _publishTargets({
    required RemoteInputWorkspaceStatus statusFallback,
    String errorMessage = '',
  }) {
    final activePeerId =
        _targets[_snapshot.activePeerId]?.snapshot.isConnected == true
            ? _snapshot.activePeerId
            : '';
    _setSnapshot(
      _snapshot.copyWith(
        status: statusFallback,
        activePeerId: activePeerId,
        errorMessage: errorMessage,
        targets: _snapshotTargets(),
      ),
    );
  }

  Map<String, RemoteInputWorkspaceTargetSnapshot> _snapshotTargets() {
    return <String, RemoteInputWorkspaceTargetSnapshot>{
      for (final entry in _targets.entries) entry.key: entry.value.snapshot,
    };
  }

  Future<void> _disposeControllerRuntime({
    required String workspaceSessionId,
  }) async {
    await _inputSubscription?.cancel();
    await _releaseSubscription?.cancel();
    await _errorSubscription?.cancel();
    await _diagnosticSubscription?.cancel();
    _inputSubscription = null;
    _releaseSubscription = null;
    _errorSubscription = null;
    _diagnosticSubscription = null;
    if (workspaceSessionId.isNotEmpty) {
      await _platform.stopCapture(sessionId: workspaceSessionId);
    }
    for (final target in _targets.values) {
      await target.transportDoneSubscription?.cancel();
      target.transportDoneSubscription = null;
      await target.transport?.close();
      target.transport = null;
      _manager.stopSession(target.offer.sessionId);
    }
    _targets.clear();
    _sendControlTo = null;
  }

  void _setSnapshot(RemoteInputWorkspaceSnapshot snapshot) {
    _snapshot = snapshot;
    notifyListeners();
  }
}

class _WorkspaceLayoutSegment {
  const _WorkspaceLayoutSegment({
    required this.peerId,
    required this.displayId,
    required this.edge,
    required this.start,
    required this.end,
  });

  final String peerId;
  final String displayId;
  final RemoteInputEdge edge;
  final int start;
  final int end;

  String get key => '$displayId|${edge.name}';
}

class _RemoteInputWorkspaceTargetRuntime {
  _RemoteInputWorkspaceTargetRuntime({
    required this.request,
    required this.offer,
    required this.routedMappings,
  }) : snapshot = RemoteInputWorkspaceTargetSnapshot(
          peerId: request.peerId,
          peerName: request.peerName,
          sessionId: offer.sessionId,
          status: RemoteInputWorkspaceTargetStatus.offering,
        );

  final RemoteInputWorkspaceTargetRequest request;
  final RemoteInputControlMessage offer;
  final List<RemoteInputEdgeMapping> routedMappings;
  RemoteInputWorkspaceTargetSnapshot snapshot;
  RemoteInputPacketTransport? transport;
  StreamSubscription<void>? transportDoneSubscription;
}
