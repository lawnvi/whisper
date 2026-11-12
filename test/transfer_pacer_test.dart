import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/incoming_transfer_parts.dart';
import 'package:whisper/socket/transfer_pacer.dart';

/// What a transfer over a simulated link came to: bytes a second carried
/// over the second half, the longest a frame waited behind others after the
/// first ten seconds, the longest nothing arrived for, and how long
/// something small and live, sent at any moment of the second half, waits
/// for the link to be free of file data (19 times in 20 no longer, and at
/// the worst).
typedef _Carried = ({
  double rate,
  Duration worstWait,
  Duration stillest,
  Duration liveWait,
  Duration worstLiveWait,
});

/// Sends through a pacer for [seconds], as the engine does, over a link
/// that carries [capacity] bytes a second ([capacityAt] when that changes on
/// the way) and never refuses a write: what it has not carried yet queues
/// up. The receiver answers by the real [IncomingAckClock], after writing
/// what came, which takes [answering] and holds up whatever comes
/// meanwhile. With [sleepy], whatever arrives after a quiet moment waits
/// that long first, as on a phone whose radio saves power. Something live
/// shares the link unless [live] says otherwise; with [busy] the pointer is
/// moving all the while.
Future<_Carried> _transfer(
  WidgetTester tester, {
  required double capacity,
  double Function(Duration at)? capacityAt,
  Duration sleepy = Duration.zero,
  Duration answering = const Duration(milliseconds: 3),
  bool live = true,
  bool busy = false,
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
  final pacer = TransferPacer(active: () => live, busy: () => busy, now: now);
  final clock = IncomingAckClock(now: now);
  var cursor = 0, acked = 0, received = 0, answered = 0;
  var writing = false, stopped = false;
  var linkFreeAt = Duration.zero, lastArrival = Duration.zero;
  var worstWait = Duration.zero, stillest = Duration.zero;
  Duration? arrivedAt;
  Completer<void>? wake;

  void answer() {
    if (received <= answered || writing) return;
    final since = answered, upTo = received;
    writing = true;
    // The write to disk before an answer: 500 MB/s. A receiver that takes
    // long over it reads nothing more from the link until it is done.
    final write =
        answering +
        Duration(microseconds: ((upTo - since) / 500e6 * 1e6).round());
    if (answering > const Duration(milliseconds: 50)) {
      final at = elapsed();
      linkFreeAt = (linkFreeAt > at ? linkFreeAt : at) + answering;
    }
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
        final waiting = wake;
        wake = null;
        waiting?.complete();
      });
    });
  }

  void arrived(int end) {
    final at = elapsed();
    final last = arrivedAt;
    if (last != null && at - last > stillest) stillest = at - last;
    arrivedAt = at;
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
    final carries = capacityAt?.call(at) ?? capacity;
    linkFreeAt =
        start + Duration(microseconds: (length / carries * 1e6).round());
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
      // As the engine does: an answer that comes while it is sending moves
      // the end on, it does not wait for the one after.
      final end = acked + pacer.inFlight(id, window, timely: true);
      if (cursor >= end) {
        wake = Completer<void>();
        await wake!.future;
        continue;
      }
      final length = math.min(pacer.frameBytes(chunk, id), end - cursor);
      await pacer.take(length);
      write(length);
      cursor += length;
      pacer.sent(id, cursor);
    }
  }());

  await tester.pump(Duration(seconds: seconds ~/ 2));
  final half = received;
  final liveWaits = <Duration>[];
  final sampling = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final busy = linkFreeAt - elapsed();
    liveWaits.add(busy > Duration.zero ? busy : Duration.zero);
  });
  await tester.pump(Duration(seconds: seconds - seconds ~/ 2));
  sampling.cancel();
  liveWaits.sort();
  final rate = (received - half) / (seconds - seconds ~/ 2);
  stopped = true;
  final waiting = wake;
  wake = null;
  waiting?.complete();
  pacer.dispose();
  // What is still on its way arrives; nothing follows.
  await tester.pump(const Duration(seconds: 30));
  return (
    rate: rate,
    worstWait: worstWait,
    stillest: stillest,
    liveWait: liveWaits[liveWaits.length * 19 ~/ 20],
    worstLiveWait: liveWaits.last,
  );
}

void main() {
  late DateTime now;
  late TransferPacer pacer;

  setUp(() {
    now = DateTime(2026);
    pacer = TransferPacer(now: () => now);
  });
  tearDown(() => pacer.dispose());

  test('frames are a quarter second of what the receiver confirms', () {
    expect(pacer.frameBytes(4 << 20), 512 << 10, reason: 'nothing known yet');
    pacer.sent('t', 1 << 20);
    pacer.acknowledged('t', 0);
    now = now.add(const Duration(seconds: 1));
    pacer.acknowledged('t', 200 << 10); // a slow link: 200 KiB/s
    expect(pacer.frameBytes(4 << 20), 48 << 10);
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

  // Transfers crawled while sound or pointer was shared: a seventh of the
  // link with sound, slower the longer it ran to a locked phone, seconds of
  // standing still at the start. Each time the pacer had slowed down for
  // something that was not the transfer's doing: an answer as late as the
  // frame it answers is large, a phone that answers later the less it is
  // sent, a speaker that is always about to run dry. It leaves a tenth of
  // what the link is counted to carry now, and goes by nothing else.
  group('with something live, over a link', () {
    testWidgets('that is fine, it takes most of what the link carries, '
        'leaves a little, and little queues', (tester) async {
      for (final capacity in [1e6, 8e6, 50e6]) {
        final carried = await _transfer(tester, capacity: capacity);
        expect(
          carried.rate,
          inInclusiveRange(capacity * 0.8, capacity * 0.95),
          reason: '$capacity',
        );
        expect(
          carried.worstWait,
          lessThan(const Duration(seconds: 1)),
          reason: '$capacity',
        );
        expect(
          carried.stillest,
          lessThan(const Duration(seconds: 2)),
          reason: '$capacity',
        );
        // The pointer lagged behind file data although a sixth of the
        // link was left over: frames of megabytes kept the link full for
        // most of every quarter second, and what was live waited 80 to
        // 200 ms behind each. In slices it is about 20.
        // Not on the slowest: its smallest frame alone is 16 ms of the
        // link, and frames further apart than a receiver waits before it
        // answers would have it answer every one.
        if (capacity > 2e6) {
          expect(
            carried.liveWait,
            lessThan(const Duration(milliseconds: 40)),
            reason: '$capacity',
          );
        }
      }
    });

    // Every ten seconds to two minutes it went over what the link carries
    // for a few seconds, to see whether it carries more, and the pointer
    // lagged for as long.
    testWidgets('while the pointer moves, it never goes over what the link '
        'carries', (tester) async {
      for (final capacity in [8e6, 50e6]) {
        final carried = await _transfer(
          tester,
          capacity: capacity,
          busy: true,
          seconds: 120,
        );
        expect(carried.rate, greaterThan(capacity * 0.8), reason: '$capacity');
        // One slice of ten milliseconds is all that is ever ahead of it.
        expect(
          carried.worstLiveWait,
          lessThan(const Duration(milliseconds: 20)),
          reason: '$capacity',
        );
      }
    });

    testWidgets('that gets slower or faster, it follows', (tester) async {
      final slower = await _transfer(
        tester,
        capacity: 50e6,
        capacityAt: (at) => at.inSeconds < 20 ? 50e6 : 20e6,
        seconds: 80,
      );
      expect(slower.rate, inInclusiveRange(20e6 * 0.8, 20e6 * 0.95));
      final faster = await _transfer(
        tester,
        capacity: 20e6,
        capacityAt: (at) => at.inSeconds < 20 ? 20e6 : 50e6,
        // It looks for more every half minute to two minutes.
        seconds: 240,
      );
      expect(faster.rate, greaterThan(50e6 * 0.8));
    });

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
      expect(carried.stillest, lessThan(const Duration(seconds: 2)));
    });

    // Such a receiver answers every frame that comes after a pause, and a
    // held transfer is all pauses: it gets through less the slower it is
    // sent to, and going under what it takes never ends.
    testWidgets('whose receiver takes long over every answer, it lets go '
        'rather than crawl', (tester) async {
      Future<_Carried> run({required bool live}) => _transfer(
        tester,
        capacity: 8e6,
        answering: const Duration(milliseconds: 250),
        live: live,
        seconds: 100,
      );
      final unheld = await run(live: false);
      final held = await run(live: true);
      expect(held.rate, greaterThan(unheld.rate * 0.8));
    });
  });

  // A transfer to a phone and then one to a desktop shared what the first
  // had counted: the second started held to the phone's link and crawled
  // until it found out, longer while the pointer moved.
  test('what the link carried is kept for the same device only', () {
    final live = TransferPacer(now: () => now);
    addTearDown(live.dispose);
    var offset = 0;
    unawaited(live.take(64 << 10, peer: 'phone'));
    for (var i = 0; i < 40; i++) {
      offset += 256 << 10; // about 1 MB/s
      live.sent('t', offset);
      now = now.add(const Duration(milliseconds: 250));
      live.acknowledged('t', offset, interval: 32 << 20, size: 1 << 30);
      live.evaluate();
    }
    expect(live.rate, lessThan(1e6), reason: 'held under the phone link');
    void rest() {
      now = now.add(const Duration(seconds: 3));
      live.evaluate();
      expect(live.rate, double.infinity);
    }

    rest();
    unawaited(live.take(64 << 10, peer: 'phone'));
    expect(live.rate, lessThan(1e6), reason: 'held from the start');
    rest();
    unawaited(live.take(64 << 10, peer: 'desktop'));
    expect(live.rate, double.infinity, reason: 'counts the desktop link');
  });

  test('with nothing live it holds nothing back', () async {
    final free = TransferPacer(active: () => false);
    addTearDown(free.dispose);
    for (var i = 0; i < 100; i++) {
      await free.take(64 << 20).timeout(const Duration(milliseconds: 50));
    }
  });
}
