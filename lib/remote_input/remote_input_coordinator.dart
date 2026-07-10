import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/remote_input/remote_input_failure_reason.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_scroll.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

typedef RemoteInputControlSender = void Function(
  RemoteInputControlMessage control,
);
typedef RemoteInputTransportFactory = Future<RemoteInputPacketTransport>
    Function(Uri uri);
typedef RemoteInputKeyTranslatorFactory = RemoteInputKeyTranslator Function(
  RemoteInputPlatformKind platform,
);
typedef RemoteInputPlatformKindProvider = RemoteInputPlatformKind Function();
typedef RemoteInputScrollMultiplierProvider = Future<double> Function();

enum RemoteInputRuntimeRole {
  none,
  source,
  sink,
}

enum RemoteInputRuntimeStatus {
  idle,
  offering,
  armed,
  connecting,
  active,
  failed,
}

enum RemoteInputDiagnosticKind {
  startRequested,
  startRejected,
  offerCreated,
  controlReceived,
  controlStopped,
  controlError,
  stopped,
  offerIgnored,
  offerRejected,
  offerBusy,
  offerAcceptFailed,
  injectionStarting,
  acceptSent,
  injectionFailed,
  captureStarting,
  captureFailed,
  injectionStarted,
  earlyReleaseIgnored,
  platformError,
  platformDiagnostic,
  packetObserved,
  injectionActive,
  captureMissingEdge,
  transportConnecting,
  transportConnected,
  captureStarted,
  transportClosed,
  staleReleaseIgnored,
  settingFallback,
  stateChanged,
}

enum RemoteInputTraceDirection { source, sink }

class RemoteInputRuntimeState {
  const RemoteInputRuntimeState({
    required this.status,
    required this.role,
    this.sessionId = '',
    this.peerId = '',
    this.errorMessage = '',
  });

  const RemoteInputRuntimeState.idle()
      : status = RemoteInputRuntimeStatus.idle,
        role = RemoteInputRuntimeRole.none,
        sessionId = '',
        peerId = '',
        errorMessage = '';

  final RemoteInputRuntimeStatus status;
  final RemoteInputRuntimeRole role;
  final String sessionId;
  final String peerId;
  final String errorMessage;

  bool get isActive => status == RemoteInputRuntimeStatus.active;
  bool get isBusy =>
      status == RemoteInputRuntimeStatus.offering ||
      status == RemoteInputRuntimeStatus.connecting;

  bool isForPeer(String peerId) {
    return this.peerId == peerId && status != RemoteInputRuntimeStatus.idle;
  }
}

class RemoteInputCoordinator extends ChangeNotifier {
  RemoteInputCoordinator({
    RemoteInputManager? manager,
    RemoteInputPlatform? platform,
    RemoteInputTransportFactory? transportFactory,
    RemoteInputKeyTranslatorFactory? keyTranslatorFactory,
    RemoteInputPlatformKindProvider? platformKindProvider,
    RemoteInputScrollMultiplierProvider? scrollMultiplierProvider,
  })  : _manager = manager ?? RemoteInputManager.shared,
        _platform = platform ?? RemoteInputPlatform(),
        _transportFactory = transportFactory,
        _keyTranslatorFactory = keyTranslatorFactory ??
            ((platform) => RemoteInputKeyTranslator(targetPlatform: platform)),
        _platformKindProvider =
            platformKindProvider ?? currentRemoteInputPlatformKind,
        _scrollMultiplierProvider = scrollMultiplierProvider ??
            LocalSetting().remoteInputScrollMultiplier;

  static final RemoteInputCoordinator shared = RemoteInputCoordinator();
  static const double _sinkEntryReleaseDistance = 16;
  static const int _packetTraceLimit = 8;

  final RemoteInputManager _manager;
  final RemoteInputPlatform _platform;
  final RemoteInputTransportFactory? _transportFactory;
  final RemoteInputKeyTranslatorFactory _keyTranslatorFactory;
  final RemoteInputPlatformKindProvider _platformKindProvider;
  final RemoteInputScrollMultiplierProvider _scrollMultiplierProvider;

  RemoteInputRuntimeState _state = const RemoteInputRuntimeState.idle();
  RemoteInputPacketTransport? _transport;
  final List<RemoteInputPacketFrame> _pendingInjectionFrames =
      <RemoteInputPacketFrame>[];
  bool _injectionPumpRunning = false;
  RemoteInputKeyTranslator? _keyTranslator;
  StreamSubscription<RemoteInputPacketFrame>? _inputSubscription;
  StreamSubscription<PlatformRemoteInputRelease>? _releaseSubscription;
  StreamSubscription<PlatformRemoteInputError>? _errorSubscription;
  StreamSubscription<PlatformRemoteInputDiagnostic>? _diagnosticSubscription;
  StreamSubscription<void>? _transportDoneSubscription;
  int _latestSourceInputSequence = 0;
  int _latestSourceActivationSequence = 0;
  int _latestSinkPacketSequence = 0;
  int _latestSinkActivationSequence = 0;
  int _sourcePacketTraceCount = 0;
  int _sinkPacketTraceCount = 0;
  double _sinkEntryTravel = 0;
  double _scrollMultiplier = 1.0;
  RemoteInputPlatformKind _sinkSourcePlatform = RemoteInputPlatformKind.unknown;
  RemoteInputEdgeMapping? _sinkActiveEdgeMapping;

  RemoteInputRuntimeState get state => _state;
  RemoteInputPlatform get platform => _platform;

  void updateScrollMultiplier(double multiplier) {
    _scrollMultiplier = RemoteInputScrollNormalizer.clampMultiplier(multiplier);
  }

  Future<RemoteInputTopology> displayTopology() {
    return _platform.displayTopology();
  }

  bool get _hasLiveSession =>
      _state.status != RemoteInputRuntimeStatus.idle &&
      _state.status != RemoteInputRuntimeStatus.failed;

  bool get _shouldTraceLifecycle =>
      !kReleaseMode ||
      Platform.environment['WHISPER_REMOTE_INPUT_TRACE'] == '1';

  bool get _shouldTracePackets =>
      Platform.environment['WHISPER_REMOTE_INPUT_TRACE'] == '1';

  void _trace(
    RemoteInputDiagnosticKind kind, {
    RemoteInputRuntimeStatus? state,
    RemoteInputRuntimeRole? role,
    RemoteInputControlAction? action,
    RemoteInputTraceDirection? direction,
    RemoteInputFailureReason? reason,
    bool? allowed,
    bool? enabled,
    int? count,
    Object? localError,
  }) {
    if (!_shouldTraceLifecycle) {
      return;
    }
    privacyLog.event(PrivacyEvent.remoteInputDiagnostic, <PrivacyField, Object>{
      PrivacyField.kind: kind,
      if (state != null) PrivacyField.state: state,
      if (role != null) PrivacyField.role: role,
      if (action != null) PrivacyField.action: action,
      if (direction != null) PrivacyField.direction: direction,
      if (reason != null) PrivacyField.reason: reason,
      if (allowed != null) PrivacyField.allowed: allowed,
      if (enabled != null) PrivacyField.enabled: enabled,
      if (count != null) PrivacyField.count: count,
      if (localError != null)
        PrivacyField.errorType: privacyLog.errorType(localError),
    });
  }

  Future<void> startSharingToConnectedPeer({
    required String sourcePeerId,
    required String sinkPeerId,
    required String sinkHost,
    required int sinkPort,
    required RemoteInputEdge layoutEdge,
    required String releaseHotkey,
    required bool isMutuallyTrusted,
    required bool remoteCanInject,
    required RemoteInputControlSender sendControl,
    String sourceDisplayId = '',
    RemoteInputEdge? sourceEdge,
    int sourceSegmentStart = 0,
    int sourceSegmentEnd = 0,
    String sinkDisplayId = '',
    RemoteInputEdge? sinkEdge,
    int sinkSegmentStart = 0,
    int sinkSegmentEnd = 0,
    List<RemoteInputEdgeMapping> edgeMappings =
        const <RemoteInputEdgeMapping>[],
  }) async {
    _trace(
      RemoteInputDiagnosticKind.startRequested,
      state: _state.status,
      role: _state.role,
      allowed: isMutuallyTrusted,
      enabled: remoteCanInject,
    );
    await stopLocal();
    if (!isMutuallyTrusted || !remoteCanInject) {
      final failureReason = !isMutuallyTrusted
          ? RemoteInputFailureReason.trustRequired
          : RemoteInputFailureReason.unsupported;
      _trace(
        RemoteInputDiagnosticKind.startRejected,
        reason: failureReason,
        allowed: isMutuallyTrusted,
        enabled: remoteCanInject,
      );
      _setState(
        RemoteInputRuntimeState(
          status: RemoteInputRuntimeStatus.failed,
          role: RemoteInputRuntimeRole.none,
          peerId: sinkPeerId,
          errorMessage: failureReason.name,
        ),
      );
      return;
    }

    final offer = _manager.createOffer(
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      layoutEdge: layoutEdge,
      releaseHotkey: releaseHotkey,
      sourcePlatform: _platformKindProvider().name,
      sourceDisplayId: sourceDisplayId,
      sourceEdge: sourceEdge,
      sourceSegmentStart: sourceSegmentStart,
      sourceSegmentEnd: sourceSegmentEnd,
      sinkDisplayId: sinkDisplayId,
      sinkEdge: sinkEdge,
      sinkSegmentStart: sinkSegmentStart,
      sinkSegmentEnd: sinkSegmentEnd,
      edgeMappings: edgeMappings,
    );
    _setState(
      RemoteInputRuntimeState(
        status: RemoteInputRuntimeStatus.offering,
        role: RemoteInputRuntimeRole.source,
        sessionId: offer.sessionId,
        peerId: sinkPeerId,
      ),
    );
    _trace(RemoteInputDiagnosticKind.offerCreated);
    sendControl(offer);
  }

  Future<void> handleControlMessage(
    RemoteInputControlMessage message, {
    required String localPeerId,
    required String remoteHost,
    required int remotePort,
    required bool isMutuallyTrusted,
    required bool localCanInject,
    required RemoteInputControlSender sendControl,
    String remotePlatform = '',
    Uint8List? mediaSendKey,
  }) async {
    _trace(
      RemoteInputDiagnosticKind.controlReceived,
      action: message.action,
      state: _state.status,
      role: _state.role,
      allowed: isMutuallyTrusted,
      enabled: localCanInject,
    );
    switch (message.action) {
      case RemoteInputControlAction.offer:
        await _handleOffer(
          message,
          localPeerId: localPeerId,
          isMutuallyTrusted: isMutuallyTrusted,
          localCanInject: localCanInject,
          sendControl: sendControl,
          remotePlatform: remotePlatform,
        );
        break;
      case RemoteInputControlAction.accept:
        await _handleAccept(
          message,
          localPeerId: localPeerId,
          remoteHost: remoteHost,
          remotePort: remotePort,
          sendControl: sendControl,
          mediaSendKey: mediaSendKey,
        );
        break;
      case RemoteInputControlAction.release:
        await _handleRelease(message);
        break;
      case RemoteInputControlAction.stop:
      case RemoteInputControlAction.reject:
        _trace(
          RemoteInputDiagnosticKind.controlStopped,
          action: message.action,
        );
        _manager.handleControlMessage(message);
        if (_state.sessionId == message.sessionId) {
          await stopLocal();
        }
        break;
      case RemoteInputControlAction.error:
        final failureReason =
            remoteInputFailureReasonFromWire(message.errorMessage);
        _trace(
          RemoteInputDiagnosticKind.controlError,
          reason: failureReason,
        );
        _manager.handleControlMessage(message);
        if (_state.sessionId == message.sessionId) {
          await stopLocal();
          _setState(
            RemoteInputRuntimeState(
              status: RemoteInputRuntimeStatus.failed,
              role: RemoteInputRuntimeRole.none,
              sessionId: message.sessionId,
              peerId: _state.peerId,
              errorMessage: failureReason.name,
            ),
          );
        }
        break;
    }
  }

  Future<void> stopSharing({
    required RemoteInputControlSender sendControl,
  }) async {
    final current = _state;
    if (current.status == RemoteInputRuntimeStatus.idle ||
        current.sessionId.isEmpty) {
      return;
    }
    final session = _manager.session(current.sessionId);
    if (session != null) {
      sendControl(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.stop,
          sessionId: session.sessionId,
          sourcePeerId: session.sourcePeerId,
          sinkPeerId: session.sinkPeerId,
        ),
      );
    }
    await stopLocal();
  }

  Future<void> stopLocal() async {
    final current = _state;
    _trace(
      RemoteInputDiagnosticKind.stopped,
      state: current.status,
      role: current.role,
    );
    final transport = _transport;
    _transport = null;
    _keyTranslator = null;
    _pendingInjectionFrames.clear();
    _injectionPumpRunning = false;
    _latestSourceInputSequence = 0;
    _latestSourceActivationSequence = 0;
    _latestSinkPacketSequence = 0;
    _latestSinkActivationSequence = 0;
    _sinkEntryTravel = 0;
    _sinkSourcePlatform = RemoteInputPlatformKind.unknown;
    _sinkActiveEdgeMapping = null;
    if (_manager.onPacket != null) {
      _manager.onPacket = null;
    }
    await _inputSubscription?.cancel();
    await _releaseSubscription?.cancel();
    await _errorSubscription?.cancel();
    await _diagnosticSubscription?.cancel();
    await _transportDoneSubscription?.cancel();
    _inputSubscription = null;
    _releaseSubscription = null;
    _errorSubscription = null;
    _diagnosticSubscription = null;
    _transportDoneSubscription = null;
    if (current.sessionId.isNotEmpty) {
      if (current.role == RemoteInputRuntimeRole.source) {
        await _platform.stopCapture(sessionId: current.sessionId);
      }
      if (current.role == RemoteInputRuntimeRole.sink) {
        await _platform.stopInjection(sessionId: current.sessionId);
      }
      _manager.stopSession(current.sessionId);
    }
    await transport?.close();
    _setState(const RemoteInputRuntimeState.idle());
  }

  Future<void> _handleOffer(
    RemoteInputControlMessage offer, {
    required String localPeerId,
    required bool isMutuallyTrusted,
    required bool localCanInject,
    required RemoteInputControlSender sendControl,
    String remotePlatform = '',
  }) async {
    if (offer.sinkPeerId != localPeerId) {
      _trace(RemoteInputDiagnosticKind.offerIgnored);
      _manager.handleControlMessage(offer);
      return;
    }
    if (!isMutuallyTrusted || !localCanInject) {
      final failureReason = !isMutuallyTrusted
          ? RemoteInputFailureReason.trustRequired
          : RemoteInputFailureReason.injection;
      _trace(
        RemoteInputDiagnosticKind.offerRejected,
        reason: failureReason,
        allowed: isMutuallyTrusted,
        enabled: localCanInject,
      );
      sendControl(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.reject,
          sessionId: offer.sessionId,
          sourcePeerId: offer.sourcePeerId,
          sinkPeerId: offer.sinkPeerId,
          errorMessage: failureReason.name,
        ),
      );
      return;
    }
    if (_hasLiveSession && _state.sessionId != offer.sessionId) {
      _trace(
        RemoteInputDiagnosticKind.offerBusy,
        state: _state.status,
        role: _state.role,
        reason: RemoteInputFailureReason.busy,
      );
      sendControl(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.reject,
          sessionId: offer.sessionId,
          sourcePeerId: offer.sourcePeerId,
          sinkPeerId: offer.sinkPeerId,
          errorMessage: RemoteInputFailureReason.busy.name,
        ),
      );
      return;
    }

    final accept = _manager.acceptOffer(
      offer,
      sinkPlatform: _platformKindProvider().name,
    );
    if (accept.action == RemoteInputControlAction.error) {
      _trace(
        RemoteInputDiagnosticKind.offerAcceptFailed,
        reason: RemoteInputFailureReason.protocol,
      );
      sendControl(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.error,
          sessionId: accept.sessionId,
          sourcePeerId: accept.sourcePeerId,
          sinkPeerId: accept.sinkPeerId,
          errorMessage: RemoteInputFailureReason.protocol.name,
        ),
      );
      return;
    }
    try {
      _trace(RemoteInputDiagnosticKind.injectionStarting);
      await _startInjection(
        accept,
        sendControl: sendControl,
        remotePlatform: remotePlatform,
      );
      _trace(RemoteInputDiagnosticKind.acceptSent);
      sendControl(accept);
    } catch (error) {
      final failureReason = remoteInputFailureReasonFor(
        error,
        context: RemoteInputFailureContext.injection,
      );
      _trace(
        RemoteInputDiagnosticKind.injectionFailed,
        reason: failureReason,
        localError: error,
      );
      final failedPeerId = offer.sourcePeerId;
      await stopLocal();
      _setState(
        RemoteInputRuntimeState(
          status: RemoteInputRuntimeStatus.failed,
          role: RemoteInputRuntimeRole.sink,
          sessionId: offer.sessionId,
          peerId: failedPeerId,
          errorMessage: failureReason.name,
        ),
      );
      sendControl(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.error,
          sessionId: offer.sessionId,
          sourcePeerId: offer.sourcePeerId,
          sinkPeerId: offer.sinkPeerId,
          errorMessage: _state.errorMessage,
        ),
      );
    }
  }

  Future<void> _handleAccept(
    RemoteInputControlMessage accept, {
    required String localPeerId,
    required String remoteHost,
    required int remotePort,
    required RemoteInputControlSender sendControl,
    Uint8List? mediaSendKey,
  }) async {
    _manager.handleControlMessage(accept);
    if (accept.sourcePeerId != localPeerId) {
      _trace(RemoteInputDiagnosticKind.offerIgnored);
      return;
    }
    try {
      _trace(RemoteInputDiagnosticKind.captureStarting);
      await _startCapture(
        accept,
        remoteHost: remoteHost,
        remotePort: remotePort,
        sendControl: sendControl,
        mediaSendKey: mediaSendKey,
      );
    } catch (error) {
      final failureReason = remoteInputFailureReasonFor(
        error,
        context: RemoteInputFailureContext.capture,
      );
      _trace(
        RemoteInputDiagnosticKind.captureFailed,
        reason: failureReason,
        localError: error,
      );
      final failedPeerId = accept.sinkPeerId;
      await stopLocal();
      _setState(
        RemoteInputRuntimeState(
          status: RemoteInputRuntimeStatus.failed,
          role: RemoteInputRuntimeRole.source,
          sessionId: accept.sessionId,
          peerId: failedPeerId,
          errorMessage: failureReason.name,
        ),
      );
      sendControl(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.error,
          sessionId: accept.sessionId,
          sourcePeerId: accept.sourcePeerId,
          sinkPeerId: accept.sinkPeerId,
          errorMessage: _state.errorMessage,
        ),
      );
    }
  }

  Future<void> _startInjection(
    RemoteInputControlMessage message, {
    required RemoteInputControlSender sendControl,
    String remotePlatform = '',
  }) async {
    _trace(RemoteInputDiagnosticKind.injectionStarting);
    await stopLocal();
    _setState(
      RemoteInputRuntimeState(
        status: RemoteInputRuntimeStatus.connecting,
        role: RemoteInputRuntimeRole.sink,
        sessionId: message.sessionId,
        peerId: message.sourcePeerId,
      ),
    );
    await _platform.startInjection(
      sessionId: message.sessionId,
      displayId: message.sinkDisplayId,
      edge: message.sinkEdge ?? _oppositeEdge(message.layoutEdge),
      segmentStart: message.sinkSegmentStart,
      segmentEnd: message.sinkSegmentEnd,
      edgeMappings: message.edgeMappings,
    );
    _trace(RemoteInputDiagnosticKind.injectionStarted);
    final targetPlatform = _platformKindProvider();
    _keyTranslator = _keyTranslatorFactory(targetPlatform);
    _sinkSourcePlatform = _effectiveRemotePlatform(
      message.sourcePlatform,
      remotePlatform,
    );
    updateScrollMultiplier(await _loadScrollMultiplier());
    _latestSinkPacketSequence = 0;
    _latestSinkActivationSequence = 0;
    _sinkPacketTraceCount = 0;
    _sinkEntryTravel = 0;
    _sinkActiveEdgeMapping =
        message.edgeMappings.isNotEmpty ? message.edgeMappings.first : null;
    _releaseSubscription = _platform.releases.listen((release) {
      if (release.sessionId == message.sessionId) {
        if (release.reason == 'edge') {
          if (_isEarlySinkEdgeRelease(release)) {
            _trace(RemoteInputDiagnosticKind.earlyReleaseIgnored);
            return;
          }
          sendControl(
            RemoteInputControlMessage(
              action: RemoteInputControlAction.release,
              sessionId: message.sessionId,
              sourcePeerId: message.sourcePeerId,
              sinkPeerId: message.sinkPeerId,
              releaseReason: release.reason,
              releaseSequence: release.sequence > 0
                  ? release.sequence
                  : _latestSinkPacketSequence,
              releaseActivationSequence: release.activationSequence > 0
                  ? release.activationSequence
                  : _latestSinkActivationSequence,
              releaseEdgeUnit: _sourceReleaseEdgeUnit(
                sinkEdgeUnit: release.edgeUnit,
                sourceEdgeUnit: release.sourceEdgeUnit,
                message: message,
                routeId: release.routeId,
              ),
              sourceDisplayId: release.sourceDisplayId,
              sourceEdge: release.sourceEdge,
              sourceSegmentStart: release.sourceSegmentStart,
              sourceSegmentEnd: release.sourceSegmentEnd,
              routeId: release.routeId,
            ),
          );
        } else {
          unawaited(stopSharing(sendControl: sendControl));
        }
      }
    });
    _errorSubscription = _platform.errors.listen((error) {
      if (error.sessionId == message.sessionId) {
        _trace(
          RemoteInputDiagnosticKind.platformError,
          reason: RemoteInputFailureReason.injection,
        );
        unawaited(stopLocal());
      }
    });
    _diagnosticSubscription = _platform.diagnostics.listen((diagnostic) {
      if (diagnostic.sessionId == message.sessionId) {
        _trace(RemoteInputDiagnosticKind.platformDiagnostic);
      }
    });
    _manager.onPacket = (packet) {
      final routedPacket = _routeSinkActiveStartPacket(packet, message);
      if (packet.sessionId == message.sessionId &&
          packet.sequence > _latestSinkPacketSequence) {
        _latestSinkPacketSequence = packet.sequence;
      }
      if (packet.sessionId == message.sessionId &&
          _isActivationStartPacket(packet)) {
        _latestSinkActivationSequence = packet.sequence;
        _sinkEntryTravel = 0;
      } else if (packet.sessionId == message.sessionId &&
          _latestSinkActivationSequence > 0) {
        _sinkEntryTravel += _sinkEntryDelta(packet, message.layoutEdge);
      }
      final scrollNormalized = RemoteInputScrollNormalizer.normalizeForTarget(
        routedPacket,
        targetPlatform: targetPlatform,
        scrollMultiplier: _scrollMultiplier,
        fallbackSourcePlatform: _sinkSourcePlatform,
      );
      final translated = _keyTranslator?.translateFrame(scrollNormalized) ??
          <RemoteInputPacketFrame>[
            scrollNormalized,
          ];
      if (_shouldTracePackets && _sinkPacketTraceCount < _packetTraceLimit) {
        _sinkPacketTraceCount++;
        _trace(
          RemoteInputDiagnosticKind.packetObserved,
          direction: RemoteInputTraceDirection.sink,
          count: _sinkPacketTraceCount,
        );
      }
      _enqueueInjection(message.sessionId, translated);
    };
    _setState(
      RemoteInputRuntimeState(
        status: RemoteInputRuntimeStatus.active,
        role: RemoteInputRuntimeRole.sink,
        sessionId: message.sessionId,
        peerId: message.sourcePeerId,
      ),
    );
    _trace(RemoteInputDiagnosticKind.injectionActive);
  }

  bool _isEarlySinkEdgeRelease(PlatformRemoteInputRelease release) {
    final releaseSequence =
        release.sequence > 0 ? release.sequence : _latestSinkPacketSequence;
    final activationSequence = release.activationSequence > 0
        ? release.activationSequence
        : _latestSinkActivationSequence;
    return activationSequence > 0 &&
        releaseSequence > 0 &&
        _sinkEntryTravel < _sinkEntryReleaseDistance;
  }

  void _enqueueInjection(
    String sessionId,
    List<RemoteInputPacketFrame> frames,
  ) {
    for (final frame in frames) {
      if (frame.sessionId == sessionId) {
        _appendPendingInjectionFrame(frame);
      }
    }
    _startInjectionPump();
  }

  void _appendPendingInjectionFrame(RemoteInputPacketFrame frame) {
    if (_pendingInjectionFrames.isNotEmpty) {
      final previous = _pendingInjectionFrames.last;
      final coalesced = _coalesceQueuedMouseMove(previous, frame);
      if (coalesced != null) {
        _pendingInjectionFrames[_pendingInjectionFrames.length - 1] = coalesced;
        return;
      }
    }
    _pendingInjectionFrames.add(frame);
  }

  void _startInjectionPump() {
    if (_injectionPumpRunning) {
      return;
    }
    _injectionPumpRunning = true;
    unawaited(_drainInjectionQueue());
  }

  Future<void> _drainInjectionQueue() async {
    while (_pendingInjectionFrames.isNotEmpty) {
      final frame = _pendingInjectionFrames.removeAt(0);
      if (_state.role != RemoteInputRuntimeRole.sink ||
          _state.sessionId != frame.sessionId) {
        continue;
      }
      try {
        await _platform.injectEvent(frame);
      } catch (_) {}
    }
    _injectionPumpRunning = false;
    if (_pendingInjectionFrames.isNotEmpty) {
      _startInjectionPump();
    }
  }

  RemoteInputPacketFrame? _coalesceQueuedMouseMove(
    RemoteInputPacketFrame previous,
    RemoteInputPacketFrame next,
  ) {
    if (previous.sessionId != next.sessionId ||
        previous.eventType != RemoteInputEventType.mouseMove ||
        next.eventType != RemoteInputEventType.mouseMove) {
      return null;
    }
    final previousPayload = _mousePayload(previous);
    final nextPayload = _mousePayload(next);
    if (previousPayload == null || nextPayload == null) {
      return null;
    }
    if (previousPayload['activeStart'] == true ||
        nextPayload['activeStart'] == true) {
      return null;
    }
    final mergedPayload = Map<String, dynamic>.from(nextPayload);
    mergedPayload['activeStart'] = false;
    mergedPayload['deltaX'] = _numberPayload(previousPayload['deltaX']) +
        _numberPayload(nextPayload['deltaX']);
    mergedPayload['deltaY'] = _numberPayload(previousPayload['deltaY']) +
        _numberPayload(nextPayload['deltaY']);
    return RemoteInputPacketFrame(
      sessionId: next.sessionId,
      sequence: next.sequence,
      timestampMicros: next.timestampMicros,
      eventType: next.eventType,
      payload: Uint8List.fromList(utf8.encode(jsonEncode(mergedPayload))),
    );
  }

  Future<void> _startCapture(
    RemoteInputControlMessage message, {
    required String remoteHost,
    required int remotePort,
    required RemoteInputControlSender sendControl,
    Uint8List? mediaSendKey,
  }) async {
    final edge = message.layoutEdge;
    if (edge == null) {
      _trace(
        RemoteInputDiagnosticKind.captureMissingEdge,
        reason: RemoteInputFailureReason.protocol,
      );
      return;
    }
    final uri = _inputUri(
      host: remoteHost,
      port: remotePort,
      path: message.path,
      sessionId: message.sessionId,
      transportToken: message.transportToken,
    );
    _trace(RemoteInputDiagnosticKind.transportConnecting);
    _setState(
      RemoteInputRuntimeState(
        status: RemoteInputRuntimeStatus.connecting,
        role: RemoteInputRuntimeRole.source,
        sessionId: message.sessionId,
        peerId: message.sinkPeerId,
      ),
    );
    final transportFactory = _transportFactory;
    final RemoteInputPacketTransport transport;
    if (transportFactory != null) {
      transport = await transportFactory(uri);
    } else {
      if (message.transportToken.isEmpty || mediaSendKey == null) {
        throw StateError('authenticated remote input context missing');
      }
      transport = await RemoteInputWebSocketPacketTransport.connect(
        uri,
        mediaMacKey: mediaSendKey,
        sessionId: message.sessionId,
      );
    }
    _transport = transport;
    _transportDoneSubscription = _listenForSourceTransportDone(
      transport,
      sessionId: message.sessionId,
    );
    _trace(RemoteInputDiagnosticKind.transportConnected);
    _latestSourceInputSequence = 0;
    _latestSourceActivationSequence = 0;
    _sourcePacketTraceCount = 0;
    _inputSubscription = _platform.inputEvents.listen((event) {
      if (event.sessionId != message.sessionId) {
        return;
      }
      final annotated = RemoteInputScrollNormalizer.annotateSourceFrame(
        event,
        sourcePlatform: _platformKindProvider(),
      );
      if (_shouldTracePackets && _sourcePacketTraceCount < _packetTraceLimit) {
        _sourcePacketTraceCount++;
        _trace(
          RemoteInputDiagnosticKind.packetObserved,
          direction: RemoteInputTraceDirection.source,
          count: _sourcePacketTraceCount,
        );
      }
      if (event.sequence > _latestSourceInputSequence) {
        _latestSourceInputSequence = event.sequence;
      }
      if (_isActivationStartPacket(event)) {
        _latestSourceActivationSequence = event.sequence;
      }
      transport.send(annotated);
      if (_state.status == RemoteInputRuntimeStatus.armed) {
        _setState(
          RemoteInputRuntimeState(
            status: RemoteInputRuntimeStatus.active,
            role: RemoteInputRuntimeRole.source,
            sessionId: message.sessionId,
            peerId: message.sinkPeerId,
          ),
        );
      }
    });
    _releaseSubscription = _platform.releases.listen((release) {
      if (release.sessionId == message.sessionId) {
        unawaited(stopSharing(sendControl: sendControl));
      }
    });
    _errorSubscription = _platform.errors.listen((error) {
      if (error.sessionId == message.sessionId) {
        _trace(
          RemoteInputDiagnosticKind.platformError,
          reason: RemoteInputFailureReason.capture,
        );
        unawaited(stopLocal());
      }
    });
    _diagnosticSubscription = _platform.diagnostics.listen((diagnostic) {
      if (diagnostic.sessionId == message.sessionId) {
        _trace(RemoteInputDiagnosticKind.platformDiagnostic);
      }
    });
    await _platform.startCapture(
      sessionId: message.sessionId,
      edge: message.sourceEdge ?? edge,
      releaseHotkey: message.releaseHotkey,
      displayId: message.sourceDisplayId,
      segmentStart: message.sourceSegmentStart,
      segmentEnd: message.sourceSegmentEnd,
      edgeMappings: message.edgeMappings,
    );
    _trace(RemoteInputDiagnosticKind.captureStarted);
    _setState(
      RemoteInputRuntimeState(
        status: RemoteInputRuntimeStatus.armed,
        role: RemoteInputRuntimeRole.source,
        sessionId: message.sessionId,
        peerId: message.sinkPeerId,
      ),
    );
  }

  StreamSubscription<void>? _listenForSourceTransportDone(
    RemoteInputPacketTransport transport, {
    required String sessionId,
  }) {
    if (transport is! RemoteInputObservablePacketTransport) {
      return null;
    }
    return transport.done.listen((_) {
      if (_state.role != RemoteInputRuntimeRole.source ||
          _state.sessionId != sessionId) {
        return;
      }
      _trace(RemoteInputDiagnosticKind.transportClosed);
      unawaited(stopLocal());
    });
  }

  Future<void> _handleRelease(RemoteInputControlMessage message) async {
    _manager.handleControlMessage(message);
    if (_state.sessionId != message.sessionId ||
        _state.role != RemoteInputRuntimeRole.source ||
        message.releaseReason != 'edge') {
      return;
    }
    if (message.releaseActivationSequence > 0 &&
        _latestSourceActivationSequence > message.releaseActivationSequence) {
      _trace(RemoteInputDiagnosticKind.staleReleaseIgnored);
      return;
    }
    await _platform.pauseCapture(
      sessionId: message.sessionId,
      releaseSequence: message.releaseSequence,
      releaseActivationSequence: message.releaseActivationSequence,
      releaseEdgeUnit: message.releaseEdgeUnit,
      displayId: message.sourceDisplayId,
      edge: message.sourceEdge,
      segmentStart: message.sourceSegmentStart,
      segmentEnd: message.sourceSegmentEnd,
      routeId: message.routeId,
    );
    _setState(
      RemoteInputRuntimeState(
        status: RemoteInputRuntimeStatus.armed,
        role: RemoteInputRuntimeRole.source,
        sessionId: message.sessionId,
        peerId: _state.peerId,
      ),
    );
  }

  RemoteInputPacketFrame _routeSinkActiveStartPacket(
    RemoteInputPacketFrame packet,
    RemoteInputControlMessage message,
  ) {
    if (packet.sessionId != message.sessionId ||
        packet.eventType != RemoteInputEventType.mouseMove ||
        message.edgeMappings.isEmpty) {
      return packet;
    }
    final payload = _mousePayload(packet);
    if (payload == null || payload['activeStart'] != true) {
      return packet;
    }
    final sourceEdge = _sourceEdgeForPayload(payload) ??
        message.sourceEdge ??
        message.layoutEdge;
    if (sourceEdge == null) {
      return packet;
    }
    final sourceCoordinate = _sourceCoordinateForPayload(
      payload,
      message,
      sourceEdge: sourceEdge,
    );
    final routeId = payload['routeId'] as String? ?? '';
    final routeMapping = routeId.isNotEmpty
        ? _edgeMappingForRouteId(routeId, message.edgeMappings)
        : null;
    final coordinateMapping = sourceCoordinate == null
        ? null
        : _edgeMappingForSourceCoordinate(
            sourceCoordinate,
            message.edgeMappings,
            sourceEdge: sourceEdge,
          );
    final mapping = routeMapping ?? coordinateMapping;
    if (mapping == null) {
      return packet;
    }
    final routeEdgeUnit = routeMapping != null && payload['edgeUnit'] is num
        ? _numberPayload(payload['edgeUnit']).clamp(0, 1).toDouble()
        : null;
    final mappedSourceCoordinate = routeEdgeUnit == null
        ? sourceCoordinate ??
            _sourceCoordinateForPayload(
              payload,
              message,
              sourceEdge: mapping.sourceEdge,
            )
        : null;
    if (routeEdgeUnit == null && mappedSourceCoordinate == null) {
      return packet;
    }
    _sinkActiveEdgeMapping = mapping;
    final routedPayload = Map<String, dynamic>.from(payload);
    routedPayload['edgeUnit'] = routeEdgeUnit ??
        mapping.edgeUnitForSourceCoordinate(mappedSourceCoordinate!);
    routedPayload['routeId'] = mapping.effectiveRouteId;
    routedPayload['sinkDisplayId'] = mapping.sinkDisplayId;
    routedPayload['sinkEdge'] = mapping.sinkEdge.name;
    routedPayload['sinkSegmentStart'] = mapping.sinkSegmentStart;
    routedPayload['sinkSegmentEnd'] = mapping.sinkSegmentEnd;
    return RemoteInputPacketFrame(
      sessionId: packet.sessionId,
      sequence: packet.sequence,
      timestampMicros: packet.timestampMicros,
      eventType: packet.eventType,
      payload: Uint8List.fromList(utf8.encode(jsonEncode(routedPayload))),
    );
  }

  double? _sourceCoordinateForPayload(
    Map<String, dynamic> payload,
    RemoteInputControlMessage message, {
    required RemoteInputEdge sourceEdge,
  }) {
    final value = sourceEdge == RemoteInputEdge.left ||
            sourceEdge == RemoteInputEdge.right
        ? payload['y']
        : payload['x'];
    if (value is num) {
      return value.toDouble();
    }
    if (message.sourceSegmentEnd > message.sourceSegmentStart &&
        payload['edgeUnit'] is num) {
      final edgeUnit =
          _numberPayload(payload['edgeUnit']).clamp(0, 1).toDouble();
      final matchingMappings = message.edgeMappings
          .where((mapping) => mapping.sourceEdge == sourceEdge)
          .toList(growable: false);
      if (matchingMappings.length == 1) {
        return matchingMappings.single.sourceCoordinateForEdgeUnit(edgeUnit);
      }
      return message.sourceSegmentStart +
          (message.sourceSegmentEnd - message.sourceSegmentStart) * edgeUnit;
    }
    return null;
  }

  RemoteInputEdgeMapping? _edgeMappingForRouteId(
    String routeId,
    List<RemoteInputEdgeMapping> mappings,
  ) {
    for (final mapping in mappings) {
      if (mapping.effectiveRouteId == routeId) {
        return mapping;
      }
    }
    return null;
  }

  RemoteInputEdgeMapping? _edgeMappingForSourceCoordinate(
    double coordinate,
    List<RemoteInputEdgeMapping> mappings, {
    required RemoteInputEdge sourceEdge,
  }) {
    for (final mapping in mappings) {
      if (mapping.sourceEdge != sourceEdge) {
        continue;
      }
      if (mapping.containsSourceCoordinate(coordinate, tolerance: 1)) {
        return mapping;
      }
    }
    return null;
  }

  RemoteInputEdge? _sourceEdgeForPayload(Map<String, dynamic> payload) {
    final edgeName = payload['edge'];
    if (edgeName is! String) {
      return null;
    }
    for (final edge in RemoteInputEdge.values) {
      if (edge.name == edgeName) {
        return edge;
      }
    }
    return null;
  }

  double _sourceReleaseEdgeUnit({
    required double sinkEdgeUnit,
    required bool sourceEdgeUnit,
    required RemoteInputControlMessage message,
    required String routeId,
  }) {
    if (sourceEdgeUnit) {
      return sinkEdgeUnit;
    }
    final routeMapping = routeId.isNotEmpty
        ? _edgeMappingForRouteId(routeId, message.edgeMappings)
        : null;
    final mapping = routeMapping ?? _sinkActiveEdgeMapping;
    if (mapping == null ||
        message.sourceSegmentEnd <= message.sourceSegmentStart) {
      return sinkEdgeUnit;
    }
    final sourceCoordinate = mapping.sourceCoordinateForEdgeUnit(sinkEdgeUnit);
    final sourceLength = message.sourceSegmentEnd - message.sourceSegmentStart;
    return ((sourceCoordinate - message.sourceSegmentStart) / sourceLength)
        .clamp(0, 1)
        .toDouble();
  }

  bool _isActivationStartPacket(RemoteInputPacketFrame packet) {
    if (packet.eventType != RemoteInputEventType.mouseMove) {
      return false;
    }
    final payload = _mousePayload(packet);
    return payload != null && payload['activeStart'] == true;
  }

  double _sinkEntryDelta(
    RemoteInputPacketFrame packet,
    RemoteInputEdge? layoutEdge,
  ) {
    if (packet.eventType != RemoteInputEventType.mouseMove) {
      return 0;
    }
    final payload = _mousePayload(packet);
    if (payload == null) {
      return 0;
    }
    final deltaX = _numberPayload(payload['deltaX']);
    final deltaY = _numberPayload(payload['deltaY']);
    final edge = (payload['edge'] as String?) ?? layoutEdge?.name ?? 'right';
    switch (edge) {
      case 'left':
        return deltaX < 0 ? -deltaX : 0;
      case 'top':
        return deltaY < 0 ? -deltaY : 0;
      case 'bottom':
        return deltaY > 0 ? deltaY : 0;
      case 'right':
      default:
        return deltaX > 0 ? deltaX : 0;
    }
  }

  Map<String, dynamic>? _mousePayload(RemoteInputPacketFrame packet) {
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

  double _numberPayload(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return 0;
  }

  RemoteInputEdge? _oppositeEdge(RemoteInputEdge? edge) {
    switch (edge) {
      case RemoteInputEdge.left:
        return RemoteInputEdge.right;
      case RemoteInputEdge.right:
        return RemoteInputEdge.left;
      case RemoteInputEdge.top:
        return RemoteInputEdge.bottom;
      case RemoteInputEdge.bottom:
        return RemoteInputEdge.top;
      case null:
        return null;
    }
  }

  Uri _inputUri({
    required String host,
    required int port,
    required String path,
    required String sessionId,
    required String transportToken,
  }) {
    final normalizedPath = path.isEmpty ? '/input' : path;
    return buildPeerPacketUri(
      host: host,
      port: port,
      path: normalizedPath,
      queryParameters: <String, String>{
        if (transportToken.isNotEmpty) 'session': sessionId,
        if (transportToken.isNotEmpty) 'token': transportToken,
      },
    );
  }

  RemoteInputPlatformKind _effectiveRemotePlatform(
    String declaredPlatform,
    String fallbackPlatform,
  ) {
    final declared = remoteInputPlatformKindFromString(declaredPlatform);
    if (declared != RemoteInputPlatformKind.unknown) {
      return declared;
    }
    return remoteInputPlatformKindFromString(fallbackPlatform);
  }

  Future<double> _loadScrollMultiplier() async {
    try {
      return await _scrollMultiplierProvider();
    } catch (error) {
      _trace(
        RemoteInputDiagnosticKind.settingFallback,
        localError: error,
      );
      return 1.0;
    }
  }

  void _setState(RemoteInputRuntimeState state) {
    _trace(
      RemoteInputDiagnosticKind.stateChanged,
      state: state.status,
      role: state.role,
    );
    _state = state;
    notifyListeners();
  }
}
