import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:whisper/helper/android_system_share.dart';

class AndroidSystemShareInbox extends ChangeNotifier {
  AndroidSystemShareInbox({
    AndroidSystemSharePlatform? platform,
    this.maxPendingEvents = androidSystemShareMaxPendingEvents,
    this.maxRecentEventIds = 64,
  }) : assert(maxPendingEvents > 0),
       assert(maxRecentEventIds >= maxPendingEvents),
       _platform = platform ?? MethodChannelAndroidSystemSharePlatform() {
    _platform.setShareIntentHandler(_handleShareIntentReceived);
  }

  static final AndroidSystemShareInbox shared = AndroidSystemShareInbox();

  final AndroidSystemSharePlatform _platform;
  final int maxPendingEvents;
  final int maxRecentEventIds;
  final LinkedHashMap<String, AndroidSystemShareEvent> _pendingEvents =
      LinkedHashMap<String, AndroidSystemShareEvent>();
  final LinkedHashSet<String> _recentEventIds = LinkedHashSet<String>();
  final ListQueue<AndroidSystemShareFailure> _failures =
      ListQueue<AndroidSystemShareFailure>();
  final LinkedHashSet<String> _recentFailureKeys = LinkedHashSet<String>();
  Future<void>? _refreshFuture;
  bool _refreshRequested = false;
  bool _isDisposed = false;

  List<AndroidSystemShareEvent> get pendingEvents =>
      List<AndroidSystemShareEvent>.unmodifiable(_pendingEvents.values);

  bool get hasPendingEvents => _pendingEvents.isNotEmpty;

  AndroidSystemShareEvent? event(String eventId) => _pendingEvents[eventId];

  AndroidSystemShareFailure? takeFailure() {
    return _failures.isEmpty ? null : _failures.removeFirst();
  }

  Future<void> initialize() => refresh();

  Future<void> refresh() {
    if (_isDisposed) {
      return Future<void>.value();
    }
    _refreshRequested = true;
    final activeRefresh = _refreshFuture;
    if (activeRefresh != null) {
      return activeRefresh;
    }
    final nextRefresh = _runRefresh();
    _refreshFuture = nextRefresh;
    return nextRefresh.whenComplete(() {
      _refreshFuture = null;
      if (_refreshRequested && !_isDisposed) {
        unawaited(refresh());
      }
    });
  }

  Future<void> _runRefresh() async {
    while (_refreshRequested && !_isDisposed) {
      _refreshRequested = false;
      final events = await _platform.consumePendingShares();
      if (_isDisposed) {
        return;
      }
      await _merge(events);
      final failures = await _platform.consumePendingShareFailures();
      if (_isDisposed) {
        return;
      }
      _recordFailures(failures);
    }
  }

  Future<void> _handleShareIntentReceived(AndroidSystemShareFailure? failure) {
    if (failure != null) {
      _recordFailures(<AndroidSystemShareFailure>[failure]);
    }
    return refresh();
  }

  Future<void> _merge(List<AndroidSystemShareEvent> events) async {
    var changed = false;
    for (final event in events) {
      if (_recentEventIds.contains(event.id)) {
        continue;
      }
      _recentEventIds.add(event.id);
      if (_pendingEvents.length >= maxPendingEvents) {
        await _platform.discardPendingShare(event.id);
        _recordFailures(<AndroidSystemShareFailure>[
          AndroidSystemShareFailure(
            reason: AndroidSystemShareFailureReason.queueFull,
            receivedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ]);
        continue;
      }
      _pendingEvents[event.id] = event;
      changed = true;
      while (_recentEventIds.length > maxRecentEventIds) {
        _recentEventIds.remove(_recentEventIds.first);
      }
    }
    if (changed) {
      notifyListeners();
    }
  }

  void _recordFailures(Iterable<AndroidSystemShareFailure> failures) {
    var changed = false;
    for (final failure in failures) {
      final key = '${failure.reason.index}:${failure.receivedAt}';
      if (!_recentFailureKeys.add(key)) {
        continue;
      }
      _failures.addLast(failure);
      while (_failures.length > maxRecentEventIds) {
        _failures.removeFirst();
      }
      while (_recentFailureKeys.length > maxRecentEventIds) {
        _recentFailureKeys.remove(_recentFailureKeys.first);
      }
      changed = true;
    }
    if (changed) {
      notifyListeners();
    }
  }

  AndroidSystemShareEvent? take(String eventId) {
    final event = _pendingEvents.remove(eventId);
    if (event != null) {
      unawaited(_platform.discardPendingShare(eventId));
      notifyListeners();
    }
    return event;
  }

  List<AndroidSystemShareEvent> takeAll() {
    if (_pendingEvents.isEmpty) {
      return const <AndroidSystemShareEvent>[];
    }
    final events = List<AndroidSystemShareEvent>.unmodifiable(
      _pendingEvents.values,
    );
    _pendingEvents.clear();
    for (final event in events) {
      unawaited(_platform.discardPendingShare(event.id));
    }
    notifyListeners();
    return events;
  }

  void clear() {
    if (_pendingEvents.isEmpty) {
      return;
    }
    final eventIds = _pendingEvents.keys.toList(growable: false);
    _pendingEvents.clear();
    for (final eventId in eventIds) {
      unawaited(_platform.discardPendingShare(eventId));
    }
    notifyListeners();
  }

  Future<void> persistProgress({
    required String eventId,
    required String peerId,
    required String publicKeyHash,
    required bool textSent,
    required bool waitingForConnection,
    required Iterable<String> sentItemUris,
  }) async {
    final event = _pendingEvents[eventId];
    if (event == null) {
      return;
    }
    final sentUris = sentItemUris.toSet();
    await _platform.updatePendingShareProgress(
      eventId: eventId,
      peerId: peerId,
      publicKeyHash: publicKeyHash,
      textSent: textSent,
      waitingForConnection: waitingForConnection,
      sentItemUris: sentUris,
    );
    if (_pendingEvents[eventId] != event) {
      return;
    }
    _pendingEvents[eventId] = event.copyWithProgress(
      targetPeerId: peerId,
      targetPublicKeyHash: publicKeyHash,
      textSent: textSent,
      waitingForConnection: waitingForConnection,
      sentItemUris: sentUris,
    );
    notifyListeners();
  }

  Future<AndroidSystemShareEvent?> complete(String eventId) async {
    final event = _pendingEvents[eventId];
    if (event == null) {
      return null;
    }
    await _platform.completePendingShare(eventId);
    if (_pendingEvents[eventId] == event) {
      _pendingEvents.remove(eventId);
      notifyListeners();
    }
    return event;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _platform.setShareIntentHandler(null);
    _pendingEvents.clear();
    _failures.clear();
    _recentFailureKeys.clear();
    super.dispose();
  }
}
