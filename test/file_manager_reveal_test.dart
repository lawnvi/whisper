import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/file.dart';

void main() {
  late Directory tempDirectory;
  late File file;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync('whisper_reveal_');
    file = File(
      '${tempDirectory.path}${Platform.pathSeparator}report final.txt',
    )..writeAsStringSync('content');
  });

  tearDown(() {
    tempDirectory.deleteSync(recursive: true);
  });

  test('Linux opens a folder without a shell reading its name', () async {
    // What a sender could name a folder so that a shell would run part of it.
    final folder = '${tempDirectory.path}/notes \$(touch pwned) `id`; ls';
    final calls = <FileManagerCommand>[];

    await openLinuxDirectory(
      folder,
      processRunner: (executable, arguments) async {
        calls.add(FileManagerCommand(executable, arguments));
        return ProcessResult(1, 0, '', '');
      },
    );

    expect(calls, hasLength(1));
    expect(calls.single.executable, 'xdg-open');
    expect(calls.single.arguments, <String>[folder]);

    // The plugin that does this on Windows pastes the path into a command
    // line for `sh` on Linux, so it must stay out of the Linux branch.
    final source = File('lib/helper/file.dart').readAsStringSync();
    final linuxBranch = source.substring(
      source.indexOf('} else if (Platform.isLinux) {\n    await open'),
      source.indexOf('} else if (Platform.isWindows) {\n    final openDir'),
    );
    expect(linuxBranch, contains('openLinuxDirectory(path)'));
    expect(linuxBranch, isNot(contains('OpenDir')));
  });

  test('Windows passes the file separately from the select switch', () async {
    final calls = <FileManagerCommand>[];

    final revealed = await revealFileInFileManager(
      file.path,
      platform: DesktopFileManagerPlatform.windows,
      processRunner: (executable, arguments) async {
        calls.add(FileManagerCommand(executable, arguments));
        return ProcessResult(1, 0, '', '');
      },
    );

    expect(revealed, isTrue);
    expect(calls.single.executable, 'explorer.exe');
    expect(calls.single.arguments, <String>['/select,', file.path]);
  });

  test('Explorer exiting with 1 still counts as shown', () async {
    final revealed = await revealFileInFileManager(
      file.path,
      platform: DesktopFileManagerPlatform.windows,
      processRunner: (executable, arguments) async =>
          ProcessResult(1, 1, '', ''),
    );

    expect(revealed, isTrue);
  });
}
