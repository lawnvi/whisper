import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/file.dart';

void main() {
  late Directory tempDirectory;
  late File file;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync('whisper_reveal_');
    file =
        File('${tempDirectory.path}${Platform.pathSeparator}report final.txt')
          ..writeAsStringSync('content');
  });

  tearDown(() {
    tempDirectory.deleteSync(recursive: true);
  });

  test('macOS reveals the exact file with Finder', () async {
    final calls = <FileManagerCommand>[];

    final revealed = await revealFileInFileManager(
      file.path,
      platform: DesktopFileManagerPlatform.macOS,
      processRunner: (executable, arguments) async {
        calls.add(FileManagerCommand(executable, arguments));
        return ProcessResult(1, 0, '', '');
      },
    );

    expect(revealed, isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.executable, 'open');
    expect(calls.single.arguments, <String>['-R', file.path]);
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

  test('Linux prefers FileManager1 and falls back to installed managers',
      () async {
    final executables = <String>[];

    final revealed = await revealFileInFileManager(
      file.path,
      platform: DesktopFileManagerPlatform.linux,
      processRunner: (executable, arguments) async {
        executables.add(executable);
        if (executable == 'gdbus') {
          expect(arguments, contains('org.freedesktop.FileManager1.ShowItems'));
          expect(arguments.join(' '), contains(Uri.file(file.path).toString()));
          return ProcessResult(1, 1, '', 'unavailable');
        }
        if (executable == 'nautilus') {
          throw const ProcessException('nautilus', <String>[]);
        }
        expect(arguments, <String>['--select', file.path]);
        return ProcessResult(1, 0, '', '');
      },
    );

    expect(revealed, isTrue);
    expect(executables, <String>['gdbus', 'nautilus', 'dolphin']);
  });

  test('does not launch a file manager for a missing file', () async {
    var processStarted = false;

    final revealed = await revealFileInFileManager(
      '${tempDirectory.path}${Platform.pathSeparator}missing.txt',
      platform: DesktopFileManagerPlatform.macOS,
      processRunner: (executable, arguments) async {
        processStarted = true;
        return ProcessResult(1, 0, '', '');
      },
    );

    expect(revealed, isFalse);
    expect(processStarted, isFalse);
  });
}
