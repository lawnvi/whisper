import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/helper.dart';

void main() {
  test(
    'uses a distinct icon and label for every supported device platform',
    () {
      final platforms = <String, (IconData, String)>{
        'android': (Icons.android_rounded, 'Android'),
        'ios': (Icons.apple_rounded, 'iPhone / iPad'),
        'macos': (Icons.laptop_mac_rounded, 'Mac'),
        'windows': (Icons.window_rounded, 'Windows'),
        'linux': (Icons.terminal_rounded, 'Linux'),
      };

      for (final entry in platforms.entries) {
        expect(platformIcon(entry.key), entry.value.$1);
        expect(platformLabel(entry.key), entry.value.$2);
      }
      expect(platforms.keys.map(platformIcon).toSet(), hasLength(5));
    },
  );

  test('normalizes common aliases and keeps unknown platform names', () {
    expect(platformIcon('Darwin'), Icons.laptop_mac_rounded);
    expect(platformIcon('win32'), Icons.window_rounded);
    expect(platformIcon('unknown-os'), Icons.devices_other_rounded);
    expect(platformLabel('unknown-os'), 'unknown-os');
  });

}
