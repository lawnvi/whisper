import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/cast_receiver/request_gate.dart';
import 'package:whisper/cast_receiver/receiver_name.dart';

void main() {
  test(
    'one prompt per source; declined retries stay blocked until reopened',
    () async {
      final gate = CastRequestGate()..open();
      addTearDown(gate.dispose);
      final first = gate.authorize('192.168.1.10');
      final duplicate = gate.authorize('192.168.1.10');
      expect(identical(first, duplicate), isTrue);
      expect(await gate.authorize('192.168.1.11'), isFalse);
      gate.decide(gate.pending!, false);
      expect(await first, isFalse);
      expect(await gate.authorize('192.168.1.10'), isFalse);
      expect(gate.pending, isNull);
      gate.open();
      final retry = gate.authorize('192.168.1.10');
      gate.decide(gate.pending!, true);
      expect(await retry, isTrue);
      expect(await gate.authorize('192.168.1.10'), isTrue);
      expect(gate.pending, isNull);
    },
  );

  test(
    'closing reception cancels a prompt and ignores its stale acceptance',
    () async {
      final gate = CastRequestGate()..open();
      addTearDown(gate.dispose);
      final response = gate.authorize('192.168.1.10');
      final request = gate.pending!;
      gate.presented(request);
      gate.close();
      gate.decide(request, true);
      expect(await response, isFalse);
      expect(await gate.authorize(request.address), isFalse);
      gate.open();
      final cancelled = gate.authorize(request.address);
      expect(gate.cancel(request.address), isTrue);
      expect(await cancelled, isFalse);
      expect(gate.pending, isNull);
    },
  );

  test(
    'auto acceptance waits five seconds after the prompt is presented',
    () async {
      final gate = CastRequestGate()..open();
      addTearDown(gate.dispose);
      final response = gate.authorize('192.168.1.10');
      final request = gate.pending!;
      expect(request.secondsRemaining, 5);
      gate.presented(request);
      expect(await response.timeout(const Duration(seconds: 7)), isTrue);
      expect(request.secondsRemaining, 0);
      expect(gate.pending, isNull);
    },
  );

  test(
    'receiver names migrate old defaults without a random suffix',
    () {
      String name(String saved, String id, {bool explicit = false}) =>
          castReceiverName(
            savedName: saved,
            systemName: '书房的 MacBook Air',
            deviceId: id,
            explicitlyNamed: explicit,
          );
      expect(name('MacBook Air', 'a'), '书房的 MacBook Air');
      expect(
        name('MacBook Air', 'a', explicit: true),
        'MacBook Air',
      );
      expect(name('客厅电脑', 'a'), '客厅电脑');
      expect(name('客厅电脑', 'a'), name('客厅电脑', 'b'));
    },
  );
}
