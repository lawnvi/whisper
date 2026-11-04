import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/desktop_clipboard_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopClipboardFileReader', () {
    late Directory tempDir;
    late MethodChannel channel;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'whisper_clipboard_file_test_',
      );
      channel = const MethodChannel('test_desktop_clipboard_files');
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'composer keeps received images after the sharing cache is cleared',
      () async {
        final source = File(
          p.join(
            tempDir.path,
            'whisper_remote_clipboard',
            'session',
            'image.png',
          ),
        );
        await source.parent.create(recursive: true);
        await source.writeAsBytes([137, 80, 78, 71]);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async => [source.path]);
        final reader = DesktopClipboardFileReader(
          channel: channel,
          tempDirectoryProvider: () async => tempDir,
        );
        expect((await reader.readFileDrafts()).single.path, source.path);
        final draft = (await reader.readFileDrafts(
          retainRemoteFiles: true,
        )).single;
        await source.parent.delete(recursive: true);
        expect(draft.fileName, 'image.png');
        expect(await File(draft.path).readAsBytes(), [137, 80, 78, 71]);
      },
    );
  });
}
