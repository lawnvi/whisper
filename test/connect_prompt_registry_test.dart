import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/connect_prompt_registry.dart';

void main() {
  test('register returns false and rebinds latest callback for duplicate peer',
      () {
    final registry = ConnectPromptRegistry();
    final calls = <String>[];

    expect(registry.register('peer-a', (allow) => calls.add('first:$allow')),
        isTrue);
    expect(registry.register('peer-a', (allow) => calls.add('second:$allow')),
        isFalse);

    registry.latestCallbackFor('peer-a')?.call(true);

    expect(calls, <String>['second:true']);
  });

  test('resolveAndClose invokes closer and removes prompt entry', () {
    final registry = ConnectPromptRegistry();
    final closes = <String>[];

    registry.register('peer-a', (_) {});
    registry.bindCloser('peer-a', () {
      closes.add('closed');
    });

    registry.resolveAndClose('peer-a');

    expect(closes, <String>['closed']);
    expect(registry.latestCallbackFor('peer-a'), isNull);
    expect(registry.register('peer-a', (_) {}), isTrue);
  });

  test('removeFor drops prompt without invoking closer', () {
    final registry = ConnectPromptRegistry();
    var closed = false;

    registry.register('peer-a', (_) {});
    registry.bindCloser('peer-a', () {
      closed = true;
    });
    registry.removeFor('peer-a');

    expect(closed, isFalse);
    expect(registry.latestCallbackFor('peer-a'), isNull);
  });

  test('bindCloser can run after duplicate callback rebind', () {
    final registry = ConnectPromptRegistry();
    VoidCallback? closer;

    registry.register('peer-a', (_) {});
    expect(registry.register('peer-a', (_) {}), isFalse);
    registry.bindCloser('peer-a', () {
      closer = () {};
    });
    registry.resolveAndClose('peer-a');

    expect(closer, isNotNull);
  });
}
