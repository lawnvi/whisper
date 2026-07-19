import 'dart:async';

import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/peer_socket_session.dart';

typedef AuthLifecycleFailure = Future<void> Function(
  Object error,
  StackTrace stackTrace,
);

final class AuthHandshakeLifecycle {
  const AuthHandshakeLifecycle._();

  /// Keeps a signed allow result local until persistence, AEAD activation, and
  /// peer registration represented by [commit] have all completed.
  static Future<bool> completeServerAllow<T>({
    required Future<T> Function() commit,
    required Future<void> Function(T value) sendAllow,
    required FutureOr<void> Function(T value) onAuthenticated,
    required AuthLifecycleFailure onFailure,
  }) async {
    try {
      final value = await commit();
      await sendAllow(value);
      await onAuthenticated(value);
      return true;
    } catch (error, stackTrace) {
      await onFailure(error, stackTrace);
      return false;
    }
  }

  static Future<bool> resolveGuarded({
    required Future<void> Function() resolve,
    required AuthLifecycleFailure onFailure,
  }) async {
    try {
      await resolve();
      return true;
    } catch (error, stackTrace) {
      await onFailure(error, stackTrace);
      return false;
    }
  }
}

final class AuthSocketLifecycle {
  const AuthSocketLifecycle._();

  static void closeBeforeQueuedCleanup(
    PeerSocketSession? session,
    void Function() queueCleanup,
  ) {
    session?.close();
    queueCleanup();
  }

  static bool hasConnectionWork({
    required bool hasSelectedSink,
    required bool hasClientTimer,
    required bool hasPendingSessions,
    required bool hasPendingResults,
    required bool hasPeerConnections,
    required bool hasReceiver,
  }) {
    return hasSelectedSink ||
        hasClientTimer ||
        hasPendingSessions ||
        hasPendingResults ||
        hasPeerConnections ||
        hasReceiver;
  }

  static void closePendingAuth({
    required Iterable<PeerSocketSession> sessions,
    required Iterable<void Function()> completeFailures,
  }) {
    for (final completeFailure in completeFailures) {
      completeFailure();
    }
    for (final session in sessions) {
      if (!session.isAuthenticated) {
        session.close();
      }
    }
  }

  static Future<bool> removeConnectionIfCurrent({
    required PeerConnectionRegistry connections,
    required String peerId,
    required PeerSocketSession? closingSession,
    required PeerSocketSession? currentSession,
    FutureOr<void> Function(TransferConnectionBinding binding)? afterRemove,
  }) {
    // Identity is checked as well as the numeric generation so a late onDone
    // from a replaced socket cannot remove the replacement.
    if (!isCurrentSession(
      closingSession: closingSession,
      currentSession: currentSession,
    )) {
      return Future<bool>.value(false);
    }
    return connections.removeIfCurrent(
      TransferConnectionBinding(
        peerId: peerId,
        generation: closingSession!.connectionGeneration,
      ),
      afterRemove: afterRemove,
    );
  }

  static bool isCurrentSession({
    required PeerSocketSession? closingSession,
    required PeerSocketSession? currentSession,
  }) {
    return closingSession != null && identical(closingSession, currentSession);
  }
}
