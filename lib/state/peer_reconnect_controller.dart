import 'dart:async';
import 'dart:math';

import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/peer_endpoint.dart';

enum ReconnectEligibilityResult {
  eligible,
  autoConnectDisabled,
  identityUnpinned,
  trustRevoked,
}

enum ReconnectSuppressionReason {
  manualDisconnect,
  trustRevoked,
  autoConnectDisabled,
  identityUnpinned,
  eligibilityCheckFailed,
  managerClosed,
}

final class ReconnectTarget {
  factory ReconnectTarget({
    required String peerId,
    required String host,
    required int port,
  }) {
    if (peerId.isEmpty) {
      throw ArgumentError.value(peerId, 'peerId', 'must not be empty');
    }
    return ReconnectTarget._(
      peerId: peerId,
      endpoint: PeerEndpoint(host: host, port: port),
    );
  }

  factory ReconnectTarget.endpoint({
    required String peerId,
    required PeerEndpoint endpoint,
  }) {
    if (peerId.isEmpty) {
      throw ArgumentError.value(peerId, 'peerId', 'must not be empty');
    }
    return ReconnectTarget._(peerId: peerId, endpoint: endpoint);
  }

  const ReconnectTarget._({required this.peerId, required this.endpoint});

  final String peerId;
  final PeerEndpoint endpoint;

  String get host => endpoint.host;
  int get port => endpoint.port;

  @override
  bool operator ==(Object other) =>
      other is ReconnectTarget &&
      other.peerId == peerId &&
      other.endpoint == endpoint;

  @override
  int get hashCode => Object.hash(peerId, endpoint);
}

/// Cancellation guard for one dial generation.
///
/// Dialers should race I/O against [whenCancelled] and check [isCurrent]
/// immediately before authenticating or registering a connection.
final class ReconnectAttemptContext {
  ReconnectAttemptContext._({
    required this.target,
    required this.generation,
  });

  final ReconnectTarget target;
  final int generation;
  final Completer<void> _cancelled = Completer<void>();
  bool _active = true;
  bool _wasCancelled = false;
  ConnectionAttemptReason _resultReason = ConnectionAttemptReason.none;

  bool get isCurrent => _active && !_wasCancelled;
  bool get isCancelled => _wasCancelled;
  Future<void> get whenCancelled => _cancelled.future;
  ConnectionAttemptReason get resultReason => _resultReason;

  /// 拨号方回报底层结果原因,让控制器区分可短延迟重试的去重拒绝
  /// (duplicateRequest,同 peer 旧尝试仍在异步清理)与真正的终态拒绝。
  void reportResultReason(ConnectionAttemptReason reason) {
    _resultReason = reason;
  }

  void _cancel() {
    if (!_active) {
      return;
    }
    _active = false;
    _wasCancelled = true;
    _cancelled.complete();
  }

  void _complete() {
    _active = false;
  }
}

typedef ReconnectClock = DateTime Function();
typedef ReconnectTimerFactory = Timer Function(
  Duration delay,
  void Function() callback,
);
typedef ReconnectRandomDouble = double Function();
typedef ReconnectEligibility = FutureOr<ReconnectEligibilityResult> Function(
  ReconnectTarget target,
);
typedef ReconnectAttempt = FutureOr<ConnectionAttemptStatus> Function(
  ReconnectAttemptContext attempt,
);

/// A reconnect state machine owned by exactly one peer.
final class PeerReconnectController {
  /// 认证成功的连接必须存活满该时长,断开时才复位重连退避;
  /// 更短命的连接视为连续失败继续升档,避免「断联-秒级重连-再断」死循环。
  static const Duration stableConnectionThreshold = Duration(seconds: 30);

  PeerReconnectController({
    required ReconnectAttempt attempt,
    required ReconnectEligibility eligibility,
    ReconnectClock? clock,
    ReconnectTimerFactory? timerFactory,
    ReconnectRandomDouble? randomDouble,
  })  : _attempt = attempt,
        _eligibility = eligibility,
        _clock = clock ?? DateTime.now,
        _timerFactory = timerFactory ?? _createTimer,
        _randomDouble = randomDouble ?? Random().nextDouble;

  final ReconnectAttempt _attempt;
  final ReconnectEligibility _eligibility;
  final ReconnectClock _clock;
  final ReconnectTimerFactory _timerFactory;
  final ReconnectRandomDouble _randomDouble;

  ReconnectTarget? _target;
  Timer? _timer;
  DateTime? _nextAttemptAt;
  DateTime? _authenticatedAt;
  int _attemptCount = 0;
  int _generation = 0;
  final Set<ReconnectAttemptContext> _activeAttempts =
      <ReconnectAttemptContext>{};
  final Set<ReconnectSuppressionReason> _suppressionReasons =
      <ReconnectSuppressionReason>{};
  bool _closed = false;

  ReconnectTarget? get target => _target;
  int get attemptCount => _attemptCount;
  int get generation => _generation;
  bool get hasPendingAttempt => _timer != null;
  bool get isAttemptInFlight => _activeAttempts.isNotEmpty;
  bool get isSuppressed => _suppressionReasons.isNotEmpty;
  bool get isClosed => _closed;
  DateTime? get nextAttemptAt => _nextAttemptAt;
  Set<ReconnectSuppressionReason> get suppressionReasons =>
      Set<ReconnectSuppressionReason>.unmodifiable(_suppressionReasons);

  void scheduleReconnect(ReconnectTarget target) {
    if (_target == target && (_timer != null || _activeAttempts.isNotEmpty)) {
      return;
    }
    _setTarget(target);
    if (_closed || isSuppressed) {
      return;
    }
    if (_authenticatedAt != null) {
      // 会话仍存活(自动连接重开、信任恢复等场景会走到这里):
      // 不得把活会话结算成短命失败,也不排冗余拨号;
      // 断开时由 sessionClosed 统一结算稳定性。
      return;
    }
    _replaceScheduledAttempt(_retryDelay());
  }

  /// 会话生命周期终点:不论断因,在断开通知处结算稳定性复位。
  /// 存活满 [stableConnectionThreshold] 复位退避,短命会话按连续失败升档。
  void sessionClosed() {
    if (_closed) {
      return;
    }
    _settleAuthenticatedSession();
  }

  /// 结算上一段 authenticated 会话:存活满
  /// [stableConnectionThreshold] 才复位退避,短命连接视为一次连续失败。
  void _settleAuthenticatedSession() {
    final authenticatedAt = _authenticatedAt;
    if (authenticatedAt == null) {
      return;
    }
    _authenticatedAt = null;
    final lifetime = _clock().difference(authenticatedAt);
    if (lifetime >= stableConnectionThreshold) {
      _attemptCount = 0;
    } else {
      _attemptCount += 1;
    }
  }

  void updateTarget(ReconnectTarget target, {bool accelerate = true}) {
    if (_target == target) {
      return;
    }
    _setTarget(target);
    final hadTimer = _timer != null;
    final hadAttempt = _activeAttempts.isNotEmpty;
    if ((!hadTimer && !hadAttempt) || _closed || isSuppressed) {
      return;
    }

    final replacementDelay = accelerate ? Duration.zero : _remainingDelay();
    _invalidate();
    _armTimer(replacementDelay);
  }

  void authenticated() {
    if (_closed) {
      return;
    }
    // 不立即清零 _attemptCount:每轮重连握手都会成功,若在此复位,
    // 断联-重连循环的退避将永远停留在 ~1s。记录时刻,断开时按
    // 存活时长在 _settleAuthenticatedSession 里结算。
    _authenticatedAt = _clock();
    _invalidate();
  }

  void manualDisconnect() =>
      _suppressReconnects(ReconnectSuppressionReason.manualDisconnect);

  void trustRevoked() =>
      _suppressReconnects(ReconnectSuppressionReason.trustRevoked);

  void trustRestored() =>
      _restoreEligibility(ReconnectSuppressionReason.trustRevoked);

  void autoConnectDisabled() =>
      _suppressReconnects(ReconnectSuppressionReason.autoConnectDisabled);

  void autoConnectEnabled() =>
      _restoreEligibility(ReconnectSuppressionReason.autoConnectDisabled);

  void identityUnpinned() =>
      _suppressReconnects(ReconnectSuppressionReason.identityUnpinned);

  void identityPinned() =>
      _restoreEligibility(ReconnectSuppressionReason.identityUnpinned);

  void eligibilityRestored() =>
      _restoreEligibility(ReconnectSuppressionReason.eligibilityCheckFailed);

  void unsuppressForManualConnect(ReconnectTarget target) {
    if (_closed) {
      return;
    }
    _setTarget(target);
    _invalidate();
    _suppressionReasons.remove(
      ReconnectSuppressionReason.manualDisconnect,
    );
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _suppressionReasons
      ..clear()
      ..add(ReconnectSuppressionReason.managerClosed);
    _invalidate();
  }

  void _setTarget(ReconnectTarget target) {
    final current = _target;
    if (current != null && current.peerId != target.peerId) {
      throw ArgumentError.value(
        target.peerId,
        'target.peerId',
        'must match the controller peer',
      );
    }
    _target = target;
  }

  Duration _remainingDelay() {
    final deadline = _nextAttemptAt;
    if (deadline == null) {
      return _retryDelay();
    }
    final remaining = deadline.difference(_clock());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void _replaceScheduledAttempt(Duration delay) {
    _invalidate();
    _armTimer(delay);
  }

  void _armTimer(Duration delay) {
    if (_closed || isSuppressed) {
      return;
    }
    final target = _target;
    if (target == null) {
      return;
    }
    final scheduledGeneration = _generation;
    _nextAttemptAt = _clock().add(delay);
    _timer = _timerFactory(delay, () {
      if (!_isCurrent(scheduledGeneration)) {
        return;
      }
      _timer = null;
      _nextAttemptAt = null;
      unawaited(_runAttempt(scheduledGeneration, target));
    });
  }

  Future<void> _runAttempt(
    int attemptGeneration,
    ReconnectTarget scheduledTarget,
  ) async {
    if (!_isCurrent(attemptGeneration)) {
      return;
    }
    final attemptContext = ReconnectAttemptContext._(
      target: scheduledTarget,
      generation: attemptGeneration,
    );
    _activeAttempts.add(attemptContext);

    ReconnectEligibilityResult eligibility;
    try {
      eligibility = await _eligibility(scheduledTarget);
    } catch (_) {
      if (!_isCurrent(attemptGeneration)) {
        _retireAttempt(attemptContext);
        return;
      }
      _retireAttempt(attemptContext);
      _suppressReconnects(
        ReconnectSuppressionReason.eligibilityCheckFailed,
      );
      return;
    }
    if (!_isCurrent(attemptGeneration)) {
      _retireAttempt(attemptContext);
      return;
    }
    if (eligibility != ReconnectEligibilityResult.eligible) {
      _retireAttempt(attemptContext);
      _suppressReconnects(_suppressionFor(eligibility));
      return;
    }

    ConnectionAttemptStatus result;
    try {
      result = await _attempt(attemptContext);
    } catch (_) {
      if (!_isCurrent(attemptGeneration)) {
        _retireAttempt(attemptContext);
        return;
      }
      _retireAttempt(attemptContext);
      _invalidate();
      return;
    }
    if (!_isCurrent(attemptGeneration)) {
      _retireAttempt(attemptContext);
      return;
    }

    _retireAttempt(attemptContext);
    switch (result) {
      case ConnectionAttemptStatus.authenticated:
        authenticated();
        break;
      case ConnectionAttemptStatus.networkFailure:
        _attemptCount += 1;
        scheduleReconnect(scheduledTarget);
        break;
      case ConnectionAttemptStatus.rejected:
        if (attemptContext.resultReason ==
            ConnectionAttemptReason.duplicateRequest) {
          // 去重拒绝说明同 peer 仍有在途/清理中的尝试,不是终态:
          // 按当前退避重排(计数不升档),避免自动重连从此休眠。
          scheduleReconnect(scheduledTarget);
          break;
        }
        _invalidate();
        break;
      case ConnectionAttemptStatus.cancelled:
        _invalidate();
        break;
    }
  }

  void _retireAttempt(ReconnectAttemptContext attempt) {
    _activeAttempts.remove(attempt);
    attempt._complete();
  }

  ReconnectSuppressionReason _suppressionFor(
    ReconnectEligibilityResult eligibility,
  ) {
    return switch (eligibility) {
      ReconnectEligibilityResult.autoConnectDisabled =>
        ReconnectSuppressionReason.autoConnectDisabled,
      ReconnectEligibilityResult.identityUnpinned =>
        ReconnectSuppressionReason.identityUnpinned,
      ReconnectEligibilityResult.trustRevoked =>
        ReconnectSuppressionReason.trustRevoked,
      ReconnectEligibilityResult.eligible => throw StateError(
          'eligible reconnect cannot produce a suppression reason',
        ),
    };
  }

  void _suppressReconnects(ReconnectSuppressionReason reason) {
    if (_closed) {
      return;
    }
    _suppressionReasons.add(reason);
    _invalidate();
  }

  void _restoreEligibility(ReconnectSuppressionReason reason) {
    if (_closed || !_suppressionReasons.contains(reason)) {
      return;
    }
    _invalidate();
    _suppressionReasons.remove(reason);
  }

  void _invalidate() {
    _generation += 1;
    _timer?.cancel();
    _timer = null;
    _nextAttemptAt = null;
    for (final attempt in _activeAttempts) {
      attempt._cancel();
    }
    _activeAttempts.clear();
  }

  bool _isCurrent(int expectedGeneration) =>
      expectedGeneration == _generation && !_closed && !isSuppressed;

  Duration _retryDelay() => _delayForAttempt(_attemptCount, _randomDouble());

  static Duration _delayForAttempt(int attempt, double randomDouble) {
    const seconds = <int>[1, 2, 4, 8, 16, 30, 60];
    final base = seconds[min(attempt, seconds.length - 1)];
    final multiplier = 0.8 + 0.4 * randomDouble;
    return Duration(
      microseconds:
          (Duration.microsecondsPerSecond * base * multiplier).round(),
    );
  }

  static Timer _createTimer(Duration delay, void Function() callback) =>
      Timer(delay, callback);
}
