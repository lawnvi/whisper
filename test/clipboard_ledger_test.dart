import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/clipboard/clipboard_ledger.dart';

/// A clipboard whose change count grows the way the system's does.
final class _FakeClipboard {
  int token = 100;
  void change() => token += 1;
}

void main() {
  test(
    'Whisper\'s own writes are never taken, however late the notice',
    () async {
      final clipboard = _FakeClipboard();
      final ledger = ClipboardLedger(readToken: () async => clipboard.token);
      await ledger.start();

      // What was on the clipboard at start is not sent.
      expect(await ledger.takeChange(), isNull);

      // Another device's text goes on the clipboard; the notice comes after an
      // arbitrary delay (the old 2-second window let a late one through).
      await ledger.ownWrite(() async => clipboard.change());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await ledger.takeChange(), isNull);

      // The user copies: taken once, however many notices come for it.
      clipboard.change();
      expect(await ledger.takeChange(), clipboard.token);
      expect(await ledger.takeChange(), isNull);

      // A write that failed still marks whatever it left behind as own.
      await expectLater(
        ledger.ownWrite<void>(() async {
          clipboard.change();
          throw StateError('write failed');
        }),
        throwsStateError,
      );
      expect(await ledger.takeChange(), isNull);
    },
  );

  test(
    'a user copy that overwrote an own write before its notice is taken',
    () async {
      final clipboard = _FakeClipboard();
      final ledger = ClipboardLedger(readToken: () async => clipboard.token);
      await ledger.start();

      await ledger.ownWrite(() async => clipboard.change());
      clipboard.change();
      // Both notices are handled now: only the user's change goes out.
      expect(await ledger.takeChange(), clipboard.token);
      expect(await ledger.takeChange(), isNull);
    },
  );

  test(
    'without tokens (phones) every change is offered and text decides',
    () async {
      final ledger = ClipboardLedger(readToken: () async => null);
      await ledger.start(currentText: 'on the clipboard at start');

      expect(ledger.syncedText, 'on the clipboard at start');
      expect(await ledger.takeChange(), 0);

      ledger.noteSynced('from another device');
      expect(ledger.syncedText, 'from another device');

      // Files or an image in between: the same text copied again goes out.
      ledger.noteNotText();
      expect(ledger.syncedText, isNull);
    },
  );
}
