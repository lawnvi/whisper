import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/incoming_transfer_parts.dart';
import 'package:whisper/socket/transfer_pacer.dart';

/// What a transfer over a simulated link came to.
typedef _Carried = ({double rate, Duration worstWait});

/// Sends through a live pacer for [seconds], as the engine does, over a link
/// that carries [capacity] bytes a second and never refuses a write: what it
/// has not carried yet queues up. The receiver answers by the real
/// [IncomingAckClock], after writing what came. With [sleepy], whatever
/// arrives after a quiet moment waits that long first, as on a phone whose
/// radio saves power. Gives the rate carried over the second half and the
/// longest a frame waited behind others after the first ten seconds.
Future<_Carried> _transfer(
  WidgetTester tester, {
  required double capacity,
  Duration sleepy = Duration.zero,
  int seconds = 40,
}) async {
  const id = 't';
  const chunk = 4 << 20;
  const interval = 32 << 20;
  const window = 64 << 20;
  const size = 1 << 40;
  const latency = Duration(milliseconds: 2);
  final began = tester.binding.clock.now();
  DateTime now() => tester.binding.clock.now();
  Duration elapsed() => now().difference(began);
  final pacer = TransferPacer(audioStrained: () => false, now: now);
  final clock = IncomingAckClock(now: now);
  var cursor = 0, acked = 0, received = 0, answered = 0;
  var writing = false, stopped = false;
  var linkFreeAt = Duration.zero, lastArrival = Duration.zero;
  var worstWait = Duration.zero;
  Completer<void>? wake;

  void answer() {
    if (received <= answered || writing) return;
    final since = answered, upTo = received;
    writing = true;
    // The write to disk before an answer: 500 MB/s.
    final write = Duration(
      microseconds: 3000 + ((upTo - since) / 500e6 * 1e6).round(),
    );
    Timer(write, () {
      writing = false;
      answered = upTo;
      clock.answered(id);
      if (received > answered) clock.remind(id, answer);
      Timer(latency, () {
        pacer.acknowledged(
          id,
          upTo,
          interval: interval,
          size: size,
          since: since,
        );
        acked = upTo;
        wake?.complete();
        wake = null;
      });
    });
  }

  void arrived(int end) {
    received = end;
    if (clock.due(
      id,
      received: received,
      answered: answered,
      interval: interval,
    )) {
      answer();
    } else {
      clock.remind(id, answer);
    }
  }

  void write(int length) {
    final at = elapsed();
    final start = at > linkFreeAt ? at : linkFreeAt;
    if (at > const Duration(seconds: 10) && start - at > worstWait) {
      worstWait = start - at;
    }
    linkFreeAt =
        start + Duration(microseconds: (length / capacity * 1e6).round());
    var arrival = linkFreeAt + latency;
    if (sleepy > Duration.zero &&
        arrival - lastArrival > const Duration(milliseconds: 40)) {
      arrival += sleepy;
      linkFreeAt += sleepy;
    }
    lastArrival = arrival;
    final end = cursor + length;
    Timer(arrival - at, () => arrived(end));
  }

  unawaited(() async {
    while (!stopped) {
      final end = acked + pacer.inFlight(id, window, timely: true);
      while (cursor < end && !stopped) {
        final length = math.min(pacer.frameBytes(chunk, id), end - cursor);
        await pacer.take(length);
        write(length);
        cursor += length;
        pacer.sent(id, cursor);
      }
      wake = Completer<void>();
      await wake!.future;
    }
  }());

  await tester.pump(Duration(seconds: seconds ~/ 2));
  final half = received;
  await tester.pump(Duration(seconds: seconds - seconds ~/ 2));
  final rate = (received - half) / (seconds - seconds ~/ 2);
  stopped = true;
  wake?.complete();
  pacer.dispose();
  // What is still on its way arrives; nothing follows.
  await tester.pump(const Duration(seconds: 30));
  return (rate: rate, worstWait: worstWait);
}

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
    expect(pacer.frameBytes(4 << 20), 48 << 10);
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

  test('an old receiver is never held back', () {
    const window = 64 << 20;
    pacer.acknowledged('t', 0, interval: 32 << 20, size: 100 << 20);
    now = now.add(const Duration(seconds: 1));
    pacer.acknowledged('t', 32 << 20, interval: 32 << 20, size: 100 << 20);
    expect(pacer.inFlight('t', window, timely: false), window);
  });

  test('a fast link opens within a few answers', () {
    const window = 64 << 20;
    expect(pacer.inFlight('t', window, timely: true), 128 << 10);
    var sent = 0;
    for (var answer = 0; answer < 6; answer++) {
      sent += pacer.inFlight('t', window, timely: true);
      pacer.sent('t', sent);
      now = now.add(const Duration(milliseconds: 5));
      pacer.acknowledged('t', sent, interval: 32 << 20, size: 1 << 30);
    }
    expect(pacer.inFlight('t', window, timely: true), window);
  });

  test('once answers queue it is held to two seconds of the link', () {
    const window = 64 << 20;
    var offset = 0;
    void frame(Duration took) {
      offset += 64 << 10;
      pacer.sent('t', offset);
      now = now.add(took);
      pacer.acknowledged('t', offset, interval: 32 << 20, size: 1 << 30);
    }

    frame(const Duration(milliseconds: 20)); // nothing queued
    for (var i = 0; i < 8; i++) {
      frame(const Duration(milliseconds: 600)); // 64 KiB waits behind a queue
    }
    expect(pacer.queueDelay, greaterThan(const Duration(milliseconds: 80)));
    // About 107 KiB/s confirmed: two seconds of it.
    expect(pacer.inFlight('t', window, timely: true), lessThan(512 << 10));
    expect(pacer.queueDelay, greaterThanOrEqualTo(Duration.zero));
  });

  group('with something live, over a link', () {
    // Transfers went at a third of a healthy Wi-Fi link while sound or
    // pointer was shared, and slower the longer they ran. An answer to a
    // frame takes as long as the frame does to cross the link; that passed
    // for a queue, and every look slowed the transfer again.
    testWidgets('that is fine, most of what it carries goes '
        'and little queues', (tester) async {
      for (final capacity in [1e6, 8e6, 30e6]) {
        final carried = await _transfer(tester, capacity: capacity);
        expect(carried.rate, greaterThan(capacity * 0.6), reason: '$capacity');
        expect(
          carried.worstWait,
          lessThan(const Duration(seconds: 1)),
          reason: '$capacity',
        );
      }
    });

    // A locked phone answered later the less it was sent. Each late answer
    // slowed the transfer, which made the next later still: 0.1 MB/s over a
    // link that carried 3.
    testWidgets('whose receiver saves power, it does not slow to a crawl', (
      tester,
    ) async {
      const capacity = 3.3e6;
      final carried = await _transfer(
        tester,
        capacity: capacity,
        sleepy: const Duration(milliseconds: 150),
      );
      expect(carried.rate, greaterThan(capacity * 0.2));
    });
  });

  // Slowing down again and again for a sound that suffers for another
  // reason only made the transfer slow.
  test('while the sound suffers whatever it does, it gives way three times '
      'and no further', () async {
    for (var i = 0; i < 6; i++) {
      await tick(sent: pacer.rate);
    }
    final before = pacer.rate;
    strained = true;
    final rates = <double>[];
    for (var i = 0; i < 80; i++) {
      await tick(sent: pacer.rate);
      rates.add(pacer.rate);
    }
    expect(rates.last, closeTo(before * 0.6 * 0.6 * 0.6, 1));
    expect(rates[40], rates.last);
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
