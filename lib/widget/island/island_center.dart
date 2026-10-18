import 'dart:async';

import 'package:flutter/foundation.dart';

import 'island_activity.dart';

/// Where the island is: gone, the small island, or the open card.
enum IslandStage { hidden, compact, expanded }

enum IslandHaptic { selection, light, medium }

/// Every live activity of the app on one island (phones): file copies,
/// transfers, the speaker, this phone being streamed, windows sent here.
///
/// The center decides what shows and when; the host only draws it and
/// springs between [stage]s:
/// - a new activity arrives as the small island and opens for a moment
///   ([IslandArrival.open]), or just sits there ([IslandArrival.quiet]);
/// - trouble (connection gone, a failure) opens it for a while;
/// - done shows a tick for a moment, then it goes; stopped goes sooner;
///   failed stays until put away;
/// - the most important activity is on the small island, the next in a
///   circle beside it; the card lists all of them;
/// - swiped away, what is under way waits out of sight until something
///   about it changes; a window sent here is dismissed.
/// In the background nothing shows (the system notifications take over);
/// what should have opened the card opens it when the app comes back.
class IslandCenter extends ChangeNotifier implements IslandControls {
  IslandCenter({
    Iterable<IslandSource> sources = const [],
    this.clock = const IslandClock(),
  }) {
    for (final source in sources) {
      addSource(source);
    }
  }

  static final IslandCenter shared = IslandCenter();

  final IslandClock clock;

  /// Taps under the finger; the host plays them.
  void Function(IslandHaptic haptic)? haptics;

  /// The small island first, then it opens: reads as "something came".
  static const arrivalDelay = Duration(milliseconds: 140);
  static const arrivalOpen = Duration(milliseconds: 3800);
  static const troubleOpen = Duration(seconds: 6);
  static const tapOpen = Duration(seconds: 8);
  static const doneLingers = Duration(milliseconds: 2600);
  static const endedLingers = Duration(milliseconds: 1600);

  /// What was due while the finger was on the island happens this long
  /// after it lets go.
  static const afterRelease = Duration(milliseconds: 1600);

  final _sources = <IslandSource>[];
  final _spotlights = <IslandSource, StreamSubscription<String>>{};
  final _tracks = <String, _Track>{};
  IslandSource? _adding;

  IslandStage _stage = IslandStage.hidden;
  bool _foreground = true;
  bool _immersive = false;
  int _hushes = 0;
  bool _held = false;
  bool _closeWhenReleased = false;
  String? _featured;
  Timer? _openTimer;
  Timer? _closeTimer;
  _Cue? _pending;
  List<_Track> _visible = const [];
  List<_Track> _listed = const [];
  bool _disposed = false;

  // ------------------------------------------------------------ reading

  IslandStage get stage => _foreground ? _stage : IslandStage.hidden;

  bool get foreground => _foreground;

  /// What the small island and its circle show, most important first.
  List<IslandActivity> get visible => [for (final t in _visible) t.activity];

  /// Everything the open card lists (also what was swiped out of sight).
  List<IslandActivity> get listed => [for (final t in _listed) t.activity];

  /// At the top of the open card (and on the small island).
  IslandActivity? get featured {
    final pinned = _featured;
    if (pinned != null) {
      for (final track in _listed) {
        if (track.activity.id == pinned) {
          return track.activity;
        }
      }
    }
    return _visible.isEmpty ? null : _visible.first.activity;
  }

  /// In the circle beside the small island.
  IslandActivity? get secondary {
    final shown = featured;
    for (final track in _visible) {
      if (track.activity.id != shown?.id) {
        return track.activity;
      }
    }
    return null;
  }

  /// The rest of the card, below [featured].
  List<IslandActivity> get others {
    final shown = featured;
    return [
      for (final track in _listed)
        if (track.activity.id != shown?.id) track.activity,
    ];
  }

  /// How much an activity matters right now: a window sent here, then
  /// trouble, the phone being streamed, copies and transfers, a tick that
  /// is about to go, the speaker, anything paused.
  static int rank(IslandActivity activity) {
    if (activity.kind == IslandKind.offer) {
      return 100;
    }
    return switch (activity.status) {
      IslandStatus.failed => 90,
      IslandStatus.waiting => 85,
      IslandStatus.done || IslandStatus.ended => 55,
      IslandStatus.paused => 20,
      IslandStatus.live => switch (activity.kind) {
        IslandKind.streamed => 70,
        IslandKind.copy || IslandKind.transfer => 60,
        IslandKind.audio => 50,
        IslandKind.offer => 100,
      },
    };
  }

  static bool _urgent(IslandActivity activity) =>
      activity.urgent ||
      activity.kind == IslandKind.offer ||
      activity.status.trouble;

  // ------------------------------------------------------------ sources

  void addSource(IslandSource source) {
    if (_sources.contains(source)) {
      return;
    }
    _sources.add(source);
    source.addListener(_sync);
    _spotlights[source] = source.spotlights.listen(_spotlight);
    // What is already going on comes in quietly: no card for it.
    _adding = source;
    _sync();
    _adding = null;
  }

  void removeSource(IslandSource source) {
    if (!_sources.remove(source)) {
      return;
    }
    source.removeListener(_sync);
    unawaited(_spotlights.remove(source)?.cancel());
    _sync();
  }

  void _sync() {
    if (_disposed) {
      return;
    }
    if (_syncing) {
      // A source answered a call of ours by changing: once more after.
      _again = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _again = false;
        _syncOnce();
      } while (_again);
    } finally {
      _syncing = false;
    }
    _refresh();
  }

  bool _syncing = false;
  bool _again = false;

  void _syncOnce() {
    final present = <String>{};
    for (final source in _sources) {
      for (final activity in source.activities) {
        if (!present.add(activity.id)) {
          continue;
        }
        final track = _tracks[activity.id];
        if (track == null) {
          final fresh = _Track(activity, source);
          _tracks[activity.id] = fresh;
          _added(fresh, initial: identical(source, _adding));
          continue;
        }
        final before = track.activity.status;
        track.activity = activity;
        if (before != activity.status) {
          _changed(track, before);
        }
      }
    }
    for (final id in _tracks.keys.toList()) {
      if (!present.contains(id)) {
        _tracks.remove(id)!.cancel();
        if (_featured == id) {
          _featured = null;
        }
      }
    }
  }

  void _added(_Track track, {required bool initial}) {
    final activity = track.activity;
    final failedNow = activity.status == IslandStatus.failed && !initial;
    if (activity.status.finished && !failedNow) {
      // Over before the island saw it: nothing to show.
      _retire(track);
      return;
    }
    if (initial) {
      track.revealed = true;
      return;
    }
    if (activity.showAfter > Duration.zero) {
      track.reveal = clock.timer(activity.showAfter, () {
        track.reveal = null;
        if (track.activity.status.finished) {
          _retire(track);
        } else {
          _reveal(track);
        }
        _refresh();
      });
      return;
    }
    _reveal(track);
  }

  void _reveal(_Track track) {
    track.revealed = true;
    final activity = track.activity;
    if (activity.status.trouble) {
      _cue(track, IslandCenter.troubleOpen, IslandHaptic.medium);
    } else if (activity.arrival == IslandArrival.open) {
      _cue(
        track,
        activity.openFor ?? IslandCenter.arrivalOpen,
        activity.kind == IslandKind.offer
            ? IslandHaptic.medium
            : IslandHaptic.selection,
      );
    }
  }

  void _changed(_Track track, IslandStatus before) {
    final activity = track.activity;
    final status = activity.status;
    if (track.retired) {
      if (!status.finished) {
        // Carried on (resumed, tried again): back on the small island.
        track
          ..retired = false
          ..revealed = true
          ..snoozed = false;
      }
      return;
    }
    if (!track.revealed) {
      if (status.finished) {
        track.reveal?.cancel();
        track.reveal = null;
        _retire(track);
      }
      return;
    }
    if (status.trouble && !before.trouble) {
      track.snoozed = false;
      _cue(track, IslandCenter.troubleOpen, IslandHaptic.medium);
    }
    switch (status) {
      case IslandStatus.done:
        if (_foreground && !track.snoozed) {
          haptics?.call(IslandHaptic.light);
        }
        _linger(track, IslandCenter.doneLingers);
      case IslandStatus.ended:
        _linger(track, IslandCenter.endedLingers);
      case IslandStatus.failed:
        track.linger?.cancel();
        track.linger = null;
      case IslandStatus.live || IslandStatus.paused || IslandStatus.waiting:
        track.linger?.cancel();
        track.linger = null;
    }
  }

  void _linger(_Track track, Duration duration) {
    track.linger?.cancel();
    track.linger = clock.timer(duration, () {
      track.linger = null;
      if (_held && _stage == IslandStage.expanded) {
        track.retireWhenReleased = true;
        return;
      }
      _retire(track);
      _refresh();
    });
  }

  void _retire(_Track track) {
    if (track.retired) {
      return;
    }
    track
      ..retired = true
      ..retireWhenReleased = false;
    track.linger?.cancel();
    track.linger = null;
    track.expiry?.cancel();
    track.expiry = null;
    if (_featured == track.activity.id) {
      _featured = null;
    }
    track.source.retired(track.activity.id);
  }

  void _spotlight(String id) {
    final track = _tracks[id];
    if (track == null || !track.revealed) {
      return;
    }
    track.snoozed = false;
    if (track.retired) {
      track.retired = false;
      if (track.activity.status == IslandStatus.done ||
          track.activity.status == IslandStatus.ended) {
        _linger(track, IslandCenter.arrivalOpen + IslandCenter.doneLingers);
      }
    }
    _cue(track, IslandCenter.arrivalOpen, IslandHaptic.selection);
    _refresh();
  }

  // -------------------------------------------------------------- stage

  /// Opens the card on [track] for [duration] (later, if in the background).
  void _cue(_Track track, Duration duration, IslandHaptic haptic) {
    final cue = _Cue(track.activity.id, duration, haptic);
    if (!_foreground) {
      final pending = _pending;
      final pendingTrack = pending == null ? null : _tracks[pending.id];
      if (pendingTrack == null ||
          rank(track.activity) >= rank(pendingTrack.activity)) {
        _pending = cue;
      }
      return;
    }
    _play(cue);
  }

  void _play(_Cue cue) {
    haptics?.call(cue.haptic);
    _featured = cue.id;
    _openFor(cue.duration, delayed: true);
  }

  void _openFor(Duration duration, {bool delayed = false}) {
    _closeTimer?.cancel();
    _closeTimer = null;
    _closeWhenReleased = false;
    _cancelExpiries();
    if (delayed && _stage != IslandStage.expanded) {
      if (_stage == IslandStage.hidden) {
        _stage = IslandStage.compact;
      }
      _openTimer?.cancel();
      _openTimer = clock.timer(IslandCenter.arrivalDelay, () {
        _openTimer = null;
        _expand(duration);
        _refresh();
      });
      return;
    }
    _openTimer?.cancel();
    _openTimer = null;
    _expand(duration);
  }

  void _expand(Duration duration) {
    _cancelExpiries();
    _stage = IslandStage.expanded;
    _closeTimer?.cancel();
    _closeTimer = clock.timer(duration, _autoClose);
  }

  void _autoClose() {
    _closeTimer = null;
    if (_held) {
      _closeWhenReleased = true;
      return;
    }
    _collapse();
    _refresh();
  }

  void _collapse() {
    _openTimer?.cancel();
    _openTimer = null;
    _closeTimer?.cancel();
    _closeTimer = null;
    _closeWhenReleased = false;
    _featured = null;
    _stage = _visible.isEmpty ? IslandStage.hidden : IslandStage.compact;
  }

  void _startExpiries() {
    if (!_foreground || _stage != IslandStage.compact || _openTimer != null) {
      return;
    }
    for (final track in _visible) {
      final waits = track.activity.waitsFor;
      if (waits == null || track.expiry != null) {
        continue;
      }
      track.expiry = clock.timer(waits, () {
        track.expiry = null;
        if (_held) {
          track.expiry = clock.timer(IslandCenter.afterRelease, () {
            track.expiry = null;
            track.source.expired(track.activity);
          });
          return;
        }
        track.source.expired(track.activity);
      });
    }
  }

  void _cancelExpiries() {
    for (final track in _tracks.values) {
      track.expiry?.cancel();
      track.expiry = null;
    }
  }

  void _refresh() {
    if (_disposed) {
      return;
    }
    final listed = [
      for (final track in _tracks.values)
        if (track.revealed &&
            !track.retired &&
            (!_quiet || _urgent(track.activity)))
          track,
    ]..sort(_order);
    _listed = listed;
    _visible = [
      for (final track in listed)
        if (!track.snoozed) track,
    ];
    if (_visible.isEmpty) {
      if (_openTimer == null) {
        _collapse();
      }
    } else if (_stage == IslandStage.hidden) {
      _stage = IslandStage.compact;
    }
    if (_stage == IslandStage.compact) {
      _startExpiries();
    }
    final pinned = _featured;
    if (pinned != null && !listed.any((t) => t.activity.id == pinned)) {
      _featured = null;
    }
    notifyListeners();
  }

  bool get _quiet => _immersive || _hushes > 0;

  static int _order(_Track a, _Track b) {
    final byRank = rank(b.activity).compareTo(rank(a.activity));
    if (byRank != 0) {
      return byRank;
    }
    final bySince = b.activity.since.compareTo(a.activity.since);
    if (bySince != 0) {
      return bySince;
    }
    return a.activity.id.compareTo(b.activity.id);
  }

  // ------------------------------------------------------------ gestures

  /// The small island tapped: it opens. The card tapped: it closes.
  void tap() {
    switch (_stage) {
      case IslandStage.compact:
        haptics?.call(IslandHaptic.light);
        _openFor(IslandCenter.tapOpen);
        _refresh();
      case IslandStage.expanded:
        collapse();
      case IslandStage.hidden:
        break;
    }
  }

  /// The circle beside the small island tapped: the card opens on it.
  void tapSecondary() {
    final second = secondary;
    if (second == null || _stage != IslandStage.compact) {
      return;
    }
    haptics?.call(IslandHaptic.light);
    _featured = second.id;
    _openFor(IslandCenter.tapOpen);
    _refresh();
  }

  void pullDown() {
    if (_stage == IslandStage.compact) {
      haptics?.call(IslandHaptic.light);
      _openFor(IslandCenter.tapOpen);
      _refresh();
    }
  }

  /// Swiped up: the card closes; the small island goes away (windows sent
  /// here are dismissed, finished ones leave, the rest wait out of sight).
  void swipeUp() {
    switch (_stage) {
      case IslandStage.expanded:
        haptics?.call(IslandHaptic.light);
        collapse();
      case IslandStage.compact:
        haptics?.call(IslandHaptic.light);
        for (final track in _visible) {
          final activity = track.activity;
          if (activity.kind == IslandKind.offer) {
            _retire(track);
            track.source.dismissed(activity);
          } else if (activity.status.finished) {
            _retire(track);
          } else {
            track.snoozed = true;
          }
        }
        _openTimer?.cancel();
        _openTimer = null;
        _featured = null;
        _stage = IslandStage.hidden;
        _refresh();
      case IslandStage.hidden:
        break;
    }
  }

  @override
  void collapse() {
    if (_stage != IslandStage.expanded && _openTimer == null) {
      return;
    }
    _collapse();
    _refresh();
  }

  @override
  void feature(String id) {
    if (!_listed.any((track) => track.activity.id == id)) {
      return;
    }
    haptics?.call(IslandHaptic.selection);
    _featured = id;
    if (_stage == IslandStage.expanded) {
      _openFor(IslandCenter.tapOpen);
    }
    _refresh();
  }

  @override
  void hold() => _held = true;

  @override
  void release() {
    if (!_held) {
      return;
    }
    _held = false;
    if (_closeWhenReleased) {
      _closeWhenReleased = false;
      _closeTimer?.cancel();
      _closeTimer = clock.timer(IslandCenter.afterRelease, _autoClose);
    }
    for (final track in _tracks.values) {
      if (track.retireWhenReleased) {
        track.retireWhenReleased = false;
        _linger(track, IslandCenter.afterRelease);
      }
    }
  }

  // ---------------------------------------------------------- the world

  /// The app is on screen (else the system notifications speak for it).
  void setForeground(bool value) {
    if (_foreground == value) {
      return;
    }
    _foreground = value;
    if (!value) {
      _openTimer?.cancel();
      _openTimer = null;
      _closeTimer?.cancel();
      _closeTimer = null;
      _closeWhenReleased = false;
      _cancelExpiries();
      if (_stage == IslandStage.expanded) {
        _stage = IslandStage.compact;
      }
      _featured = null;
      _held = false;
    } else {
      final cue = _pending;
      _pending = null;
      final track = cue == null ? null : _tracks[cue.id];
      if (cue != null &&
          track != null &&
          track.revealed &&
          !track.retired &&
          !track.snoozed) {
        _play(cue);
      }
    }
    _refresh();
  }

  /// Something fills the screen (status bar hidden): only what needs the
  /// user (windows sent here, trouble) shows.
  set immersive(bool value) {
    if (_immersive == value) {
      return;
    }
    _immersive = value;
    _refresh();
  }

  bool get immersive => _immersive;

  /// Keeping to what needs the user (something fills the screen).
  bool get quiet => _quiet;

  /// Keeps the island to what needs the user until the returned callback
  /// is called (a page that fills the screen).
  VoidCallback hush() {
    _hushes++;
    _refresh();
    var done = false;
    return () {
      if (done) {
        return;
      }
      done = true;
      _hushes--;
      _refresh();
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _openTimer?.cancel();
    _closeTimer?.cancel();
    for (final track in _tracks.values) {
      track.cancel();
    }
    for (final source in _sources) {
      source.removeListener(_sync);
    }
    for (final subscription in _spotlights.values) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}

class _Track {
  _Track(this.activity, this.source);

  IslandActivity activity;
  final IslandSource source;

  /// Past its [IslandActivity.showAfter]: the island knows of it.
  bool revealed = false;

  /// Seen and over (or put away): not shown again unless it carries on.
  bool retired = false;

  /// Swiped out of sight while under way: back when something changes.
  bool snoozed = false;
  bool retireWhenReleased = false;
  Timer? reveal;
  Timer? linger;
  Timer? expiry;

  void cancel() {
    reveal?.cancel();
    linger?.cancel();
    expiry?.cancel();
  }
}

class _Cue {
  const _Cue(this.id, this.duration, this.haptic);

  final String id;
  final Duration duration;
  final IslandHaptic haptic;
}
