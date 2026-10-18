import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/android/window_activity.dart';
import 'package:whisper/window_stream/core/window_input_event.dart';

void main() {
  test('the window activity\'s touches and keys become stream input', () {
    final tap = NativeWindowActivity.inputOf({
      'type': 'pointer',
      'action': 'down',
      'x': 0.25,
      'y': 0.5,
      'button': 'secondary',
    });
    expect(tap, isA<PointerInput>());
    tap as PointerInput;
    expect(tap.action, PointerAction.down);
    expect(tap.button, PointerButton.secondary);
    expect([tap.x, tap.y], [0.25, 0.5]);

    final scroll =
        NativeWindowActivity.inputOf({
              'type': 'scroll',
              'phase': 'began',
              'x': 0.1,
              'y': 0.2,
              'dx': 0,
              'dy': -0.05,
            })
            as ScrollInput;
    expect(scroll.phase, ScrollPhase.began);
    expect(scroll.precise, isTrue);

    final key =
        NativeWindowActivity.inputOf({'type': 'key', 'down': true, 'code': 51})
            as KeyInput;
    expect([key.down, key.macKeyCode], [true, 51]);

    final text =
        NativeWindowActivity.inputOf({'type': 'text', 'text': '你好'})
            as TextInput;
    expect(text.text, '你好');
    expect(NativeWindowActivity.inputOf({'type': 'text', 'text': ''}), isNull);
  });

  test('pinyin drafts on the phone viewer are not sent as letters', () {
    final viewer = File(
      'lib/page/window_stream/viewer/viewer_keyboard.dart',
    ).readAsStringSync();
    expect(viewer, contains('composing.isCollapsed'));
  });

  test('the file manager\'s copies are not synced to other devices', () {
    final model = File(
      'lib/page/remote_files/files_model.dart',
    ).readAsStringSync();
    expect(model, contains('markOwnClipboardFiles(paths)'));
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    expect(deviceList, contains('if (isOwnClipboardFiles(paths))'));
  });
}
