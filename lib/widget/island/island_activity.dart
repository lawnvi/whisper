import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// What an activity on the island is about.
enum IslandKind {
  /// A window another device sent here, waiting to be viewed.
  offer,

  /// This phone's apps are shown (and can be used) on another device.
  streamed,

  /// A copy made in the file manager.
  copy,

  /// This device plays another device's sound.
  audio,
}

/// Where an activity stands, as far as the island cares.
enum IslandStatus {
  /// Under way.
  live,

  /// Stopped by the user for now (a paused speaker); nothing is wrong.
  paused,

  /// Held up by something outside: the connection went, it was paused by a
  /// reconnect. Worth a look.
  waiting,

  /// Did not work. Stays until put away or tried again.
  failed,

  /// Finished as it should: a tick for a moment, then it goes.
  done,

  /// Over without a result to show (stopped, disconnected): it goes soon.
  ended,
}

extension IslandStatusFacts on IslandStatus {
  bool get finished =>
      this == IslandStatus.done ||
      this == IslandStatus.ended ||
      this == IslandStatus.failed;

  /// Something is wrong: the island opens to say so.
  bool get trouble =>
      this == IslandStatus.waiting || this == IslandStatus.failed;
}

/// How a new activity comes in.
enum IslandArrival {
  /// The small island, then the card for a moment: the user sees what
  /// started (a paste, a window sent here, someone playing through this
  /// phone).
  open,

  /// Only the small island: it is shown elsewhere already (a file sent from
  /// the conversation shows its progress there).
  quiet,
}

/// What the island shows for an activity. Each source draws its own kind;
/// the island only lays the pieces out.
abstract class IslandPresenter {
  const IslandPresenter();

  /// The small island's content, laid out in a 36-point-high capsule.
  Widget compact(BuildContext context);

  /// The little circle beside the small island (about [size] across).
  Widget glyph(BuildContext context, double size);

  /// The activity at the top of the open card, with its actions.
  Widget featured(BuildContext context, IslandControls controls);

  /// One line in the open card below the featured activity.
  Widget row(BuildContext context, IslandControls controls);

  /// What a screen reader says for the small island.
  String describe(BuildContext context);
}

/// What views can ask of the island.
abstract class IslandControls {
  /// Back to the small island.
  void collapse();

  /// Shows [id] at the top of the open card.
  void feature(String id);

  /// The finger is on the island: nothing closes or leaves under it.
  void hold();
  void release();
}

/// One live activity, as a source sees it right now. Sources make a new one
/// whenever something changes; [id] ties them together.
@immutable
class IslandActivity {
  const IslandActivity({
    required this.id,
    required this.kind,
    required this.status,
    required this.since,
    required this.presenter,
    this.arrival = IslandArrival.open,
    this.openFor,
    this.waitsFor,
    this.showAfter = Duration.zero,
    this.urgent = false,
  });

  final String id;
  final IslandKind kind;
  final IslandStatus status;

  /// When it started: newer ones come first among equals.
  final DateTime since;
  final IslandPresenter presenter;
  final IslandArrival arrival;

  /// How long the card stays open when it arrives (default: a moment).
  final Duration? openFor;

  /// Once back to the small island, how long it waits before it lets go
  /// by itself (a window sent here); null: until it is over.
  final Duration? waitsFor;

  /// Only shown if still under way after this long: a quick transfer that
  /// is over at once never flashes up.
  final Duration showAfter;

  /// Shown even while something fills the screen (a window or photo viewed
  /// full screen, status bar hidden).
  final bool urgent;

  IslandActivity copyWith({IslandStatus? status}) => IslandActivity(
    id: id,
    kind: kind,
    status: status ?? this.status,
    since: since,
    presenter: presenter,
    arrival: arrival,
    openFor: openFor,
    waitsFor: waitsFor,
    showAfter: showAfter,
    urgent: urgent,
  );

  @override
  String toString() => 'IslandActivity($id, $kind, $status)';
}

/// Something the island shows activities of: file copies, the speaker, the
/// phone being streamed, windows sent here.
abstract class IslandSource implements Listenable {
  /// What is going on now. A finished activity stays here until the island
  /// says it is [retired], so its tick (or cross) can be seen.
  List<IslandActivity> get activities;

  /// Ids the island should open on (the user asked to see it again).
  Stream<String> get spotlights => const Stream<String>.empty();

  /// The island no longer shows [id] (it finished and was seen, or the user
  /// put it away); a source may forget it.
  void retired(String id) {}

  /// The user swiped [activity] away. A window sent here is then settled.
  void dismissed(IslandActivity activity) {}

  /// [activity] waited on the small island for its [IslandActivity.waitsFor].
  void expired(IslandActivity activity) {}

  void dispose() {}
}

/// A source made of a plain list, for tests and simple cases.
class IslandListSource extends ChangeNotifier implements IslandSource {
  IslandListSource([List<IslandActivity>? activities])
    : _activities = [...?activities];

  List<IslandActivity> _activities;
  final _spotlights = StreamController<String>.broadcast();
  final retiredIds = <String>[];
  final dismissedIds = <String>[];
  final expiredIds = <String>[];

  @override
  List<IslandActivity> get activities => List.unmodifiable(_activities);

  set activities(List<IslandActivity> value) {
    _activities = [...value];
    notifyListeners();
  }

  void put(IslandActivity activity) {
    final index = _activities.indexWhere((a) => a.id == activity.id);
    if (index < 0) {
      _activities = [..._activities, activity];
    } else {
      _activities = [..._activities]..[index] = activity;
    }
    notifyListeners();
  }

  void remove(String id) {
    _activities = [
      for (final a in _activities)
        if (a.id != id) a,
    ];
    notifyListeners();
  }

  void spotlight(String id) => _spotlights.add(id);

  @override
  Stream<String> get spotlights => _spotlights.stream;

  @override
  void retired(String id) => retiredIds.add(id);

  @override
  void dismissed(IslandActivity activity) => dismissedIds.add(activity.id);

  @override
  void expired(IslandActivity activity) => expiredIds.add(activity.id);

  @override
  void dispose() {
    unawaited(_spotlights.close());
    super.dispose();
  }
}

/// Time for the island, replaceable in tests.
class IslandClock {
  const IslandClock();

  DateTime now() => DateTime.now();

  Timer timer(Duration duration, void Function() callback) =>
      Timer(duration, callback);
}
