import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/app_shutdown.dart';

void main() {
  test('runs shutdown steps in order only once', () async {
    final coordinator = AppShutdownCoordinator();
    final calls = <String>[];

    Future<void> first() async {
      calls.add('first');
    }

    Future<void> second() async {
      calls.add('second');
    }

    await coordinator.run([first, second]);
    await coordinator.run([second, first]);

    expect(calls, ['first', 'second']);
  });

  test('continues cleanup after an earlier shutdown step fails', () async {
    final coordinator = AppShutdownCoordinator();
    final calls = <String>[];

    final shutdown = coordinator.run([
      () async {
        calls.add('failing');
        throw StateError('failed');
      },
      () async {
        calls.add('database');
      },
    ]);

    await expectLater(shutdown, throwsStateError);
    expect(calls, ['failing', 'database']);
  });
}
