import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

typedef RemoteInputControlSender = void Function(
  RemoteInputControlMessage control,
);
typedef RemoteInputTransportFactory = Future<RemoteInputPacketTransport>
    Function(Uri uri);

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
  })  : _manager = manager ?? RemoteInputManager.shared,
        _platform = platform ?? RemoteInputPlatform(),
        _transportFactory =
            transportFactory ?? RemoteInputWebSocketPacketTransport.connect;

  static final RemoteInputCoordinator shared = RemoteInputCoordinator();

  final RemoteInputManager _manager;
  final RemoteInputPlatform _platform;
  final RemoteInputTransportFactory _transportFactory;

  RemoteInputRuntimeState _state = const RemoteInputRuntimeState.idle();
  RemoteInputPacketTransport? _transport;
  StreamSubscription<RemoteInputPacketFrame>? _inputSubscription;
  StreamSubscription<PlatformRemoteInputRelease>? _releaseSubscription;
  StreamSubscription<PlatformRemoteInputError>? _errorSubscription;

  RemoteInputRuntimeState get state => _state;

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
  }) async {
    await stopLocal();
    if (!isMutuallyTrusted || !remoteCanInject) {
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
    );
    _setState(
      RemoteInputRuntimeState(
        status: RemoteInputRuntimeStatus.offering,
        role: RemoteInputRuntimeRole.source,
        sessionId: offer.sessionId,
        peerId: sinkPeerId,
      ),
    );
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
  }) async {
    switch (message.action) {
      case RemoteInputControlAction.offer:
        await _handleOffer(
          message,
          localPeerId: localPeerId,
          isMutuallyTrusted: isMutuallyTrusted,
          localCanInject: localCanInject,
          sendControl: sendControl,
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
        _manager.handleControlMessage(message);
        if (_state.sessionId == message.sessionId) {
          await stopLocal();
        }
        break;
      case RemoteInputControlAction.error:
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
    final transport = _transport;
    _transport = null;
    if (_manager.onPacket != null) {
      _manager.onPacket = null;
    }
    await _inputSubscription?.cancel();
    await _releaseSubscription?.cancel();
    await _errorSubscription?.cancel();
    _inputSubscription = null;
    _releaseSubscription = null;
    _errorSubscription = null;
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
  }) async {
    if (offer.sinkPeerId != localPeerId) {
      _manager.handleControlMessage(offer);
      return;
    }
    if (!isMutuallyTrusted || !localCanInject) {
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

    final accept = _manager.acceptOffer(offer);
    if (accept.action == RemoteInputControlAction.error) {
      sendControl(accept);
      return;
    }
    try {
      await _startInjection(accept, sendControl: sendControl);
      sendControl(accept);
    } catch (error) {
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
      return;
    }
    try {
      await _startCapture(
        accept,
        remoteHost: remoteHost,
        remotePort: remotePort,
        sendControl: sendControl,
      );
    } catch (error) {
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
  }) async {
    await stopLocal();
    _setState(
      RemoteInputRuntimeState(
        status: RemoteInputRuntimeStatus.connecting,
        role: RemoteInputRuntimeRole.sink,
        sessionId: message.sessionId,
        peerId: message.sourcePeerId,
      ),
    );
    await _platform.startInjection(sessionId: message.sessionId);
    _releaseSubscription = _platform.releases.listen((release) {
      if (release.sessionId == message.sessionId) {
        if (release.reason == 'edge') {
          sendControl(
            RemoteInputControlMessage(
              action: RemoteInputControlAction.release,
              sessionId: message.sessionId,
              sourcePeerId: message.sourcePeerId,
              sinkPeerId: message.sinkPeerId,
              releaseReason: release.reason,
            ),
          );
        } else {
          unawaited(stopSharing(sendControl: sendControl));
        }
      }
    });
    _errorSubscription = _platform.errors.listen((error) {
      if (error.sessionId == message.sessionId) {
        unawaited(stopLocal());
      }
    });
    _manager.onPacket = (packet) {
      unawaited(_platform.injectEvent(packet));
    };
    _setState(
      RemoteInputRuntimeState(
        status: RemoteInputRuntimeStatus.active,
        role: RemoteInputRuntimeRole.sink,
        sessionId: message.sessionId,
        peerId: message.sourcePeerId,
      ),
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
      return;
    }
    _setState(
      RemoteInputRuntimeState(
        status: RemoteInputRuntimeStatus.connecting,
        role: RemoteInputRuntimeRole.source,
        sessionId: message.sessionId,
        peerId: message.sinkPeerId,
      ),
    );
    final transport = await _transportFactory(
      _inputUri(
        host: remoteHost,
        port: remotePort,
        path: message.path,
      ),
    );
    _transport = transport;
    _inputSubscription = _platform.inputEvents.listen((event) {
      if (event.sessionId != message.sessionId) {
        return;
      }
      transport.send(event);
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
        unawaited(stopLocal());
      }
    });
    await _platform.startCapture(
      sessionId: message.sessionId,
      edge: edge,
      releaseHotkey: message.releaseHotkey,
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

  Future<void> _handleRelease(RemoteInputControlMessage message) async {
    _manager.handleControlMessage(message);
    if (_state.sessionId != message.sessionId ||
        _state.role != RemoteInputRuntimeRole.source ||
        message.releaseReason != 'edge') {
      return;
    }
    await _platform.pauseCapture(sessionId: message.sessionId);
    _setState(
      RemoteInputRuntimeState(
        status: RemoteInputRuntimeStatus.armed,
        role: RemoteInputRuntimeRole.source,
        sessionId: message.sessionId,
        peerId: _state.peerId,
      ),
    );
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

  void _setState(RemoteInputRuntimeState state) {
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
