import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';
import 'package:whisper/window_stream/remote/window_stream_host.dart';

/// A window is shown in one place at a time, and a streamed window's
/// picture fits the window it is shown in.
void main() {
  group('one window, one place', () {
    late WindowStreamHost host;
    late Map<String, List<WindowStreamControlMessage>> sent;

    setUp(() {
      host = WindowStreamHost.withBackend(_Backend());
      sent = {};
    });

    Future<void> from(
      String viewer,
      WindowStreamControlAction action,
      String session, [
      Map<String, Object?> payload = const {},
    ]) => host.handleControl(
      WindowStreamControlMessage(
        action: action,
        sessionId: session,
        viewerPeerId: viewer,
        hostPeerId: 'host',
        payload: payload,
      ),
      remotePeerId: viewer,
      send: (message) async {
        (sent[viewer] ??= []).add(message);
        return true;
      },
    );

    test('opening it on another device moves it there', () async {
      await from('a', WindowStreamControlAction.open, 'session-one', {
        'windowId': 7,
        'viewportWidth': 800,
        'viewportHeight': 600,
        'pixelRatio': 2,
        'viewerName': 'MacBook',
      });
      expect(sent['a']!.last.action, WindowStreamControlAction.accept);

      // Others see where it is.
      await from('c', WindowStreamControlAction.browse, 'browse-session-c');
      final catalog = sent['c']!.last;
      expect(catalog.action, WindowStreamControlAction.catalog);
      final window = RemoteWindowInfo.fromJson(
        ((catalog.payload['windows'] as List).single as Map)
            .cast<String, Object?>(),
      );
      expect(window.viewerId, 'a');
      expect(window.viewerName, 'MacBook');

      await from('b', WindowStreamControlAction.open, 'session-two', {
        'windowId': 7,
      });
      final stop = sent['a']!.last;
      expect(stop.action, WindowStreamControlAction.stop);
      expect(stop.sessionId, 'session-one');
      expect(stop.payload['reason'], 'movedAway');
      expect(sent['b']!.last.action, WindowStreamControlAction.accept);
      expect(
        windowStreamFailureForWire('movedAway', stopping: true),
        WindowStreamFailureReason.movedAway,
      );
    });

    test('the same device opening it again just replaces its stream', () async {
      await from('a', WindowStreamControlAction.open, 'session-one', {
        'windowId': 7,
      });
      await from('a', WindowStreamControlAction.open, 'session-two', {
        'windowId': 7,
      });
      final stop = sent['a']!.firstWhere(
        (m) => m.action == WindowStreamControlAction.stop,
      );
      expect(stop.sessionId, 'session-one');
      expect(stop.payload['reason'], '');
    });
  });
}

class _Backend implements WindowCaptureBackend {
  int _next = 1;

  @override
  bool get supported => true;
  @override
  bool get inputPermitted => true;
  @override
  bool get opensApps => false;
  @override
  bool get audioSupported => false;

  @override
  void attach(void Function(CaptureEvent event) onEvent) {}

  @override
  Future<WindowStreamFailureReason?> unavailableReason() async => null;

  @override
  Future<CaptureResult> requestCatalog() async => CaptureResult(
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'windows': [
            {
              'id': 7,
              'appId': 'app',
              'appName': 'App',
              'title': 'App',
              'width': 800,
              'height': 600,
            },
          ],
          'apps': const [],
          'locked': false,
        }),
      ),
    ),
  );

  @override
  Future<CaptureResult> requestIcon(String appId, {int size = 128}) async =>
      CaptureResult.failed(1);
  @override
  Future<CaptureResult> requestThumbnail(int windowId, int maxEdge) async =>
      CaptureResult.failed(1);
  @override
  Future<CaptureResult> launchApp(String appId) async =>
      CaptureResult.failed(1);
  @override
  RemoteWindowInfo? appWindow(String appId) => null;
  @override
  void captureCloseWindow(int windowId, int pid) {}
  @override
  int captureStart(CaptureRequest request) => _next++;
  @override
  void captureStop(int capture) {}
  @override
  void captureSetPaused(int capture, bool paused) {}
  @override
  void captureRequestKeyframe(int capture) {}
  @override
  void captureSetBusy(int capture, bool busy) {}
  @override
  void captureSetScreen(int capture, int screenKey) {}
  @override
  void captureSetViewport(
    int capture,
    double width,
    double height,
    double scale,
  ) {}
  @override
  void captureSetInset(int capture, double fraction) {}
  @override
  void captureSetPixelRatio(int capture, double ratio) {}
  @override
  void captureSetBitRate(int capture, int bitRate) {}
  @override
  void captureSetAudio(int capture, int mode) {}
  @override
  void captureInput(
    int capture, {
    required int kind,
    int code = 0,
    int modifiers = 0,
    double x = 0,
    double y = 0,
    double dx = 0,
    double dy = 0,
    int phase = 0,
    String? text,
  }) {}
}
