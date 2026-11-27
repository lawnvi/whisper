import 'dart:async';

import 'package:whisper/state/peer_endpoint.dart';

/// Thrown when a staggered dial is cancelled before any candidate connects.
final class StaggeredDialCancelled implements Exception {
  const StaggeredDialCancelled();
}

/// Result of a staggered dial: the winning [endpoint] and live [connection],
/// plus [remaining] candidates that were not ruled out by a connect error so
/// callers can fall back if authentication rejects the winner for an identity
/// mismatch.
final class StaggeredDialWin<T> {
  const StaggeredDialWin({
    required this.endpoint,
    required this.connection,
    required this.remaining,
  });

  final PeerEndpoint endpoint;
  final T connection;
  final List<PeerEndpoint> remaining;
}

/// Dials [endpoints] with Happy Eyeballs-style staggering at the transport /
/// WebSocket-upgrade layer only.
///
/// The first candidate that completes [dial] wins; all other in-flight
/// candidates are closed via [close] as soon as they settle so they never
/// enter authentication or trigger disconnect cleanup.
Future<StaggeredDialWin<T>> dialStaggered<T>({
  required List<PeerEndpoint> endpoints,
  required Future<T> Function(PeerEndpoint endpoint) dial,
  required Future<void> Function(T connection) close,
  Duration stagger = const Duration(milliseconds: 250),
  int maxConcurrent = 4,
  bool Function()? isCancelled,
}) async {
  if (endpoints.isEmpty) {
    throw ArgumentError.value(endpoints, 'endpoints', 'must not be empty');
  }
  if (isCancelled?.call() == true) {
    throw const StaggeredDialCancelled();
  }
  if (endpoints.length == 1) {
    final target = endpoints.single;
    final connection = await dial(target);
    if (isCancelled?.call() == true) {
      unawaited(close(connection).catchError((Object _) {}));
      throw const StaggeredDialCancelled();
    }
    return StaggeredDialWin<T>(
      endpoint: target,
      connection: connection,
      remaining: const <PeerEndpoint>[],
    );
  }

  final limit = maxConcurrent < 1 ? 1 : maxConcurrent;
  final candidates = endpoints.length <= limit
      ? endpoints
      : endpoints.sublist(0, limit);
  final completer = Completer<StaggeredDialWin<T>>();
  final failedIndices = <int>{};
  final errors = <int, (Object, StackTrace)>{};
  Timer? nextTimer;
  var nextIndex = 0;
  var inFlight = 0;
  var settled = false;

  void finishError(Object error, StackTrace stackTrace) {
    if (settled) return;
    settled = true;
    nextTimer?.cancel();
    nextTimer = null;
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }

  void launchNext() {
    if (settled) return;
    if (isCancelled?.call() == true) {
      finishError(const StaggeredDialCancelled(), StackTrace.current);
      return;
    }
    if (nextIndex >= candidates.length || inFlight >= limit) {
      return;
    }
    final index = nextIndex++;
    final endpoint = candidates[index];
    inFlight += 1;

    if (nextIndex < candidates.length && inFlight < limit) {
      nextTimer?.cancel();
      nextTimer = Timer(stagger, launchNext);
    }

    unawaited(
      dial(endpoint).then(
        (connection) {
          inFlight -= 1;
          if (settled || isCancelled?.call() == true) {
            unawaited(close(connection).catchError((Object _) {}));
            if (!settled) {
              finishError(const StaggeredDialCancelled(), StackTrace.current);
            }
            return;
          }
          settled = true;
          nextTimer?.cancel();
          nextTimer = null;
          final remaining = <PeerEndpoint>[
            for (var i = 0; i < candidates.length; i += 1)
              if (i != index && !failedIndices.contains(i)) candidates[i],
          ];
          if (!completer.isCompleted) {
            completer.complete(
              StaggeredDialWin<T>(
                endpoint: endpoint,
                connection: connection,
                remaining: List<PeerEndpoint>.unmodifiable(remaining),
              ),
            );
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          inFlight -= 1;
          failedIndices.add(index);
          errors[index] = (error, stackTrace);
          if (settled) return;
          if (isCancelled?.call() == true) {
            finishError(const StaggeredDialCancelled(), StackTrace.current);
            return;
          }
          if (nextIndex < candidates.length) {
            // Fast failure: start the next candidate right away instead of
            // waiting out the remaining stagger delay.
            nextTimer?.cancel();
            nextTimer = null;
            launchNext();
            return;
          }
          if (inFlight == 0) {
            final primary = errors[0] ?? errors.values.first;
            finishError(primary.$1, primary.$2);
          }
        },
      ),
    );
  }

  launchNext();
  return completer.future;
}
