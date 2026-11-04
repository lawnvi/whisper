import 'dart:io';

import 'package:flutter_test/flutter_test.dart';


/// Every C/C++ source of one platform's plugin (split into common/,
/// receiver/, capture/ and exports_*), without the test tools.
String nativeSources(String platform) {
  final root = Directory('packages/window_stream_native/$platform');
  final files =
      root
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (file) =>
                RegExp(r'\.(c|cc|cpp|h|hpp)$').hasMatch(file.path) &&
                !file.path.contains('${Platform.pathSeparator}tools'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return files.map((file) => file.readAsStringSync()).join('\n');
}

/// Definitions of [name] in [source]: a line of return type words, the
/// name, its parameters and a body (calls and prototypes do not match).
int functionDefinitions(String source, String name) => RegExp(
  r'^[ \t]*(?:[A-Za-z_]\w*[ \t*&]+)*'
  '$name'
  r'[ \t]*\([^;{}]*\)\s*\{',
  multiLine: true,
).allMatches(source).length;

void main() {
  const header = 'packages/window_stream_native/src/window_stream_native.h';
  const bindings =
      'packages/window_stream_native/lib/window_stream_native.dart';
  const swiftDir = 'packages/window_stream_native/macos/Classes';

  test(
    'every C entry point exists in the Dart bindings and the macOS code',
    () {
      final functions = RegExp(r'\b(wsn_[a-z_]+)\(')
          .allMatches(File(header).readAsStringSync())
          .map((m) => m.group(1)!)
          .toSet();
      expect(functions, hasLength(greaterThanOrEqualTo(17)));
      final dart = File(bindings).readAsStringSync();
      final swift = Directory(swiftDir)
          .listSync()
          .whereType<File>()
          .map((file) => file.readAsStringSync())
          .join('\n');
      for (final name in functions) {
        expect(
          dart,
          contains("'$name'"),
          reason: '$name missing in Dart bindings',
        );
        expect(
          swift,
          contains('@_cdecl("$name")'),
          reason: '$name missing in Swift',
        );
      }
    },
  );

  test('Windows and Linux plugins define every C entry point', () {
    // DynamicLibrary lookups fail for the whole library if one is missing,
    // so a half-ported platform must still export (stub) all of them.
    final functions = RegExp(r'\b(wsn_[a-z_]+)\(')
        .allMatches(File(header).readAsStringSync())
        .map((m) => m.group(1)!)
        .toSet();
    expect(functions, hasLength(greaterThanOrEqualTo(36)));
    for (final platform in ['windows', 'linux']) {
      final source = nativeSources(platform);
      for (final name in functions) {
        // Exactly one: none fails to load, two fail to link.
        expect(
          functionDefinitions(source, name),
          1,
          reason: '$name must be defined once in the $platform plugin',
        );
      }
    }
  });

}
