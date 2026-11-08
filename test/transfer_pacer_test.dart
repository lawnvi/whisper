import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/transfer_pacer.dart';

void main() {
  // One look at the pacer: [sent] bytes went in the last tick.
  late DateTime now;
  late bool strained;
  late TransferPacer pacer;

  setUp(() {
    now = DateTime(2026);
    strained = false;
    pacer = TransferPacer(audioStrained: () => strained, now: () => now);
  });
  tearDown(() => pacer.dispose());

  Future<void> tick({required double sent}) async {
    // What went: taken without waiting on the real clock.
    final bytes = (sent * TransferPacer.tick.inMilliseconds / 1000).round();
    final at = now;
    final pending = pacer.take(bytes);
    now = at.add(TransferPacer.tick);
    pacer.evaluate();
    await pending.timeout(const Duration(seconds: 1), onTimeout: () {});
  }

  test('with the sound fine it speeds up as far as the link goes', () async {
    for (var i = 0; i < 20; i++) {
      await tick(sent: pacer.rate);
    }
    expect(pacer.rate, greaterThan(pacer.start * 4));
  });

  test('the sound suffering, it drops and stays below that speed', () async {
    for (var i = 0; i < 6; i++) {
      await tick(sent: pacer.rate);
    }
    final troubleAt = pacer.rate;
    strained = true;
    await tick(sent: troubleAt);
    expect(pacer.rate, closeTo(troubleAt * 0.6, 1));
    strained = false;
    for (var i = 0; i < 40; i++) {
      await tick(sent: pacer.rate);
    }
    expect(pacer.rate, lessThanOrEqualTo(troubleAt * 0.85 + 1));
  });

  test('frames are a quarter second of what the receiver confirms', () {
    expect(pacer.frameBytes(4 << 20), 512 << 10, reason: 'nothing known yet');
    pacer.sent('t', 1 << 20);
    pacer.acknowledged('t', 0);
    now = now.add(const Duration(seconds: 1));
    pacer.acknowledged('t', 200 << 10); // a slow link: 200 KiB/s
    expect(pacer.frameBytes(4 << 20), 64 << 10);
  });

  test('answers coming back later than the link takes empty slow it down', () {
    pacer.sent('t', 1 << 20);
    now = now.add(const Duration(milliseconds: 20));
    pacer.acknowledged('t', 1 << 20); // the link with nothing queued
    pacer.take(1);
    for (var i = 2; i < 6; i++) {
      pacer.sent('t', i << 20);
      now = now.add(const Duration(milliseconds: 400));
      pacer.acknowledged('t', i << 20); // each now waits behind a queue
    }
    final before = pacer.rate;
    now = now.add(TransferPacer.tick);
    pacer.evaluate();
    expect(pacer.queueDelay, greaterThan(const Duration(milliseconds: 80)));
    expect(pacer.rate, lessThan(before));
  });

  test('with nothing live it holds nothing back', () async {
    final free = TransferPacer(audioStrained: () => true, active: () => false);
    addTearDown(free.dispose);
    for (var i = 0; i < 100; i++) {
      await free.take(64 << 20).timeout(const Duration(milliseconds: 50));
    }
  });

  test('it never runs far ahead of what actually goes', () async {
    for (var i = 0; i < 20; i++) {
      await tick(sent: 10e6);
    }
    expect(pacer.rate, lessThan(10e6 * 1.3 + 2e6 + 1));
  });
}
