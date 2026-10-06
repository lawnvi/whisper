import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/mobile_touchpad.dart';

void main() {
  late MobileTouchpad pad;
  late List<int> clicks;
  late List<(Offset, bool)> moves;
  late bool cancelled;
  setUp(() {
    clicks = [];
    moves = [];
    cancelled = false;
    pad = MobileTouchpad(
      move: (delta, {scroll = false}) => moves.add((delta, scroll)),
      click: clicks.add,
      flush: () {},
      cancel: () => cancelled = true,
    );
  });
  const zero = Duration.zero;
  Duration ms(int n) => Duration(milliseconds: n);
  test(
    'one finger tap clicks left, two fingers tap right once on final up',
    () {
      pad.down(1, Offset.zero, zero);
      pad.up(1, ms(50));
      expect(clicks, [0]);
      pad.down(1, Offset.zero, ms(100));
      pad.down(2, const Offset(40, 0), ms(130));
      pad.up(1, ms(200));
      expect(clicks, [0]);
      pad.up(2, ms(220));
      expect(clicks, [0, 1]);
      expect(moves, isEmpty);
    },
  );
  test('small two-finger jitter is a tap without wheel packets', () {
    pad.down(1, Offset.zero, zero);
    pad.down(2, const Offset(40, 0), ms(20));
    pad.update(1, const Offset(1, 2));
    pad.update(2, const Offset(41, 1));
    pad.up(2, ms(60));
    pad.up(1, ms(80));
    expect(clicks, [1]);
    expect(moves, isEmpty);
  });
  test(
    'scroll consumes pending motion and never clicks or moves cursor on lift',
    () {
      pad.down(1, Offset.zero, zero);
      pad.down(2, const Offset(40, 0), ms(20));
      pad.update(1, const Offset(0, 4));
      expect(moves, isEmpty);
      pad.update(2, const Offset(40, 20));
      pad.up(2, ms(80));
      pad.update(1, const Offset(0, 24));
      pad.up(1, ms(100));
      expect(clicks, isEmpty);
      expect(moves.map((m) => m.$2), everyElement(isTrue));
      expect(moves.fold(Offset.zero, (p, m) => p + m.$1), const Offset(0, 32));
    },
  );
  test(
    'late second touch, long hold, three fingers and cancel never right-click',
    () {
      pad.down(1, Offset.zero, zero);
      pad.down(2, const Offset(40, 0), ms(180));
      pad.up(2, ms(200));
      pad.up(1, ms(220));
      pad.down(1, Offset.zero, ms(300));
      pad.down(2, const Offset(40, 0), ms(330));
      pad.up(1, ms(700));
      pad.up(2, ms(720));
      pad.down(1, Offset.zero, ms(800));
      pad.down(2, const Offset(40, 0), ms(810));
      pad.down(3, const Offset(80, 0), ms(820));
      pad.up(3, ms(840));
      pad.up(2, ms(850));
      pad.up(1, ms(860));
      pad.down(1, Offset.zero, ms(900));
      pad.down(2, const Offset(40, 0), ms(920));
      pad.pointerCancel();
      pad.up(2, ms(940));
      pad.up(1, ms(950));
      expect(clicks, isEmpty);
      expect(cancelled, isTrue);
    },
  );
  test('reset invalidates old pointers, next gesture starts cleanly', () {
    pad.down(1, Offset.zero, zero);
    pad.reset();
    pad.update(1, const Offset(20, 0));
    pad.up(1, ms(50));
    expect(moves, isEmpty);
    expect(clicks, isEmpty);
    pad.down(2, Offset.zero, ms(100));
    pad.up(2, ms(140));
    expect(clicks, [0]);
  });
}
