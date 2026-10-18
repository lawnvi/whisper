import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:whisper/widget/island/island_activity.dart';

/// A clock whose timers fire only when told to.
class FakeIslandClock extends IslandClock {
  FakeIslandClock([DateTime? start])
    : _now = start ?? DateTime(2026, 10, 17, 12);

  DateTime _now;
  final _timers = <FakeIslandTimer>[];

  @override
  DateTime now() => _now;

  @override
  Timer timer(Duration duration, void Function() callback) {
    final timer = FakeIslandTimer._(_now.add(duration), callback);
    _timers.add(timer);
    return timer;
  }

  /// Moves time on, firing what falls due on the way, in order.
  void advance(Duration duration) {
    final end = _now.add(duration);
    while (true) {
      final due =
          _timers.where((t) => t.isActive && !t._at.isAfter(end)).toList()
            ..sort((a, b) => a._at.compareTo(b._at));
      if (due.isEmpty) {
        break;
      }
      final next = due.first;
      _now = next._at;
      next._fire();
    }
    _now = end;
    _timers.removeWhere((t) => !t.isActive);
  }
}

class FakeIslandTimer implements Timer {
  FakeIslandTimer._(this._at, this._callback);

  final DateTime _at;
  final void Function() _callback;
  bool _active = true;
  int _ticks = 0;

  void _fire() {
    if (!_active) {
      return;
    }
    _active = false;
    _ticks++;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;
}

/// Draws an activity as its label, for tests.
class LabelPresenter extends IslandPresenter {
  const LabelPresenter(this.label, {this.detail = ''});

  final String label;
  final String detail;

  @override
  Widget compact(BuildContext context) => Center(
    child: Text(
      'compact:$label',
      style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 13),
    ),
  );

  @override
  Widget glyph(BuildContext context, double size) => SizedBox.square(
    dimension: size,
    child: Text(
      'glyph:$label',
      style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 6),
    ),
  );

  @override
  Widget featured(BuildContext context, IslandControls controls) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(
      'featured:$label $detail',
      style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 15),
    ),
  );

  @override
  Widget row(BuildContext context, IslandControls controls) => SizedBox(
    height: 44,
    child: Text(
      'row:$label',
      style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 13),
    ),
  );

  @override
  String describe(BuildContext context) => label;
}

IslandActivity islandActivity(
  String id, {
  IslandKind kind = IslandKind.copy,
  IslandStatus status = IslandStatus.live,
  DateTime? since,
  IslandArrival arrival = IslandArrival.open,
  Duration? openFor,
  Duration? waitsFor,
  Duration showAfter = Duration.zero,
  bool urgent = false,
}) => IslandActivity(
  id: id,
  kind: kind,
  status: status,
  since: since ?? DateTime(2026, 10, 17, 12),
  presenter: LabelPresenter(id),
  arrival: arrival,
  openFor: openFor,
  waitsFor: waitsFor,
  showAfter: showAfter,
  urgent: urgent,
);
