import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/remote_input/mobile_control_hints.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('nothing shows until it knows what was seen', () {
    expect(MobileControlHints().once('touch', 'hint'), isNull);
  });

  test('a hint stays for the visit, and is gone on the next', () async {
    final first = MobileControlHints();
    await first.load();
    expect(first.once('touch', 'hint'), 'hint');
    expect(first.once('touch', 'hint'), 'hint');
    await Future<void>.delayed(Duration.zero);

    final second = MobileControlHints();
    await second.load();
    expect(second.once('touch', 'hint'), isNull);
    expect(second.once('text', 'other'), 'other');
  });
}
