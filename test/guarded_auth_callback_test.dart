import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/guarded_auth_callback.dart';
import 'package:whisper/helper/connection_request_registry.dart';

void main() {
  test('guarded callback only fires once', () {
    var calls = <bool>[];
    var resolvedWith = <bool>[];
    final guarded = GuardedAuthCallback(
      calls.add,
      onResolved: resolvedWith.add,
    );
    expect(guarded.resolved, isFalse);
    guarded.call(true);
    guarded.call(false);
    guarded.call(true);
    expect(calls, [true]);
    expect(resolvedWith, [true]);
    expect(guarded.resolved, isTrue);
  });

  test('registry resolves by requestId idempotently', () {
    final registry = ConnectionRequestRegistry();
    var calls = <bool>[];
    final guarded = GuardedAuthCallback(calls.add);
    final requestId = registry.register('peer-a', guarded);
    expect(requestId, startsWith('peer-a#'));
    expect(registry.resolve(requestId, true), isTrue);
    expect(registry.resolve(requestId, false), isFalse); // 已处理过
    expect(registry.resolve('peer-a#999', true), isFalse); // 未知 id
    expect(calls, [true]);
  });

  test('new request for same peer supersedes the old one', () {
    final registry = ConnectionRequestRegistry();
    final first = GuardedAuthCallback((_) {});
    final firstId = registry.register('peer-a', first);
    final second = GuardedAuthCallback((_) {});
    final secondId = registry.register('peer-a', second);
    expect(firstId, isNot(secondId));
    expect(registry.resolve(firstId, true), isFalse); // 旧的失效
    expect(registry.resolve(secondId, true), isTrue);
  });

  test('removeForPeer drops pending entry', () {
    final registry = ConnectionRequestRegistry();
    final guarded = GuardedAuthCallback((_) {});
    final id = registry.register('peer-a', guarded);
    expect(registry.removeForPeer('peer-a'), same(guarded));
    expect(registry.resolve(id, true), isFalse);
  });
}
