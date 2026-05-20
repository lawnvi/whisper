import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_scroll.dart';

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
        _transportFactory =
            transportFactory ?? RemoteInputWebSocketPacketTransport.connect,
        _keyTranslatorFactory = keyTranslatorFactory ??
            ((platform) => RemoteInputKeyTranslator(targetPlatform: platform)),
        _platformKindProvider =
            platformKindProvider ?? currentRemoteInputPlatformKind,
        _scrollMultiplierProvider = scrollMultiplierProvider ??
            LocalSetting().remoteInputScrollMultiplier;

  static final RemoteInputCoordinator shared = RemoteInputCoordinator();
  static const double _sinkEntryReleaseDistance = 16;
  static const int _packetTraceLimit = 40;

  final RemoteInputManager _manager;
  final RemoteInputPlatform _platform;
  final RemoteInputTransportFactory _transportFactory;
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

  String _shortSessionId(String sessionId) {
    if (sessionId.length <= 8) {
      return sessionId;
    }
    return sessionId.substring(0, 8);
  }

  String _stateSummary(RemoteInputRuntimeState state) {
    return '${state.role.name}/${state.status.name} '
        'session=${_shortSessionId(state.sessionId)} '
        'peer=${state.peerId} '
        'error=${state.errorMessage}';
  }

  String _controlSummary(RemoteInputControlMessage message) {
    return 'action=${message.action.name} '
        'session=${_shortSessionId(message.sessionId)} '
        'source=${message.sourcePeerId} '
        'sink=${message.sinkPeerId} '
        'edge=${message.layoutEdge?.name ?? '-'} '
        'path=${message.path} '
        'sourcePlatform=${message.sourcePlatform} '
        'sinkPlatform=${message.sinkPlatform} '
        'reason=${message.releaseReason} '
        'error=${message.errorMessage}';
  }

  void _trace(String message) {
    logger.i(message);
    if (_shouldPrintTrace) {
      debugPrint(message);
    }
  }

  void _tracePacket(String message) {
    if (_shouldPrintTrace) {
      _trace(message);
    }
  }

  bool get _shouldPrintTrace =>
      !kReleaseMode ||
      Platform.environment['WHISPER_REMOTE_INPUT_TRACE'] == '1';

  String _packetSummary(RemoteInputPacketFrame packet) {
    final payload = _mousePayload(packet);
    if (payload == null) {
      return 'session=${_shortSessionId(packet.sessionId)} '
          'seq=${packet.sequence} type=${packet.eventType.name}';
    }
    return 'session=${_shortSessionId(packet.sessionId)} '
        'seq=${packet.sequence} type=${packet.eventType.name} '
        'dx=${_numberPayload(payload['deltaX'])} '
        'dy=${_numberPayload(payload['deltaY'])} '
        'activeStart=${payload['activeStart'] == true} '
        'edge=${payload['edge'] ?? '-'} '
        'unitX=${_numberPayload(payload['unitX']).toStringAsFixed(3)} '
        'unitY=${_numberPayload(payload['unitY']).toStringAsFixed(3)}';
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
      'remote input start share requested source=$sourcePeerId '
      'sink=$sinkPeerId sinkAddress=$sinkHost:$sinkPort '
      'edge=${layoutEdge.name} mutualTrust=$isMutuallyTrusted '
      'remoteCanInject=$remoteCanInject state=${_stateSummary(_state)}',
    );
    await stopLocal();
    if (!isMutuallyTrusted || !remoteCanInject) {
      _trace(
        'remote input start share rejected locally mutualTrust=$isMutuallyTrusted '
        'remoteCanInject=$remoteCanInject sink=$sinkPeerId',
      );
      _setState(
        RemoteInputRuntimeState(
          status: RemoteInputRuntimeStatus.failed,
          role: RemoteInputRuntimeRole.none,
          peerId: sinkPeerId,
          errorMessage: !isMutuallyTrusted
              ? 'Remote input requires mutual trust'
              : 'Peer does not support remote input',
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
    _trace('remote input created offer ${_controlSummary(offer)}');
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
  }) async {
    _trace(
      'remote input coordinator handling ${_controlSummary(message)} '
      'local=$localPeerId remoteAddress=$remoteHost:$remotePort '
      'mutualTrust=$isMutuallyTrusted localCanInject=$localCanInject '
      'state=${_stateSummary(_state)}',
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
        );
        break;
      case RemoteInputControlAction.release:
        await _handleRelease(message);
        break;
      case RemoteInputControlAction.stop:
      case RemoteInputControlAction.reject:
        _trace(
            'remote input received ${message.action.name} ${_controlSummary(message)}');
        _manager.handleControlMessage(message);
        if (_state.sessionId == message.sessionId) {
          await stopLocal();
        }
        break;
      case RemoteInputControlAction.error:
        _trace('remote input received error ${_controlSummary(message)}');
        _manager.handleControlMessage(message);
        if (_state.sessionId == message.sessionId) {
          await stopLocal();
          _setState(
            RemoteInputRuntimeState(
              status: RemoteInputRuntimeStatus.failed,
              role: RemoteInputRuntimeRole.none,
              sessionId: message.sessionId,
              peerId: _state.peerId,
              errorMessage: message.errorMessage,
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
    _trace('remote input stop local current=${_stateSummary(current)}');
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
      _trace(
        'remote input offer ignored for different sink '
        '${_controlSummary(offer)} local=$localPeerId',
      );
      _manager.handleControlMessage(offer);
      return;
    }
    if (!isMutuallyTrusted || !localCanInject) {
      _trace(
        'remote input offer rejected ${_controlSummary(offer)} '
        'mutualTrust=$isMutuallyTrusted localCanInject=$localCanInject',
      );
      sendControl(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.reject,
          sessionId: offer.sessionId,
          sourcePeerId: offer.sourcePeerId,
          sinkPeerId: offer.sinkPeerId,
          errorMessage: !isMutuallyTrusted
              ? 'Remote input requires mutual trust'
              : 'Local device cannot inject input',
        ),
      );
      return;
    }
    if (_hasLiveSession && _state.sessionId != offer.sessionId) {
      _trace(
        'remote input offer rejected because local session is busy '
        '${_controlSummary(offer)} state=${_stateSummary(_state)}',
      );
      sendControl(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.reject,
          sessionId: offer.sessionId,
          sourcePeerId: offer.sourcePeerId,
          sinkPeerId: offer.sinkPeerId,
          errorMessage: 'Remote input session already active',
        ),
      );
      return;
    }

    final accept = _manager.acceptOffer(
      offer,
      sinkPlatform: _platformKindProvider().name,
    );
    if (accept.action == RemoteInputControlAction.error) {
      _trace('remote input offer accept failed ${_controlSummary(accept)}');
      sendControl(accept);
      return;
    }
    try {
      _trace('remote input starting injection for ${_controlSummary(accept)}');
      await _startInjection(
        accept,
        sendControl: sendControl,
        remotePlatform: remotePlatform,
      );
      _trace('remote input sending accept ${_controlSummary(accept)}');
      sendControl(accept);
    } catch (error) {
      _trace('remote input start injection failed $error');
      final failedPeerId = offer.sourcePeerId;
      await stopLocal();
      _setState(
        RemoteInputRuntimeState(
          status: RemoteInputRuntimeStatus.failed,
          role: RemoteInputRuntimeRole.sink,
          sessionId: offer.sessionId,
          peerId: failedPeerId,
          errorMessage: _friendlyErrorMessage(error),
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
  }) async {
    _manager.handleControlMessage(accept);
    if (accept.sourcePeerId != localPeerId) {
      _trace(
        'remote input accept ignored for different source '
        '${_controlSummary(accept)} local=$localPeerId',
      );
      return;
    }
    try {
      _trace(
        'remote input starting capture for ${_controlSummary(accept)} '
        'remoteAddress=$remoteHost:$remotePort',
      );
      await _startCapture(
        accept,
        remoteHost: remoteHost,
        remotePort: remotePort,
        sendControl: sendControl,
      );
    } catch (error) {
      _trace('remote input start capture failed $error');
      final failedPeerId = accept.sinkPeerId;
      await stopLocal();
      _setState(
        RemoteInputRuntimeState(
          status: RemoteInputRuntimeStatus.failed,
          role: RemoteInputRuntimeRole.source,
          sessionId: accept.sessionId,
          peerId: failedPeerId,
          errorMessage: _friendlyErrorMessage(error),
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
    _trace('remote input _startInjection ${_controlSummary(message)}');
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
    _trace(
      'remote input platform startInjection returned '
      'session=${_shortSessionId(message.sessionId)}',
    );
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
            _trace(
              'remote input ignored early sink edge release '
              'releaseSequence=${release.sequence} '
              'latestSinkPacketSequence=$_latestSinkPacketSequence '
              'activationSequence=${release.activationSequence} '
              'latestSinkActivationSequence=$_latestSinkActivationSequence '
              'sinkEntryTravel=$_sinkEntryTravel',
            );
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
        _trace('remote input platform injection error ${error.message}');
        unawaited(stopLocal());
      }
    });
    _diagnosticSubscription = _platform.diagnostics.listen((diagnostic) {
      if (diagnostic.sessionId == message.sessionId) {
        _trace('remote input diagnostic: ${diagnostic.message}');
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
      if (_sinkPacketTraceCount < _packetTraceLimit) {
        _sinkPacketTraceCount++;
        _tracePacket(
          'remote input sink packet ${_packetSummary(scrollNormalized)}',
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
    _trace('remote input injection active ${_controlSummary(message)}');
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
  }) async {
    final edge = message.layoutEdge;
    if (edge == null) {
      _trace(
          'remote input capture skipped without edge ${_controlSummary(message)}');
      return;
    }
    final uri = _inputUri(
      host: remoteHost,
      port: remotePort,
      path: message.path,
    );
    _trace('remote input _startCapture ${_controlSummary(message)} uri=$uri');
    _setState(
      RemoteInputRuntimeState(
        status: RemoteInputRuntimeStatus.connecting,
        role: RemoteInputRuntimeRole.source,
        sessionId: message.sessionId,
        peerId: message.sinkPeerId,
      ),
    );
    final transport = await _transportFactory(
      uri,
    );
    _transport = transport;
    _transportDoneSubscription = _listenForSourceTransportDone(
      transport,
      sessionId: message.sessionId,
    );
    _trace(
      'remote input transport connected session=${_shortSessionId(message.sessionId)}',
    );
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
      if (_sourcePacketTraceCount < _packetTraceLimit) {
        _sourcePacketTraceCount++;
        _tracePacket('remote input source packet ${_packetSummary(annotated)}');
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
        _trace('remote input platform capture error ${error.message}');
        unawaited(stopLocal());
      }
    });
    _diagnosticSubscription = _platform.diagnostics.listen((diagnostic) {
      if (diagnostic.sessionId == message.sessionId) {
        _trace('remote input diagnostic: ${diagnostic.message}');
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
    _trace(
      'remote input platform startCapture returned '
      'session=${_shortSessionId(message.sessionId)} edge=${edge.name}',
    );
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
      _trace(
        'remote input packet transport closed '
        'session=${_shortSessionId(sessionId)}',
      );
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
      _trace(
        'remote input ignored stale edge release '
        'releaseActivationSequence=${message.releaseActivationSequence} '
        'latestSourceActivationSequence=$_latestSourceActivationSequence',
      );
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
  }) {
    final normalizedPath = path.isEmpty ? '/input' : path;
    return Uri(
      scheme: 'ws',
      host: host,
      port: port,
      path: normalizedPath.startsWith('/')
          ? normalizedPath.substring(1)
          : normalizedPath,
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
      _trace('remote input scroll multiplier fallback after error $error');
      return 1.0;
    }
  }

  void _setState(RemoteInputRuntimeState state) {
    _trace(
      'remote input state ${_stateSummary(_state)} -> ${_stateSummary(state)}',
    );
    _state = state;
    notifyListeners();
  }

  String _friendlyErrorMessage(Object error) {
    if (error is PlatformException) {
      return error.message?.trim().isNotEmpty == true
          ? error.message!.trim()
          : error.code;
    }
    final text = error.toString();
    const platformPrefix = 'PlatformException(';
    if (!text.startsWith(platformPrefix)) {
      return text;
    }
    final parts = text
        .substring(platformPrefix.length, text.length - 1)
        .split(',')
        .map((part) => part.trim())
        .toList(growable: false);
    if (parts.length >= 2 && parts[1].isNotEmpty) {
      return parts[1];
    }
    return text;
  }
}
