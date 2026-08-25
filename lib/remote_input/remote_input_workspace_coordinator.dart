import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_failure_reason.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_graph.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

typedef RemoteInputPeerControlSender =
    void Function(String peerId, RemoteInputControlMessage control);
typedef RemoteInputWorkspaceSessionIdFactory = String Function();

enum RemoteInputWorkspaceRole { idle, controller, controlled }

enum RemoteInputWorkspaceStatus { idle, offering, armed, active, failed }

enum RemoteInputWorkspaceTargetStatus { offering, connected, failed, stopped }

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
    this.injectionMappings = const <RemoteInputEdgeMapping>[],
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
  final List<RemoteInputEdgeMapping> injectionMappings;

  RemoteInputWorkspaceTargetRequest copyWith({
    String? peerName,
    String? host,
    int? port,
    bool? isMutuallyTrusted,
    bool? remoteCanInject,
    List<RemoteInputEdgeMapping>? edgeMappings,
    List<RemoteInputEdgeMapping>? injectionMappings,
  }) {
    return RemoteInputWorkspaceTargetRequest(
      peerId: peerId,
      peerName: peerName ?? this.peerName,
      host: host ?? this.host,
      port: port ?? this.port,
      layoutEdge: layoutEdge,
      releaseHotkey: releaseHotkey,
      isMutuallyTrusted: isMutuallyTrusted ?? this.isMutuallyTrusted,
      remoteCanInject: remoteCanInject ?? this.remoteCanInject,
      path: path,
      sourceDisplayId: sourceDisplayId,
      sourceEdge: sourceEdge,
      sourceSegmentStart: sourceSegmentStart,
      sourceSegmentEnd: sourceSegmentEnd,
      sinkDisplayId: sinkDisplayId,
      sinkEdge: sinkEdge,
      sinkSegmentStart: sinkSegmentStart,
      sinkSegmentEnd: sinkSegmentEnd,
      edgeMappings: edgeMappings ?? this.edgeMappings,
      injectionMappings: injectionMappings ?? this.injectionMappings,
    );
  }
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
  }) : _manager = manager ?? RemoteInputManager(),
       _platform = platform ?? RemoteInputCoordinator.shared.platform,
       _transportFactory = transportFactory,
       _workspaceSessionIdFactory =
           workspaceSessionIdFactory ?? const Uuid().v4;

  static final RemoteInputWorkspaceCoordinator shared =
      RemoteInputWorkspaceCoordinator(
        manager: RemoteInputManager.shared,
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
  final Map<String, RemoteInputWorkspaceRoute> _workspaceRoutesByRuntimeId =
      <String, RemoteInputWorkspaceRoute>{};
  final Map<String, String> _reverseRuntimeRouteIds = <String, String>{};
  final Set<String> _onlinePeerIds = <String>{};
  List<RemoteInputWorkspaceRoute> _workspaceRoutes =
      const <RemoteInputWorkspaceRoute>[];
  final Map<String, RemoteInputPacketFrame> _pressedKeyFrames =
      <String, RemoteInputPacketFrame>{};
  Future<void> _routingSerial = Future<void>.value();
  int _latestSourceSequence = 0;
  int _nextRoutedSequence = 0;
  int _activeSourceActivationSequence = 0;
  int _workspaceRevision = 0;
  String _sourcePeerId = '';

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
    privacyLog.event(PrivacyEvent.remoteInputDiagnostic, <PrivacyField, Object>{
      PrivacyField.kind: kind,
      if (reason != null) PrivacyField.reason: reason,
    });
  }

  Future<void> startControllerWorkspace({
    required String sourcePeerId,
    required List<RemoteInputWorkspaceTargetRequest> targets,
    required RemoteInputPeerControlSender sendControlTo,
    List<RemoteInputWorkspaceRoute> workspaceRoutes =
        const <RemoteInputWorkspaceRoute>[],
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
    final validation = RemoteInputWorkspaceLayoutValidator.validateTargets(
      targets,
    );
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
    _onlinePeerIds
      ..clear()
      ..addAll(targets.map((target) => target.peerId));
    _workspaceRoutes = List<RemoteInputWorkspaceRoute>.unmodifiable(
      workspaceRoutes,
    );
    _workspaceRoutesByRuntimeId.clear();
    _reverseRuntimeRouteIds.clear();
    _pressedKeyFrames.clear();
    _routingSerial = Future<void>.value();
    _latestSourceSequence = 0;
    _nextRoutedSequence = 0;
    _activeSourceActivationSequence = 0;
    _workspaceRevision = 1;
    _sourcePeerId = sourcePeerId;
    _indexWorkspaceRoutes(workspaceSessionId, _effectiveWorkspaceRoutes());
    final snapshots = <String, RemoteInputWorkspaceTargetSnapshot>{};
    for (final target in targets) {
      final routedMappings = _captureMappingsForTarget(
        workspaceSessionId,
        target,
      );
      final primaryMapping = routedMappings.isNotEmpty
          ? routedMappings.first
          : null;
      final injectionMappings = _injectionMappingsForTarget(
        workspaceSessionId,
        target,
      );
      final primaryInjectionMapping = injectionMappings.isNotEmpty
          ? injectionMappings.first
          : primaryMapping;
      final offer = _manager.createOffer(
        sourcePeerId: sourcePeerId,
        sinkPeerId: target.peerId,
        layoutEdge: primaryMapping?.sourceEdge ?? target.layoutEdge,
        releaseHotkey: target.releaseHotkey,
        sourceDisplayId:
            primaryInjectionMapping?.sourceDisplayId ?? target.sourceDisplayId,
        sourceEdge: primaryInjectionMapping?.sourceEdge ?? target.sourceEdge,
        sourceSegmentStart:
            primaryInjectionMapping?.sourceSegmentStart ??
            target.sourceSegmentStart,
        sourceSegmentEnd:
            primaryInjectionMapping?.sourceSegmentEnd ??
            target.sourceSegmentEnd,
        sinkDisplayId:
            primaryInjectionMapping?.sinkDisplayId ?? target.sinkDisplayId,
        sinkEdge: primaryInjectionMapping?.sinkEdge ?? target.sinkEdge,
        sinkSegmentStart:
            primaryInjectionMapping?.sinkSegmentStart ??
            target.sinkSegmentStart,
        sinkSegmentEnd:
            primaryInjectionMapping?.sinkSegmentEnd ?? target.sinkSegmentEnd,
        edgeMappings: injectionMappings,
        remoteClipboardV1:
            currentRemoteInputPlatformKind() != RemoteInputPlatformKind.unknown,
      );
      _targets[target.peerId] = _RemoteInputWorkspaceTargetRuntime(
        request: target,
        offer: offer,
        routedMappings: routedMappings,
        injectionMappings: injectionMappings,
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

  Future<bool> updateControllerWorkspaceRoutes({
    required List<RemoteInputWorkspaceTargetRequest> targets,
    required List<RemoteInputWorkspaceRoute> workspaceRoutes,
    required RemoteInputPeerControlSender sendControlTo,
  }) async {
    if (!_snapshot.isControllerLive) {
      return false;
    }
    final invalidTarget = targets.where((target) {
      return !target.isMutuallyTrusted || !target.remoteCanInject;
    }).firstOrNull;
    if (invalidTarget != null) {
      return false;
    }

    final workspaceSessionId = _snapshot.workspaceSessionId;
    _workspaceRevision += 1;
    _workspaceRoutes = List<RemoteInputWorkspaceRoute>.unmodifiable(
      workspaceRoutes,
    );
    final requestedByPeer = <String, RemoteInputWorkspaceTargetRequest>{
      for (final target in targets) target.peerId: target,
    };
    final removedPeerIds = _targets.keys
        .where((peerId) => !requestedByPeer.containsKey(peerId))
        .toList(growable: false);
    for (final peerId in removedPeerIds) {
      final runtime = _targets.remove(peerId)!;
      _onlinePeerIds.remove(peerId);
      if (runtime.snapshot.isLive) {
        sendControlTo(
          peerId,
          RemoteInputControlMessage(
            action: RemoteInputControlAction.stop,
            sessionId: runtime.offer.sessionId,
            sourcePeerId: runtime.offer.sourcePeerId,
            sinkPeerId: runtime.offer.sinkPeerId,
          ),
        );
      }
      await runtime.transportDoneSubscription?.cancel();
      await runtime.transport?.close();
      _manager.stopSession(runtime.offer.sessionId);
    }
    _onlinePeerIds.addAll(requestedByPeer.keys);
    _workspaceRoutesByRuntimeId.clear();
    _reverseRuntimeRouteIds.clear();
    _indexWorkspaceRoutes(workspaceSessionId, _effectiveWorkspaceRoutes());

    for (final target in targets) {
      var runtime = _targets[target.peerId];
      if (runtime == null) {
        runtime = _createTargetRuntime(
          sourcePeerId: _snapshot.sourcePeerId,
          workspaceSessionId: workspaceSessionId,
          target: target,
        );
        _targets[target.peerId] = runtime;
        sendControlTo(target.peerId, runtime.offer);
        continue;
      }
      final captureMappings = _captureMappingsForTarget(
        workspaceSessionId,
        target,
      );
      final injectionMappings = _injectionMappingsForTarget(
        workspaceSessionId,
        target,
      );
      runtime
        ..request = target
        ..routedMappings = captureMappings
        ..injectionMappings = injectionMappings;
    }
    await _reconcileWorkspaceGraph(sendControlTo: sendControlTo);
    return true;
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
        return _enqueueRouting(() => _handleRelease(message));
      case RemoteInputControlAction.routes:
        return false;
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
    _onlinePeerIds.remove(peerId);
    await _closeControllerTarget(
      target,
      terminalStatus: RemoteInputWorkspaceStatus.idle,
      errorMessage: RemoteInputFailureReason.transport.name,
    );
  }

  Future<void> handlePeerReconnected({
    required String peerId,
    required String host,
    required int port,
    required bool isMutuallyTrusted,
    required bool remoteCanInject,
    required RemoteInputPeerControlSender sendControlTo,
  }) async {
    if (!_snapshot.isControllerLive ||
        _workspaceRoutes.isEmpty ||
        !_targets.containsKey(peerId) ||
        !isMutuallyTrusted ||
        !remoteCanInject) {
      return;
    }
    _sendControlTo = sendControlTo;
    _onlinePeerIds.add(peerId);
    final existing = _targets[peerId]!;
    existing.request = existing.request.copyWith(
      host: host,
      port: port,
      isMutuallyTrusted: isMutuallyTrusted,
      remoteCanInject: remoteCanInject,
    );
    await _reconcileWorkspaceGraph(sendControlTo: sendControlTo);
    final reachable = _reachableWorkspacePeerIds();
    for (final entry in _targets.entries.toList(growable: false)) {
      final runtime = entry.value;
      if (!_onlinePeerIds.contains(entry.key) ||
          !reachable.contains(entry.key) ||
          runtime.snapshot.isLive ||
          runtime.snapshot.isConnected) {
        continue;
      }
      final replacement = _createTargetRuntime(
        sourcePeerId: _sourcePeerId,
        workspaceSessionId: _snapshot.workspaceSessionId,
        target: runtime.request,
      );
      _targets[entry.key] = replacement;
      sendControlTo(entry.key, replacement.offer);
    }
    _publishTargets(statusFallback: RemoteInputWorkspaceStatus.offering);
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
          'authenticated remote input workspace context missing',
        );
      }
      target.transport = await RemoteInputWebSocketPacketTransport.connect(
        uri,
        mediaMacKey: mediaSendKey,
        sessionId: accept.sessionId,
        peerId: accept.sourcePeerId,
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
    if (_snapshot.activePeerId != target.request.peerId) {
      return false;
    }
    if (message.releaseActivationSequence > 0 &&
        target.targetActivationSequence > 0 &&
        message.releaseActivationSequence != target.targetActivationSequence) {
      return false;
    }
    final sourceActivationSequence = target.sourceActivationSequence > 0
        ? target.sourceActivationSequence
        : _activeSourceActivationSequence;
    final route = _workspaceRoutesByRuntimeId[message.routeId];
    if (route != null && route.sinkPeerId == target.request.peerId) {
      return _handleWorkspaceRouteRelease(
        message,
        route,
        activeTarget: target,
        sourceActivationSequence: sourceActivationSequence,
      );
    }
    // A delayed release can reference a route removed by a live layout update.
    // Keep the controller's last valid local route instead of applying the
    // controlled device's display coordinates to the controller.
    await _platform.pauseCapture(
      sessionId: _snapshot.workspaceSessionId,
      releaseSequence: _latestSourceSequence,
      releaseActivationSequence: sourceActivationSequence,
      releaseEdgeUnit: message.releaseEdgeUnit,
    );
    _clearActiveCaptureRoute(target);
    _setSnapshot(
      _snapshot.copyWith(
        status: RemoteInputWorkspaceStatus.armed,
        activePeerId: '',
      ),
    );
    return true;
  }

  Future<bool> _handleWorkspaceRouteRelease(
    RemoteInputControlMessage message,
    RemoteInputWorkspaceRoute incomingRoute, {
    required _RemoteInputWorkspaceTargetRuntime activeTarget,
    required int sourceActivationSequence,
  }) async {
    final nextPeerId = incomingRoute.sourcePeerId;
    if (nextPeerId == _snapshot.sourcePeerId) {
      final mapping = incomingRoute.mapping;
      await _platform.pauseCapture(
        sessionId: _snapshot.workspaceSessionId,
        releaseSequence: _latestSourceSequence,
        releaseActivationSequence: sourceActivationSequence,
        releaseEdgeUnit: message.releaseEdgeUnit,
        displayId: mapping.sourceDisplayId,
        edge: mapping.sourceEdge,
        segmentStart: mapping.sourceSegmentStart,
        segmentEnd: mapping.sourceSegmentEnd,
        routeId: message.routeId,
      );
      _clearActiveCaptureRoute(activeTarget);
      _setSnapshot(
        _snapshot.copyWith(
          status: RemoteInputWorkspaceStatus.armed,
          activePeerId: '',
        ),
      );
      return true;
    }

    final nextTarget = _targets[nextPeerId];
    final reverseRouteId = _reverseRuntimeRouteIds[message.routeId];
    if (nextTarget?.snapshot.isConnected != true ||
        nextTarget?.transport == null ||
        reverseRouteId == null) {
      await _platform.pauseCapture(
        sessionId: _snapshot.workspaceSessionId,
        releaseSequence: _latestSourceSequence,
        releaseActivationSequence: sourceActivationSequence,
      );
      _clearActiveCaptureRoute(activeTarget);
      _setSnapshot(
        _snapshot.copyWith(
          status: RemoteInputWorkspaceStatus.armed,
          activePeerId: '',
        ),
      );
      return true;
    }

    final reverseRoute = _workspaceRoutesByRuntimeId[reverseRouteId]!;
    final mapping = reverseRoute.mapping;
    final routedActivationSequence = _sendRoutedPacket(
      nextTarget!,
      RemoteInputPacketFrame(
        sessionId: nextTarget.offer.sessionId,
        sequence: 0,
        timestampMicros: DateTime.now().microsecondsSinceEpoch,
        eventType: RemoteInputEventType.mouseMove,
        payload: Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, Object>{
              'activeStart': true,
              'routeId': reverseRouteId,
              'edge': mapping.sourceEdge.name,
              'edgeUnit': message.releaseEdgeUnit.clamp(0, 1),
              'deltaX': 0,
              'deltaY': 0,
              'buttons': 0,
            }),
          ),
        ),
      ),
    );
    _clearTargetActivation(activeTarget);
    _recordActiveCaptureRoute(
      nextTarget,
      targetActivationSequence: routedActivationSequence,
      sourceActivationSequence: sourceActivationSequence,
    );
    for (final pressed in _pressedKeyFrames.values) {
      _sendRoutedPacket(nextTarget, pressed);
    }
    _setSnapshot(
      _snapshot.copyWith(
        status: RemoteInputWorkspaceStatus.active,
        activePeerId: nextPeerId,
        targets: _snapshotTargets(),
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
    final failureReason = remoteInputFailureReasonFromWire(
      message.errorMessage,
    );
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
    if (_workspaceRoutes.isNotEmpty) {
      await _reconcileWorkspaceGraph(
        sendControlTo: _sendControlTo,
        errorMessage: errorMessage,
      );
      return;
    }
    final hasConnectedTarget = _targets.values.any(
      (target) => target.snapshot.isConnected,
    );
    final hasLiveTarget = _targets.values.any(
      (target) => target.snapshot.isLive,
    );
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

  Set<String> _reachableWorkspacePeerIds() {
    final reachable = <String>{_sourcePeerId};
    var changed = true;
    while (changed) {
      changed = false;
      for (final route in _workspaceRoutes) {
        if (reachable.contains(route.sourcePeerId) &&
            _onlinePeerIds.contains(route.sinkPeerId) &&
            reachable.add(route.sinkPeerId)) {
          changed = true;
        }
      }
    }
    return reachable;
  }

  Future<void> _reconcileWorkspaceGraph({
    RemoteInputPeerControlSender? sendControlTo,
    String errorMessage = '',
  }) async {
    if (!_snapshot.isControllerLive || _workspaceRoutes.isEmpty) {
      return;
    }
    final reachable = _reachableWorkspacePeerIds();
    if (_snapshot.activePeerId.isNotEmpty &&
        !reachable.contains(_snapshot.activePeerId)) {
      await _platform.pauseCapture(sessionId: _snapshot.workspaceSessionId);
      _snapshot = _snapshot.copyWith(activePeerId: '');
    }
    for (final target in _targets.values) {
      if (reachable.contains(target.request.peerId) ||
          !target.snapshot.isLive) {
        continue;
      }
      if (sendControlTo != null) {
        sendControlTo(
          target.request.peerId,
          RemoteInputControlMessage(
            action: RemoteInputControlAction.stop,
            sessionId: target.offer.sessionId,
            sourcePeerId: target.offer.sourcePeerId,
            sinkPeerId: target.offer.sinkPeerId,
          ),
        );
      }
      await target.transportDoneSubscription?.cancel();
      target.transportDoneSubscription = null;
      await target.transport?.close();
      target.transport = null;
      _manager.stopSession(target.offer.sessionId);
      target.snapshot = target.snapshot.copyWith(
        status: RemoteInputWorkspaceTargetStatus.stopped,
        errorMessage: RemoteInputFailureReason.transport.name,
      );
    }

    _workspaceRevision += 1;
    _workspaceRoutesByRuntimeId.clear();
    _reverseRuntimeRouteIds.clear();
    _indexWorkspaceRoutes(
      _snapshot.workspaceSessionId,
      _effectiveWorkspaceRoutes(),
    );
    for (final target in _targets.values) {
      target.routedMappings = _captureMappingsForTarget(
        _snapshot.workspaceSessionId,
        target.request,
      );
      target.injectionMappings = _injectionMappingsForTarget(
        _snapshot.workspaceSessionId,
        target.request,
      );
      if (!target.snapshot.isConnected || sendControlTo == null) {
        continue;
      }
      final primary = target.injectionMappings.firstOrNull;
      sendControlTo(
        target.request.peerId,
        RemoteInputControlMessage(
          action: RemoteInputControlAction.routes,
          sessionId: target.offer.sessionId,
          sourcePeerId: target.offer.sourcePeerId,
          sinkPeerId: target.offer.sinkPeerId,
          layoutEdge: primary?.sourceEdge ?? target.offer.layoutEdge,
          sourceDisplayId:
              primary?.sourceDisplayId ?? target.offer.sourceDisplayId,
          sourceEdge: primary?.sourceEdge ?? target.offer.sourceEdge,
          sourceSegmentStart:
              primary?.sourceSegmentStart ?? target.offer.sourceSegmentStart,
          sourceSegmentEnd:
              primary?.sourceSegmentEnd ?? target.offer.sourceSegmentEnd,
          sinkDisplayId: primary?.sinkDisplayId ?? target.offer.sinkDisplayId,
          sinkEdge: primary?.sinkEdge ?? target.offer.sinkEdge,
          sinkSegmentStart:
              primary?.sinkSegmentStart ?? target.offer.sinkSegmentStart,
          sinkSegmentEnd:
              primary?.sinkSegmentEnd ?? target.offer.sinkSegmentEnd,
          edgeMappings: target.injectionMappings,
          workspaceRevision: _workspaceRevision,
        ),
      );
    }
    final connected = _targets.values.any(
      (target) => target.snapshot.isConnected,
    );
    if (connected) {
      await _refreshCapture();
    } else {
      await _platform.stopCapture(sessionId: _snapshot.workspaceSessionId);
    }
    _publishTargets(
      statusFallback: connected
          ? RemoteInputWorkspaceStatus.armed
          : RemoteInputWorkspaceStatus.offering,
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
      displayId:
          primaryMapping?.sourceDisplayId ??
          primaryTarget.request.sourceDisplayId,
      segmentStart:
          primaryMapping?.sourceSegmentStart ??
          primaryTarget.request.sourceSegmentStart,
      segmentEnd:
          primaryMapping?.sourceSegmentEnd ??
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
        unawaited(
          _disposeControllerRuntime(
            workspaceSessionId: _snapshot.workspaceSessionId,
          ),
        );
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
    unawaited(_enqueueRouting(() => _routeInputEvent(event)));
  }

  Future<void> _routeInputEvent(RemoteInputPacketFrame event) async {
    if (event.sessionId != _snapshot.workspaceSessionId ||
        _snapshot.role != RemoteInputWorkspaceRole.controller) {
      return;
    }
    _latestSourceSequence = math.max(_latestSourceSequence, event.sequence);
    _trackPressedKey(event);
    final target = _targetForPacket(event);
    if (target == null || target.transport == null) {
      return;
    }
    final isActiveStart = _isActivationStartPacket(event);
    final routedSequence = _sendRoutedPacket(target, event);
    if (isActiveStart) {
      _recordActiveCaptureRoute(
        target,
        targetActivationSequence: routedSequence,
        sourceActivationSequence: event.sequence,
      );
    }
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

  Future<T> _enqueueRouting<T>(FutureOr<T> Function() operation) {
    final completer = Completer<T>();
    _routingSerial = _routingSerial.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  int _sendRoutedPacket(
    _RemoteInputWorkspaceTargetRuntime target,
    RemoteInputPacketFrame packet,
  ) {
    final transport = target.transport;
    if (transport == null) {
      return 0;
    }
    _nextRoutedSequence += 1;
    transport.send(
      RemoteInputPacketFrame(
        sessionId: target.offer.sessionId,
        sequence: _nextRoutedSequence,
        timestampMicros: packet.timestampMicros,
        eventType: packet.eventType,
        payload: packet.payload,
      ),
    );
    return _nextRoutedSequence;
  }

  void _clearActiveCaptureRoute(_RemoteInputWorkspaceTargetRuntime? target) {
    _clearTargetActivation(target);
    _activeSourceActivationSequence = 0;
  }

  void _recordActiveCaptureRoute(
    _RemoteInputWorkspaceTargetRuntime target, {
    required int targetActivationSequence,
    required int sourceActivationSequence,
  }) {
    // Routed packets and native capture each maintain their own sequence.
    target
      ..targetActivationSequence = targetActivationSequence
      ..sourceActivationSequence = sourceActivationSequence;
    _activeSourceActivationSequence = sourceActivationSequence;
  }

  void _clearTargetActivation(_RemoteInputWorkspaceTargetRuntime? target) {
    target
      ?..targetActivationSequence = 0
      ..sourceActivationSequence = 0;
  }

  void _trackPressedKey(RemoteInputPacketFrame packet) {
    if (packet.eventType != RemoteInputEventType.key) {
      return;
    }
    final payload = _jsonPayload(packet);
    if (payload == null || payload['down'] is! bool) {
      return;
    }
    final semantic = payload['modifierSemantic'] ?? payload['keySemantic'];
    if (semantic == RemoteInputModifierSemantic.capsLock.name) {
      return;
    }
    final identity = semantic?.toString().isNotEmpty == true
        ? semantic.toString()
        : <Object?>[
            payload['sourcePlatform'],
            payload['macKeyCode'],
            payload['windowsScanCode'],
            payload['linuxKeyCode'],
            payload['keyCode'],
          ].join('|');
    if (payload['down'] == true) {
      _pressedKeyFrames[identity] = packet;
    } else {
      _pressedKeyFrames.remove(identity);
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
    final mappings = RemoteInputWorkspaceLayoutValidator._mappingsForTarget(
      target,
    );
    return _routedMappingsFor(
      workspaceSessionId: workspaceSessionId,
      peerId: target.peerId,
      mappings: mappings,
    );
  }

  List<RemoteInputWorkspaceRoute> _effectiveWorkspaceRoutes() {
    if (_workspaceRoutes.isEmpty) {
      return const <RemoteInputWorkspaceRoute>[];
    }
    final reachable = <String>{_sourcePeerId};
    var changed = true;
    while (changed) {
      changed = false;
      for (final route in _workspaceRoutes) {
        if (reachable.contains(route.sourcePeerId) &&
            _onlinePeerIds.contains(route.sinkPeerId) &&
            reachable.add(route.sinkPeerId)) {
          changed = true;
        }
      }
    }
    return _workspaceRoutes
        .where(
          (route) =>
              reachable.contains(route.sourcePeerId) &&
              reachable.contains(route.sinkPeerId),
        )
        .toList(growable: false);
  }

  List<RemoteInputEdgeMapping> _captureMappingsForTarget(
    String workspaceSessionId,
    RemoteInputWorkspaceTargetRequest target,
  ) {
    if (_workspaceRoutes.isEmpty) {
      return _routedMappings(
        workspaceSessionId: workspaceSessionId,
        target: target,
      );
    }
    final mappings = _effectiveWorkspaceRoutes()
        .where(
          (route) =>
              route.sourcePeerId == _sourcePeerId &&
              route.sinkPeerId == target.peerId,
        )
        .map((route) => route.mapping)
        .toList(growable: false);
    return _routedMappingsFor(
      workspaceSessionId: workspaceSessionId,
      peerId: target.peerId,
      mappings: mappings,
    );
  }

  List<RemoteInputEdgeMapping> _injectionMappingsForTarget(
    String workspaceSessionId,
    RemoteInputWorkspaceTargetRequest target,
  ) {
    final mappings = _workspaceRoutes.isEmpty
        ? (target.injectionMappings.isEmpty
              ? target.edgeMappings
              : target.injectionMappings)
        : _effectiveWorkspaceRoutes()
              .where((route) => route.sinkPeerId == target.peerId)
              .map((route) => route.mapping)
              .toList(growable: false);
    return _routedMappingsFor(
      workspaceSessionId: workspaceSessionId,
      peerId: target.peerId,
      mappings: mappings,
    );
  }

  _RemoteInputWorkspaceTargetRuntime _createTargetRuntime({
    required String sourcePeerId,
    required String workspaceSessionId,
    required RemoteInputWorkspaceTargetRequest target,
  }) {
    final captureMappings = _captureMappingsForTarget(
      workspaceSessionId,
      target,
    );
    final injectionMappings = _injectionMappingsForTarget(
      workspaceSessionId,
      target,
    );
    final primary =
        injectionMappings.firstOrNull ?? captureMappings.firstOrNull;
    final offer = _manager.createOffer(
      sourcePeerId: sourcePeerId,
      sinkPeerId: target.peerId,
      layoutEdge: primary?.sourceEdge ?? target.layoutEdge,
      releaseHotkey: target.releaseHotkey,
      sourceDisplayId: primary?.sourceDisplayId ?? target.sourceDisplayId,
      sourceEdge: primary?.sourceEdge ?? target.sourceEdge,
      sourceSegmentStart:
          primary?.sourceSegmentStart ?? target.sourceSegmentStart,
      sourceSegmentEnd: primary?.sourceSegmentEnd ?? target.sourceSegmentEnd,
      sinkDisplayId: primary?.sinkDisplayId ?? target.sinkDisplayId,
      sinkEdge: primary?.sinkEdge ?? target.sinkEdge,
      sinkSegmentStart: primary?.sinkSegmentStart ?? target.sinkSegmentStart,
      sinkSegmentEnd: primary?.sinkSegmentEnd ?? target.sinkSegmentEnd,
      edgeMappings: injectionMappings,
      remoteClipboardV1:
          currentRemoteInputPlatformKind() != RemoteInputPlatformKind.unknown,
    );
    return _RemoteInputWorkspaceTargetRuntime(
      request: target,
      offer: offer,
      routedMappings: captureMappings,
      injectionMappings: injectionMappings,
    );
  }

  List<RemoteInputEdgeMapping> _routedMappingsFor({
    required String workspaceSessionId,
    required String peerId,
    required List<RemoteInputEdgeMapping> mappings,
  }) {
    return mappings
        .map(
          (mapping) => RemoteInputEdgeMapping(
            routeId: [
              workspaceSessionId,
              peerId,
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

  void _indexWorkspaceRoutes(
    String workspaceSessionId,
    List<RemoteInputWorkspaceRoute> routes,
  ) {
    String runtimeId(RemoteInputWorkspaceRoute route) =>
        <String>[workspaceSessionId, route.sinkPeerId, route.routeId].join('|');

    for (final route in routes) {
      _workspaceRoutesByRuntimeId[runtimeId(route)] = route;
    }
    for (final route in routes) {
      final reverse = routes.where((candidate) {
        return candidate.sourcePeerId == route.sinkPeerId &&
            candidate.sinkPeerId == route.sourcePeerId &&
            candidate.mapping.sourceDisplayId == route.mapping.sinkDisplayId &&
            candidate.mapping.sinkDisplayId == route.mapping.sourceDisplayId &&
            candidate.mapping.sourceEdge == route.mapping.sinkEdge &&
            candidate.mapping.sinkEdge == route.mapping.sourceEdge;
      }).firstOrNull;
      if (reverse != null) {
        _reverseRuntimeRouteIds[runtimeId(route)] = runtimeId(reverse);
      }
    }
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
    _onlinePeerIds.clear();
    _workspaceRoutes = const <RemoteInputWorkspaceRoute>[];
    _workspaceRoutesByRuntimeId.clear();
    _reverseRuntimeRouteIds.clear();
    _pressedKeyFrames.clear();
    _latestSourceSequence = 0;
    _nextRoutedSequence = 0;
    _activeSourceActivationSequence = 0;
    _workspaceRevision = 0;
    _sourcePeerId = '';
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
    required this.injectionMappings,
  }) : snapshot = RemoteInputWorkspaceTargetSnapshot(
         peerId: request.peerId,
         peerName: request.peerName,
         sessionId: offer.sessionId,
         status: RemoteInputWorkspaceTargetStatus.offering,
       );

  RemoteInputWorkspaceTargetRequest request;
  RemoteInputControlMessage offer;
  List<RemoteInputEdgeMapping> routedMappings;
  List<RemoteInputEdgeMapping> injectionMappings;
  RemoteInputWorkspaceTargetSnapshot snapshot;
  RemoteInputPacketTransport? transport;
  StreamSubscription<void>? transportDoneSubscription;
  int targetActivationSequence = 0;
  int sourceActivationSequence = 0;
}
