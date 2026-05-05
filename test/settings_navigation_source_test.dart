import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings back buttons use the app bar foreground color', () {
    final source = File('lib/page/settings.dart').readAsStringSync();

    expect(
      RegExp(
        r'CupertinoNavigationBarBackButton\([\s\S]*?color: colorScheme\.primary,',
      ).allMatches(source),
      isEmpty,
    );
    expect(
      RegExp(
        r'CupertinoNavigationBarBackButton\([\s\S]*?color: colorScheme\.onSurface,',
      ).allMatches(source),
      hasLength(2),
    );
  });

  test('remote input auto mode sheet uses settings menu colors', () {
    final source = File('lib/page/settings.dart').readAsStringSync();
    final picker = RegExp(
      r'Future<void> _openRemoteInputAutoModePicker\([\s\S]*?Future<void> _openRemoteInputLayoutEditor',
    ).firstMatch(source)!.group(0)!;

    expect(
        picker, contains('final colorScheme = Theme.of(context).colorScheme;'));
    expect(
      picker,
      isNot(contains("child: const Text('关闭')")),
    );
    expect(
      picker,
      isNot(contains("child: const Text('本机控制对端')")),
    );
    expect(
      picker,
      isNot(contains("child: const Text('对端控制本机')")),
    );
    expect(
      RegExp(r'color: colorScheme\.onSurface').allMatches(picker),
      hasLength(4),
    );
    expect(picker, contains('style: const TextStyle(color: Colors.redAccent)'));
  });
}
