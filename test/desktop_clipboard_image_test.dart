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
      tempDir =
          await Directory.systemTemp.createTemp('whisper_clipboard_test_');
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

    test('reads clipboard PNG bytes and writes a temp screenshot file',
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
    });

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
}
