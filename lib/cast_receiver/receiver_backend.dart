import 'dart:io';

enum CastReceiverState { stopped, starting, running, unavailable, failed }

enum CastReceiverIssue { noLanAddress, startupFailed }

typedef CastReceiverEndpoint = (InternetAddress, NetworkInterface);

class CastReceiverStatus {
  const CastReceiverStatus(this.state, {this.issue});

  final CastReceiverState state;
  final CastReceiverIssue? issue;
}

abstract class ReceiverBackend {
  CastReceiverStatus status = const CastReceiverStatus(
    CastReceiverState.stopped,
  );
  void Function()? onChanged;

  void update(CastReceiverState state, {CastReceiverIssue? issue}) {
    if (status.state == state && status.issue == issue) return;
    status = CastReceiverStatus(state, issue: issue);
    onChanged?.call();
  }

  Future<void> start(CastReceiverEndpoint? endpoint);
  Future<void> stop();
  void updateName(String name) {}
}
