import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/transport_close_guard.dart';

void main() {
  test('close is invoked once and returns when the close deadline expires',
      () async {
    final releaseClose = Completer<void>();
    var closes = 0;
    final guard = TransportCloseGuard(
      close: () async {
        closes += 1;
        await releaseClose.future;
      },
      timeout: const Duration(milliseconds: 20),
    );

    final first = guard.close();
    final second = guard.close();

    expect(identical(first, second), isTrue);
    await first.timeout(const Duration(seconds: 1));
    expect(closes, 1);

    releaseClose.complete();
    await Future<void>.delayed(Duration.zero);
    await guard.close();
    expect(closes, 1);
  });
}
