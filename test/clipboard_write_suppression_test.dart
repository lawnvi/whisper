import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/clipboard_write_suppression.dart';

void main() {
  test('rapid remote values retain their generation and source', () {
    final queue = ClipboardWriteSuppressionQueue();
    final first = queue.register(content: 'alpha', sourcePeerId: 'peer-a');
    final second = queue.register(content: 'beta', sourcePeerId: 'peer-b');

    expect(second.generation, first.generation + 1);
    expect(queue.takeExact('alpha')?.sourcePeerId, 'peer-a');
    expect(queue.takeExact('beta')?.sourcePeerId, 'peer-b');
    expect(queue.takeExact('alpha'), isNull);
    expect(queue.takeExact('beta'), isNull);
  });

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

  test('concurrent writes are serialized and awaited', () async {
    final firstWrite = Completer<void>();
    final secondWrite = Completer<void>();
    final started = <String>[];
    final coordinator = ClipboardWriteCoordinator(
      writer: (content) {
        started.add(content);
        return content == 'alpha' ? firstWrite.future : secondWrite.future;
      },
    );

    var firstCompleted = false;
    var secondCompleted = false;
    final first = coordinator.write('alpha', sourcePeerId: 'peer-a')
      ..then((_) => firstCompleted = true);
    final second = coordinator.write('beta', sourcePeerId: 'peer-b')
      ..then((_) => secondCompleted = true);
    await Future<void>.delayed(Duration.zero);

    expect(started, <String>['alpha']);
    expect(firstCompleted, isFalse);
    expect(secondCompleted, isFalse);

    firstWrite.complete();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(started, <String>['alpha', 'beta']);
    expect(secondCompleted, isFalse);
    expect(coordinator.suppressions.takeExact('alpha')?.sourcePeerId, 'peer-a');

    secondWrite.complete();
    await second;
    expect(secondCompleted, isTrue);
    expect(coordinator.suppressions.takeExact('beta')?.sourcePeerId, 'peer-b');
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
