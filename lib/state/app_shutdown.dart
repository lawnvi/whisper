typedef AppShutdownStep = Future<void> Function();

class AppShutdownCoordinator {
  Future<void>? _inFlight;

  Future<void> run(List<AppShutdownStep> steps) {
    return _inFlight ??= _runSteps(steps);
  }

  Future<void> _runSteps(List<AppShutdownStep> steps) async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final step in steps) {
      try {
        await step();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }
}
