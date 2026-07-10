import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/connection_coordinator.dart';

void main() {
  test('new attempts invalidate only the older attempt for the same target',
      () {
    final tracker = ConnectionAttemptTracker();
    final firstA = tracker.begin('peer-a');
    final firstB = tracker.begin('peer-b');
    final secondA = tracker.begin('peer-a');

    expect(tracker.isCurrent('peer-a', firstA), isFalse);
    expect(tracker.isCurrent('peer-a', secondA), isTrue);
    expect(tracker.isCurrent('peer-b', firstB), isTrue);
  });

  test('complete and cancellation reject late callbacks', () {
    final tracker = ConnectionAttemptTracker();
    final completed = tracker.begin('completed');
    final cancelled = tracker.begin('cancelled');
    final disposed = tracker.begin('disposed');

    expect(tracker.complete('completed', completed), isTrue);
    expect(tracker.complete('completed', completed), isFalse);
    tracker.cancel('cancelled');
    expect(tracker.isCurrent('cancelled', cancelled), isFalse);
    tracker.cancelAll();
    expect(tracker.isCurrent('disposed', disposed), isFalse);
  });
}
