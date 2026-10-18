import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';

import '../script/gen_wsn_keymap.dart';

void main() {
  test('wsn_keymap.h matches the generator', () {
    final current = File(wsnKeymapHeaderPath).readAsStringSync();
    expect(
      current,
      buildWsnKeymapHeader(),
      reason: 'run `dart run script/gen_wsn_keymap.dart`',
    );
    expect(current, contains('DO NOT EDIT'));
  });

  test('rows reuse remote-input codes', () {
    final keys = {for (final key in resolveWsnKeys()) key.name: key};
    for (final name in [
      'keyA',
      'digit5',
      'slash',
      'f12',
      'arrowUp',
      'delete',
    ]) {
      final codes = remoteInputKeyCodes(name);
      expect(keys[name]!.mac, codes.macKeyCode, reason: name);
      expect(keys[name]!.vk, codes.windowsKeyCode, reason: name);
      expect(keys[name]!.evdev, codes.linuxKeyCode, reason: name);
    }
    // Modifiers keep remote input's mac/evdev codes but use sided VKs.
    expect(keys['shiftLeft']!.mac, remoteInputKeyCodes('shift').macKeyCode);
    expect(keys['shiftLeft']!.vk, 0xA0);
    expect(keys['metaLeft']!.vk, remoteInputKeyCodes('meta').windowsKeyCode);
  });

  test('covers the keyboard', () {
    final keys = resolveWsnKeys();
    final macs = keys.map((key) => key.mac).toSet();
    // kVK_ANSI_A..Z, digits, F1–F20, keypad 0–9, sided modifiers.
    for (final mac in [
      0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, //
      17, 32, 9, 13, 7, 16, 6, //
      18, 19, 20, 21, 23, 22, 26, 28, 25, 29, //
      122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, //
      105, 107, 113, 106, 64, 79, 80, 90, //
      82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 65, 67, 69, 75, 76, 78, 81,
      55, 54, 56, 60, 58, 61, 59, 62, 57, //
      115, 119, 116, 121, 117, 114, 123, 124, 125, 126, 72, 73, 74,
    ]) {
      expect(macs, contains(mac), reason: 'mac key $mac');
    }
    final byName = {for (final key in keys) key.name: key};
    expect(byName['controlRight']!.extended, isTrue);
    expect(byName['controlRight']!.evdev, 97);
    expect(byName['numpadEnter']!.scan, 0x1C);
    expect(byName['numpadEnter']!.extended, isTrue);
    expect(byName['f20']!.evdev, 190);
  });
}
