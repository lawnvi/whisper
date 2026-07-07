import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/dial_tiebreaker.dart';

void main() {
  test('both sides independently reach complementary decisions', () {
    const pairs = [
      ['aaa', 'bbb'],
      ['device-1', 'device-2'],
      ['Z', 'a'], // 大写 ASCII 序小于小写
    ];
    for (final pair in pairs) {
      final a = resolveSimultaneousDial(localUid: pair[0], remoteUid: pair[1]);
      final b = resolveSimultaneousDial(localUid: pair[1], remoteUid: pair[0]);
      expect(a == SimultaneousDialDecision.keepOutgoing,
          b == SimultaneousDialDecision.acceptIncoming,
          reason: '恰好一方保留出站: $pair');
    }
  });

  test('smaller uid keeps its outgoing dial', () {
    expect(resolveSimultaneousDial(localUid: 'aaa', remoteUid: 'bbb'),
        SimultaneousDialDecision.keepOutgoing);
    expect(resolveSimultaneousDial(localUid: 'bbb', remoteUid: 'aaa'),
        SimultaneousDialDecision.acceptIncoming);
  });

  test('equal uids keep outgoing to block self-connection', () {
    expect(resolveSimultaneousDial(localUid: 'same', remoteUid: 'same'),
        SimultaneousDialDecision.keepOutgoing);
  });
}
