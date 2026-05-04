typedef AppShutdownStep = Future<void> Function();

class AppShutdownCoordinator {
  Future<void>? _inFlight;

  Future<void> run(List<AppShutdownStep> steps) {
    return _inFlight ??= _runSteps(steps);
  }

  Future<void> _runSteps(List<AppShutdownStep> steps) async {
    for (final step in steps) {
      await step();
    }
  }
}
