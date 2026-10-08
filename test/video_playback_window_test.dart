import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/cast_receiver/playback_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windows = MethodChannel('mixin.one/desktop_multi_window');
  const channels = MethodChannel('mixin.one/desktop_multi_window/channels');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'local videos reuse their window and never send controls to casting',
    () async {
      SharedPreferences.setMockInitialValues({});
      final created = <String>[];
      final commands = <String>[];
      final uris = <String>[];
      final bridges = [
        PlaybackWindowBridge(),
        PlaybackWindowBridge(localVideo: true),
      ];
      addTearDown(() async {
        for (final bridge in bridges) {
          await bridge.events.setMethodCallHandler(null);
        }
        messenger.setMockMethodCallHandler(windows, null);
        messenger.setMockMethodCallHandler(channels, null);
      });
      messenger.setMockMethodCallHandler(windows, (call) async {
        if (call.method == 'createWindow') {
          final kind = (call.arguments as Map)['arguments'] as String;
          created.add(kind);
          // Exercise a ready event arriving before createWindow completes.
          await messenger.handlePlatformMessage(
            channels.name,
            codec.encodeMethodCall(
              MethodCall('methodCall', {
                'channel': 'whisper.$kind.events',
                'method': 'event',
                'arguments': {'name': 'ready', 'windowId': kind},
              }),
            ),
            (_) {},
          );
          return kind;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        if (call.method == 'invokeMethod') {
          final envelope = call.arguments as Map;
          final args = envelope['arguments'] as Map;
          commands.add('${envelope['channel']}:${args['command']}');
          final data = args['data'] as Map;
          if (data['url'] is String) uris.add(data['url'] as String);
          return {'failed': false, 'snapshot': <String, Object>{}};
        }
        return null;
      });
      await bridges.first.command('load', {
        'url': 'https://example.com/cast.mp4',
      });
      await Future.wait([
        bridges.last.openVideo('/tmp/first #中文.mp4', 'first.mp4'),
        bridges.last.openVideo('/tmp/second.mp4', 'second.mp4'),
      ]);
      await bridges.last.close();
      expect(created, ['cast_playback', 'video_playback']);
      expect(commands, [
        'mixin.one/window_controller/cast_playback:load',
        'mixin.one/window_controller/video_playback:load',
        'mixin.one/window_controller/video_playback:play',
        'mixin.one/window_controller/video_playback:load',
        'mixin.one/window_controller/video_playback:play',
        'mixin.one/window_controller/video_playback:shutdown',
      ]);
      expect(Uri.parse(uris[1]).toFilePath(), '/tmp/first #中文.mp4');
    },
  );
}
