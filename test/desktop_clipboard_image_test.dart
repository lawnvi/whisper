import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/desktop_clipboard_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopClipboardImageReader', () {
    late Directory tempDir;
    late MethodChannel channel;
    late List<MethodCall> calls;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'whisper_clipboard_test_',
      );
      channel = const MethodChannel('test_desktop_clipboard_image');
      calls = <MethodCall>[];
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'reads clipboard PNG bytes and writes a temp screenshot file',
      () async {
        final pngBytes = Uint8List.fromList(<int>[137, 80, 78, 71, 1, 2, 3]);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return pngBytes;
            });
        final reader = DesktopClipboardImageReader(
          channel: channel,
          tempDirectoryProvider: () async => tempDir,
          nowProvider: () => DateTime(2026, 6, 27, 14, 30, 12),
        );

        final draft = await reader.readImageDraft();

        expect(calls.map((call) => call.method), <String>['readImagePng']);
        expect(draft, isNotNull);
        expect(draft!.fileName, 'Screenshot 2026-06-27 14.30.12.png');
        expect(draft.size, pngBytes.length);
        expect(draft.bytes, pngBytes);
        expect(p.basename(draft.path), draft.fileName);
        expect(await File(draft.path).readAsBytes(), pngBytes);
      },
    );

    test('returns null when the desktop platform has no image', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      final reader = DesktopClipboardImageReader(
        channel: channel,
        tempDirectoryProvider: () async => tempDir,
      );

      final draft = await reader.readImageDraft();

      expect(draft, isNull);
    });

    test('returns null when the platform channel is unavailable', () async {
      final reader = DesktopClipboardImageReader(
        channel: channel,
        tempDirectoryProvider: () async => tempDir,
      );

      final draft = await reader.readImageDraft();

      expect(draft, isNull);
    });
  });

  group('DesktopClipboardFileReader', () {
    late Directory tempDir;
    late MethodChannel channel;
    late List<MethodCall> calls;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'whisper_clipboard_file_test_',
      );
      channel = const MethodChannel('test_desktop_clipboard_files');
      calls = <MethodCall>[];
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('reads copied file paths and keeps only existing files', () async {
      final first = File(p.join(tempDir.path, 'first.txt'));
      final second = File(p.join(tempDir.path, 'second.png'));
      final directory = Directory(p.join(tempDir.path, 'folder'));
      await first.writeAsString('hello');
      await second.writeAsBytes(<int>[1, 2, 3, 4]);
      await directory.create();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return <String>[
              first.path,
              directory.path,
              p.join(tempDir.path, 'missing.txt'),
              second.path,
            ];
          });
      final reader = DesktopClipboardFileReader(channel: channel);

      final drafts = await reader.readFileDrafts();

      expect(calls.map((call) => call.method), <String>['readFilePaths']);
      expect(drafts.map((draft) => draft.path), <String>[
        first.path,
        second.path,
      ]);
      expect(drafts.map((draft) => draft.fileName), <String>[
        'first.txt',
        'second.png',
      ]);
      expect(drafts.map((draft) => draft.size), <int>[5, 4]);
    });

    test(
      'returns an empty list when the platform channel is unavailable',
      () async {
        final reader = DesktopClipboardFileReader(channel: channel);

        final drafts = await reader.readFileDrafts();

        expect(drafts, isEmpty);
      },
    );
  });
}
