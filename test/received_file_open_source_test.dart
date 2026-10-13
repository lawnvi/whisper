import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows opens a received file without a command interpreter', () {
    final source = File('lib/helper/file.dart').readAsStringSync();
    final openFile = source.substring(
      source.indexOf('void openFile(String path) async {'),
      source.indexOf('Future<void> openDir('),
    );
    final windowsBranch = openFile.indexOf('if (Platform.isWindows) {');
    final plugin = openFile.indexOf('OpenFilex.open(path)');

    // open_filex runs `cmd /c start "" <path>` on Windows. With no space in
    // the path cmd takes `&` in the file name as the start of a command,
    // and the name comes from whoever sent the file.
    expect(windowsBranch, greaterThan(0));
    expect(plugin, greaterThan(windowsBranch));
    final branch = openFile.substring(windowsBranch, plugin);
    expect(branch, contains('openWithWindowsShell(path)'));
    expect(branch, contains('return;'));

    final helper = File(
      'lib/helper/windows_shell_open.dart',
    ).readAsStringSync();
    expect(helper, contains("'ShellExecuteW'"));
    expect(helper, isNot(contains('Process.')));
  });
}
