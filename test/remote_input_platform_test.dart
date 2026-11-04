import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RemoteInputPlatform', () {
    late MethodChannel channel;
    late List<MethodCall> calls;
    late List<RemoteInputTextShortcut> textShortcuts;
    late RemoteInputPlatform platform;

    setUp(() {
      channel = const MethodChannel('test_remote_input');
      calls = <MethodCall>[];
      textShortcuts = <RemoteInputTextShortcut>[];
      platform = RemoteInputPlatform(
        channel: channel,
        textShortcutHandler: (shortcut) {
          textShortcuts.add(shortcut);
          return true;
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('keeps zero release edge unit for segment-start returns', () async {
      await platform.pauseCapture(sessionId: 'input-1', releaseEdgeUnit: 0);

      expect(calls.single.method, 'pauseCapture');
      expect(calls.single.arguments['releaseEdgeUnit'], 0);
    });

    test('replays local paste without a focused Flutter field', () async {
      platform.configureLocalPasteHandler(() async => true);

      final shouldReplay = await platform.handleNativeMethodCall(
        const MethodCall('onLocalPasteShortcut', <String, dynamic>{
          'sessionId': 'workspace-1',
          'appActive': true,
        }),
      );

      expect(shouldReplay, isTrue);
      expect(textShortcuts, isEmpty);
    });

    test('replays local paste when the controller app is not active', () async {
      platform.configureLocalPasteHandler(() async => true);

      final shouldReplay = await platform.handleNativeMethodCall(
        const MethodCall('onLocalPasteShortcut', <String, dynamic>{
          'sessionId': 'workspace-1',
          'appActive': false,
        }),
      );

      expect(shouldReplay, isTrue);
      expect(textShortcuts, isEmpty);
    });
  });
}
