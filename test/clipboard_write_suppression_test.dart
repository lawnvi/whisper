import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/clipboard_write_suppression.dart';

void main() {
  test('observing the newest value retires skipped older generations', () {
    final queue = ClipboardWriteSuppressionQueue();
    queue.register(content: 'alpha', sourcePeerId: 'peer-a');
    queue.register(content: 'beta', sourcePeerId: 'peer-b');

    expect(queue.takeExact('beta')?.sourcePeerId, 'peer-b');
    expect(queue.takeExact('alpha'), isNull);
    expect(queue.takeExact('beta'), isNull);
  });

  test('suppression queue stays bounded', () {
    final queue = ClipboardWriteSuppressionQueue(capacity: 2);
    queue.register(content: 'alpha', sourcePeerId: 'peer-a');
    queue.register(content: 'beta', sourcePeerId: 'peer-b');
    queue.register(content: 'gamma', sourcePeerId: 'peer-c');

    expect(queue.takeExact('alpha'), isNull);
    expect(queue.takeExact('beta')?.sourcePeerId, 'peer-b');
    expect(queue.takeExact('gamma')?.sourcePeerId, 'peer-c');
  });

  test('failed writes remove their suppression', () async {
    final coordinator = ClipboardWriteCoordinator(
      writer: (_) => Future<void>.error(StateError('clipboard unavailable')),
    );

    await expectLater(
      coordinator.write('alpha', sourcePeerId: 'peer-a'),
      throwsStateError,
    );
    expect(coordinator.suppressions.takeExact('alpha'), isNull);
  });
}
