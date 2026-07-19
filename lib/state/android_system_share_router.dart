import 'dart:async';

import 'package:whisper/helper/android_system_share.dart';
import 'package:whisper/state/android_system_share_inbox.dart';

typedef AndroidSystemShareConnectionCheck = bool Function(String peerId);
typedef AndroidSystemShareTrustedIdentityResolver =
    String? Function(String peerId);
typedef AndroidSystemShareTextSender =
    Future<bool> Function(String peerId, AndroidSystemShareEvent event);
typedef AndroidSystemShareItemSender =
    Future<bool> Function(
      String peerId,
      AndroidSystemShareEvent event,
      AndroidSystemShareItem item,
    );

enum AndroidSystemShareRouteOutcome {
  completed,
  waitingForConnection,
  failed,
  missingEvent,
  targetConflict,
  targetIdentityInvalid,
}

class AndroidSystemShareRouteResult {
  const AndroidSystemShareRouteResult({
    required this.eventId,
    required this.peerId,
    required this.outcome,
  });

  final String eventId;
  final String peerId;
  final AndroidSystemShareRouteOutcome outcome;
}

class AndroidSystemShareRouter {
  AndroidSystemShareRouter({
    required AndroidSystemShareInbox inbox,
    required AndroidSystemShareConnectionCheck isConnected,
    required AndroidSystemShareTrustedIdentityResolver trustedIdentityHashFor,
    required AndroidSystemShareTextSender sendText,
    required AndroidSystemShareItemSender sendItem,
  }) : _inbox = inbox,
       _isConnected = isConnected,
       _trustedIdentityHashFor = trustedIdentityHashFor,
       _sendText = sendText,
       _sendItem = sendItem;

  final AndroidSystemShareInbox _inbox;
  final AndroidSystemShareConnectionCheck _isConnected;
  final AndroidSystemShareTrustedIdentityResolver _trustedIdentityHashFor;
  final AndroidSystemShareTextSender _sendText;
  final AndroidSystemShareItemSender _sendItem;
  final Map<String, _AndroidSystemShareProgress> _routes =
      <String, _AndroidSystemShareProgress>{};
  final Map<String, Future<AndroidSystemShareRouteResult>> _activeAttempts =
      <String, Future<AndroidSystemShareRouteResult>>{};

  String? targetPeerIdFor(String eventId) {
    final progress = _progressFor(eventId);
    return progress != null && _hasValidTargetBinding(progress)
        ? progress.peerId
        : null;
  }

  Future<AndroidSystemShareRouteResult> sendTo(String eventId, String peerId) {
    final normalizedPeerId = peerId.trim();
    final existingProgress = _progressFor(eventId);
    final trustedIdentityHash = _currentTrustedIdentityHash(normalizedPeerId);
    final activeAttempt = _activeAttempts[eventId];
    if (activeAttempt != null) {
      if (existingProgress?.peerId == normalizedPeerId) {
        return activeAttempt;
      }
      return Future<AndroidSystemShareRouteResult>.value(
        AndroidSystemShareRouteResult(
          eventId: eventId,
          peerId: existingProgress?.peerId ?? normalizedPeerId,
          outcome: AndroidSystemShareRouteOutcome.targetConflict,
        ),
      );
    }
    if (_inbox.event(eventId) == null || normalizedPeerId.isEmpty) {
      _routes.remove(eventId);
      return Future<AndroidSystemShareRouteResult>.value(
        AndroidSystemShareRouteResult(
          eventId: eventId,
          peerId: normalizedPeerId,
          outcome: AndroidSystemShareRouteOutcome.missingEvent,
        ),
      );
    }
    if (trustedIdentityHash == null) {
      if (existingProgress != null) {
        return _invalidateTargetBinding(eventId, existingProgress);
      }
      return Future<AndroidSystemShareRouteResult>.value(
        AndroidSystemShareRouteResult(
          eventId: eventId,
          peerId: normalizedPeerId,
          outcome: AndroidSystemShareRouteOutcome.targetIdentityInvalid,
        ),
      );
    }

    final progress =
        existingProgress ??
        _AndroidSystemShareProgress(
          peerId: normalizedPeerId,
          publicKeyHash: trustedIdentityHash,
        );
    if (existingProgress != null && !_hasValidTargetBinding(progress)) {
      return _rebindAndStart(
        eventId,
        progress,
        peerId: normalizedPeerId,
        publicKeyHash: trustedIdentityHash,
      );
    }
    if (progress.peerId != normalizedPeerId) {
      if (progress.hasSentContent) {
        return Future<AndroidSystemShareRouteResult>.value(
          AndroidSystemShareRouteResult(
            eventId: eventId,
            peerId: progress.peerId,
            outcome: AndroidSystemShareRouteOutcome.targetConflict,
          ),
        );
      }
      progress.peerId = normalizedPeerId;
      progress.publicKeyHash = trustedIdentityHash;
    }
    _routes[eventId] = progress;
    return _startAttempt(eventId, progress);
  }

  Future<AndroidSystemShareRouteResult> retry(String eventId) {
    final progress = _progressFor(eventId);
    if (progress == null) {
      return Future<AndroidSystemShareRouteResult>.value(
        AndroidSystemShareRouteResult(
          eventId: eventId,
          peerId: '',
          outcome: AndroidSystemShareRouteOutcome.missingEvent,
        ),
      );
    }
    final activeAttempt = _activeAttempts[eventId];
    return activeAttempt ?? _startAttempt(eventId, progress);
  }

  Future<List<AndroidSystemShareRouteResult>> retryConnected() async {
    final results = <AndroidSystemShareRouteResult>[];
    for (final event in _inbox.pendingEvents) {
      _progressFor(event.id);
    }
    for (final eventId in List<String>.of(_routes.keys)) {
      final progress = _routes[eventId];
      if (progress == null) {
        continue;
      }
      if (_inbox.event(eventId) == null) {
        _routes.remove(eventId);
        continue;
      }
      if (!_hasValidTargetBinding(progress)) {
        results.add(await retry(eventId));
        continue;
      }
      if ((!progress.waitingForConnection && !progress.restored) ||
          !_isConnected(progress.peerId)) {
        continue;
      }
      progress.restored = false;
      results.add(await retry(eventId));
    }
    return List<AndroidSystemShareRouteResult>.unmodifiable(results);
  }

  Future<AndroidSystemShareRouteResult> _startAttempt(
    String eventId,
    _AndroidSystemShareProgress progress,
  ) {
    final attempt = _attempt(eventId, progress);
    return _trackAttempt(eventId, attempt);
  }

  Future<AndroidSystemShareRouteResult> _trackAttempt(
    String eventId,
    Future<AndroidSystemShareRouteResult> attempt,
  ) {
    _activeAttempts[eventId] = attempt;
    return attempt.whenComplete(() {
      if (identical(_activeAttempts[eventId], attempt)) {
        _activeAttempts.remove(eventId);
      }
    });
  }

  Future<AndroidSystemShareRouteResult> _attempt(
    String eventId,
    _AndroidSystemShareProgress progress,
  ) async {
    final event = _inbox.event(eventId);
    if (event == null) {
      _routes.remove(eventId);
      return _result(
        eventId,
        progress.peerId,
        AndroidSystemShareRouteOutcome.missingEvent,
      );
    }
    if (!_hasValidTargetBinding(progress)) {
      return _invalidateTargetBinding(eventId, progress);
    }
    if (!_isConnected(progress.peerId)) {
      progress.waitingForConnection = true;
      if (!await _persistProgress(eventId, progress)) {
        return _result(
          eventId,
          progress.peerId,
          AndroidSystemShareRouteOutcome.failed,
        );
      }
      return _result(
        eventId,
        progress.peerId,
        AndroidSystemShareRouteOutcome.waitingForConnection,
      );
    }
    progress.waitingForConnection = false;
    progress.restored = false;
    if (!await _persistProgress(eventId, progress)) {
      return _result(
        eventId,
        progress.peerId,
        AndroidSystemShareRouteOutcome.failed,
      );
    }

    try {
      if (event.text.isNotEmpty && !progress.textSent) {
        if (!_hasValidTargetBinding(progress)) {
          return _invalidateTargetBinding(eventId, progress);
        }
        if (!await _sendText(progress.peerId, event)) {
          if (!_isConnected(progress.peerId)) {
            progress.waitingForConnection = true;
            await _persistProgress(eventId, progress);
            return _result(
              eventId,
              progress.peerId,
              AndroidSystemShareRouteOutcome.waitingForConnection,
            );
          }
          return _result(
            eventId,
            progress.peerId,
            AndroidSystemShareRouteOutcome.failed,
          );
        }
        if (!_hasValidTargetBinding(progress)) {
          return _invalidateTargetBinding(eventId, progress);
        }
        progress.textSent = true;
        if (!await _persistProgress(eventId, progress)) {
          return _result(
            eventId,
            progress.peerId,
            AndroidSystemShareRouteOutcome.failed,
          );
        }
      }
      for (final item in event.items) {
        if (progress.sentItemUris.contains(item.uri)) {
          continue;
        }
        if (!_hasValidTargetBinding(progress)) {
          return _invalidateTargetBinding(eventId, progress);
        }
        if (!_isConnected(progress.peerId)) {
          progress.waitingForConnection = true;
          await _persistProgress(eventId, progress);
          return _result(
            eventId,
            progress.peerId,
            AndroidSystemShareRouteOutcome.waitingForConnection,
          );
        }
        if (!await _sendItem(progress.peerId, event, item)) {
          if (!_isConnected(progress.peerId)) {
            progress.waitingForConnection = true;
            await _persistProgress(eventId, progress);
            return _result(
              eventId,
              progress.peerId,
              AndroidSystemShareRouteOutcome.waitingForConnection,
            );
          }
          return _result(
            eventId,
            progress.peerId,
            AndroidSystemShareRouteOutcome.failed,
          );
        }
        if (!_hasValidTargetBinding(progress)) {
          return _invalidateTargetBinding(eventId, progress);
        }
        progress.sentItemUris.add(item.uri);
        if (!await _persistProgress(eventId, progress)) {
          return _result(
            eventId,
            progress.peerId,
            AndroidSystemShareRouteOutcome.failed,
          );
        }
      }
    } catch (_) {
      if (!_hasValidTargetBinding(progress)) {
        return _invalidateTargetBinding(eventId, progress);
      }
      if (!_isConnected(progress.peerId)) {
        progress.waitingForConnection = true;
        await _persistProgress(eventId, progress);
        return _result(
          eventId,
          progress.peerId,
          AndroidSystemShareRouteOutcome.waitingForConnection,
        );
      }
      await _persistProgress(eventId, progress);
      return _result(
        eventId,
        progress.peerId,
        AndroidSystemShareRouteOutcome.failed,
      );
    }

    if (!_hasValidTargetBinding(progress)) {
      return _invalidateTargetBinding(eventId, progress);
    }

    try {
      await _inbox.complete(eventId);
    } catch (_) {
      return _result(
        eventId,
        progress.peerId,
        AndroidSystemShareRouteOutcome.failed,
      );
    }
    _routes.remove(eventId);
    return _result(
      eventId,
      progress.peerId,
      AndroidSystemShareRouteOutcome.completed,
    );
  }

  AndroidSystemShareRouteResult _result(
    String eventId,
    String peerId,
    AndroidSystemShareRouteOutcome outcome,
  ) {
    return AndroidSystemShareRouteResult(
      eventId: eventId,
      peerId: peerId,
      outcome: outcome,
    );
  }

  _AndroidSystemShareProgress? _progressFor(String eventId) {
    final existing = _routes[eventId];
    if (existing != null) {
      return existing;
    }
    final event = _inbox.event(eventId);
    if (event == null || event.targetPeerId.isEmpty) {
      return null;
    }
    final restored =
        _AndroidSystemShareProgress(
            peerId: event.targetPeerId,
            publicKeyHash: event.targetPublicKeyHash,
          )
          ..textSent = event.textSent
          ..waitingForConnection = event.waitingForConnection
          ..sentItemUris.addAll(event.sentItemUris)
          ..restored = true;
    _routes[eventId] = restored;
    return restored;
  }

  String? _currentTrustedIdentityHash(String peerId) {
    if (peerId.isEmpty) {
      return null;
    }
    final value = _trustedIdentityHashFor(peerId)?.trim() ?? '';
    if (value.length != 43 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      return null;
    }
    return value;
  }

  bool _hasValidTargetBinding(_AndroidSystemShareProgress progress) {
    return progress.peerId.isNotEmpty &&
        progress.publicKeyHash.isNotEmpty &&
        _currentTrustedIdentityHash(progress.peerId) == progress.publicKeyHash;
  }

  Future<AndroidSystemShareRouteResult> _rebindAndStart(
    String eventId,
    _AndroidSystemShareProgress progress, {
    required String peerId,
    required String publicKeyHash,
  }) {
    final attempt = () async {
      progress
        ..peerId = peerId
        ..publicKeyHash = publicKeyHash
        ..textSent = false
        ..waitingForConnection = false
        ..restored = false
        ..sentItemUris.clear();
      _routes[eventId] = progress;
      if (!await _persistProgress(eventId, progress)) {
        return _result(eventId, peerId, AndroidSystemShareRouteOutcome.failed);
      }
      return _attempt(eventId, progress);
    }();
    return _trackAttempt(eventId, attempt);
  }

  Future<AndroidSystemShareRouteResult> _invalidateTargetBinding(
    String eventId,
    _AndroidSystemShareProgress progress,
  ) async {
    final previousPeerId = progress.peerId;
    _routes.remove(eventId);
    progress
      ..peerId = ''
      ..publicKeyHash = ''
      ..textSent = false
      ..waitingForConnection = false
      ..restored = false
      ..sentItemUris.clear();
    await _persistProgress(eventId, progress);
    return _result(
      eventId,
      previousPeerId,
      AndroidSystemShareRouteOutcome.targetIdentityInvalid,
    );
  }

  Future<bool> _persistProgress(
    String eventId,
    _AndroidSystemShareProgress progress,
  ) async {
    try {
      await _inbox.persistProgress(
        eventId: eventId,
        peerId: progress.peerId,
        publicKeyHash: progress.publicKeyHash,
        textSent: progress.textSent,
        waitingForConnection: progress.waitingForConnection,
        sentItemUris: progress.sentItemUris,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

class _AndroidSystemShareProgress {
  _AndroidSystemShareProgress({
    required this.peerId,
    required this.publicKeyHash,
  });

  String peerId;
  String publicKeyHash;
  bool textSent = false;
  bool waitingForConnection = false;
  bool restored = false;
  final Set<String> sentItemUris = <String>{};

  bool get hasSentContent => textSent || sentItemUris.isNotEmpty;
}
