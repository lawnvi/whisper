import 'dart:async';

/// Which of a group's sinks the source plays to again by itself.
///
/// The source alone decides. A sink the connection lost (the peer went, the
/// media channel failed, an offer went unanswered) gets the sound offered
/// again: at once when its peer connects again, otherwise after a short
/// wait, a few times. A sink that paused, or was taken out, is left alone
/// until it asks to join again. Before this, each sink tried to rejoin on its
/// own with five flags of state, and a source that had not yet noticed the
/// old connection was gone dropped the request: the speaker stayed silent
/// for good.
final class AudioGroupRecovery {
  AudioGroupRecovery({
    this.waits = const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 8),
    ],
  });

  /// One wait per attempt; when they are used up the sink waits for its peer
  /// to connect again (or for its user).
  final List<Duration> waits;

  final Map<String, int> _attempts = <String, int>{};
  final Map<String, Timer> _timers = <String, Timer>{};

  /// Whether [sinkPeerId] was lost and is to be offered the sound again.
  bool wants(String sinkPeerId) => _attempts.containsKey(sinkPeerId);

  /// The connection to [sinkPeerId] went: offer again when it can be.
  void lost(String sinkPeerId) {
    _attempts.putIfAbsent(sinkPeerId, () => 0);
  }

  /// Offers [reoffer] after the next wait. False when no attempts are left;
  /// [wants] stays true, so a reconnect still brings the sink back.
  bool schedule(String sinkPeerId, void Function() reoffer) {
    final attempt = _attempts[sinkPeerId];
    if (attempt == null || attempt >= waits.length) return false;
    _timers.remove(sinkPeerId)?.cancel();
    _timers[sinkPeerId] = Timer(waits[attempt], () {
      _timers.remove(sinkPeerId);
      if (!wants(sinkPeerId)) return;
      _attempts[sinkPeerId] = attempt + 1;
      reoffer();
    });
    return true;
  }

  /// The peer of [sinkPeerId] connected again: offer now, and give it its
  /// attempts back.
  bool takeReconnect(String sinkPeerId) {
    if (!wants(sinkPeerId)) return false;
    _timers.remove(sinkPeerId)?.cancel();
    _attempts[sinkPeerId] = 0;
    return true;
  }

  /// [sinkPeerId] plays, paused, or was taken out: nothing to do for it.
  void settle(String sinkPeerId) {
    _attempts.remove(sinkPeerId);
    _timers.remove(sinkPeerId)?.cancel();
  }

  void clear() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _attempts.clear();
  }
}
