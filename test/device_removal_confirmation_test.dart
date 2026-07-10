import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/page/deviceList.dart';

void main() {
  test('cancelling device removal never clears persisted data', () async {
    var confirmations = 0;
    var clears = 0;

    final removed = await removeDeviceAfterConfirmation(
      confirm: () async {
        confirmations += 1;
        return false;
      },
      clear: () async => clears += 1,
    );

    expect(removed, isFalse);
    expect(confirmations, 1);
    expect(clears, 0);
  });

  test('confirming device removal clears exactly once', () async {
    var confirmations = 0;
    var clears = 0;

    final removed = await removeDeviceAfterConfirmation(
      confirm: () async {
        confirmations += 1;
        return true;
      },
      clear: () async => clears += 1,
    );

    expect(removed, isTrue);
    expect(confirmations, 1);
    expect(clears, 1);
  });
}
