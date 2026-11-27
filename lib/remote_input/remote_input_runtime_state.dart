/// What keyboard and mouse sharing is doing on this device, as the
/// coordinator reports it.
enum RemoteInputRuntimeRole { none, source, sink }

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
  injectionBlocked,
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
