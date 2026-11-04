import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/discovery_resolve_limiter.dart';

void main() {
  test('deduplicates resolve attempts within the configured interval', () {
    final limiter = DiscoveryResolveLimiter(
      minimumInterval: const Duration(seconds: 5),
    );
    final first = DateTime(2026, 1, 1, 12, 0, 0);

    expect(limiter.shouldResolve('peer-a', now: first), isTrue);
    expect(
      limiter.shouldResolve(
        'peer-a',
        now: first.add(const Duration(seconds: 3)),
      ),
      isFalse,
    );
    expect(
      limiter.shouldResolve(
        'peer-a',
        now: first.add(const Duration(seconds: 5)),
      ),
      isTrue,
    );
  });
}
