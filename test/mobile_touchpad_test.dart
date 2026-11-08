import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/mobile_touchpad.dart';

void main() {
  late MobileTouchpad pad;
  late List<int> clicks;
  late List<(Offset, bool)> moves;
  setUp(() {
    clicks = [];
    moves = [];
    pad = MobileTouchpad(
      move: (delta, {scroll = false}) => moves.add((delta, scroll)),
      click: clicks.add,
      flush: () {},
      cancel: () {},
    );
  });
  const zero = Duration.zero;
  Duration ms(int n) => Duration(milliseconds: n);
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
