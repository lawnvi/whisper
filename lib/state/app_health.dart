import 'package:flutter/foundation.dart';
import 'package:whisper/helper/app_log.dart';

/// What can go wrong that nothing else on screen would show. Without these the
/// app looks fine and simply finds nobody.
enum AppProblem {
  /// The database cannot be opened: no devices, no history, and nothing after it.
  database,

  /// Starting up failed or did not finish, for another reason.
  startup,

  /// Other devices cannot connect to this one.
  server,

  /// This device cannot find others, or they it.
  discovery,
}

/// Whether Whisper is actually working, for the island to say when it is not and
/// for the diagnostics to report.
class AppHealth extends ChangeNotifier {
  static final shared = AppHealth();

  final _problems = <AppProblem>{};

  /// An older install's database is there and can't be read: its history stays
  /// where it is. Nothing is broken, so it is only reported.
  bool oldHistoryUnreadable = false;

  bool has(AppProblem problem) => _problems.contains(problem);

  /// The one to say first: the earlier ones explain the later ones.
  AppProblem? get worst {
    for (final problem in AppProblem.values) {
      if (_problems.contains(problem)) return problem;
    }
    return null;
  }

  Iterable<AppProblem> get problems => _problems;

  void report(AppProblem problem, [Object? error, StackTrace? stack]) {
    AppLog.shared.recordError(problem.name, error, stack);
    if (_problems.add(problem)) notifyListeners();
  }

  void clear(AppProblem problem) {
    if (_problems.remove(problem)) notifyListeners();
  }

  /// What failed on the way up: the database, or something else.
  static AppProblem classifyStartup(Object error) {
    final type = error.runtimeType.toString();
    return type.contains('Sqlite') || type.contains('Drift')
        ? AppProblem.database
        : AppProblem.startup;
  }
}
