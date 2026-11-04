import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/app_shutdown.dart';

void main() {
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
