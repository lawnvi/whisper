import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/window_stream/android/agent/phone_capture_backend.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';
import 'package:whisper/window_stream/remote/window_stream_host.dart';
import 'package:whisper/window_stream/window_stream_coordinator.dart';

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

    test('the viewer finds a window already open here by device, not by '
        'source object', () {
      final coordinator = File(
        'lib/window_stream/window_stream_coordinator.dart',
      ).readAsStringSync();
      expect(coordinator, contains('WindowStreamSession? openSessionFor('));
      expect(
        coordinator,
        contains('session.handle.source.info.id == source.info.id'),
      );
      expect(coordinator, isNot(contains('identical(session.handle.source')));
      final page = File(
        'lib/page/window_stream/flow_space_page.dart',
      ).readAsStringSync();
      expect(page, contains('l10n.flowTaskOpenOn('));
    });
  });

  group('picture quality', () {
    test(
      'the viewer\'s choice is remembered and scales the bit rate',
      () async {
        SharedPreferences.setMockInitialValues({
          'window_stream.quality': 'smooth',
        });
        final coordinator = WindowStreamCoordinator.shared;
        await coordinator.loadQuality();
        expect(coordinator.quality.value, WindowStreamQuality.smooth);
        await coordinator.setQuality(WindowStreamQuality.best);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('window_stream.quality'), 'best');

        expect(
          WindowStreamQuality.fromName('nonsense'),
          WindowStreamQuality.high,
        );
        expect(WindowStreamQuality.standard.scale(12000000), 12000000);
        expect(WindowStreamQuality.high.scale(12000000), 24000000);
        expect(WindowStreamQuality.smooth.scale(8000000), 4000000);
      },
    );
  });

  group('picture size', () {
    test('a phone window keeps the phone layout at the viewer density', () {
      const phonePoints = Size(411, 914);
      const phonePixels = Size(1080, 2400);
      final retina = PhoneCaptureBackend.displayFor(
        viewport: const Size(310, 690),
        pixelRatio: 2,
        phonePoints: phonePoints,
        phonePixels: phonePixels,
      )!;
      expect((retina.width, retina.height), (620, 1380));
      // Laid out 411 dp wide, as on the phone.
      expect(160 * retina.width / retina.dpi, closeTo(411, 2));

      final plain = PhoneCaptureBackend.displayFor(
        viewport: const Size(405, 900),
        pixelRatio: 1,
        phonePoints: phonePoints,
        phonePixels: phonePixels,
      )!;
      expect((plain.width, plain.height), (404, 900));
      expect(160 * plain.width / plain.dpi, closeTo(411, 3));

      // Never more pixels than the phone's own screen.
      final big = PhoneCaptureBackend.displayFor(
        viewport: const Size(1600, 1000),
        pixelRatio: 2,
        phonePoints: phonePoints,
        phonePixels: phonePixels,
      )!;
      expect(big.width, 2400);
      expect(big.height, 1500);
      expect(
        PhoneCaptureBackend.displayFor(
          viewport: Size.zero,
          pixelRatio: 2,
          phonePoints: phonePoints,
          phonePixels: phonePixels,
        ),
        isNull,
      );
    });

    test('an adb phone display follows the window at its own density', () {
      // Opened as 1080x2400 in a 405x900 point window.
      final wider = WindowStreamCoordinator.androidDisplaySize(
        const Size(600, 900),
        pixelsPerPoint: 1080 / 405,
        maxEdge: 2400,
      );
      expect((wider.width, wider.height), (1600, 2400));
      final landscape = WindowStreamCoordinator.androidDisplaySize(
        const Size(1200, 700),
        pixelsPerPoint: 1080 / 405,
        maxEdge: 2400,
      );
      expect(landscape.width, 2400);
      expect(landscape.height, 1400);
    });

    test('viewers say their pixel density and desktops resize freely', () {
      final viewer = File(
        'lib/window_stream/remote/remote_peer_source.dart',
      ).readAsStringSync();
      expect(viewer, contains("'pixelRatio': handle._pixelRatio,"));
      expect(viewer, contains("'pixelRatio': _pixelRatio,"));
      final coordinator = File(
        'lib/window_stream/window_stream_coordinator.dart',
      ).readAsStringSync();
      expect(coordinator, contains('handle is RemoteStreamHandle ||'));
      expect(coordinator, contains('reflow:'));
      expect(coordinator, contains('handle.setPixelRatio(scale);'));
      final mac = File(
        'packages/window_stream_native/macos/Classes/WindowCapture.swift',
      ).readAsStringSync();
      expect(mac, contains('viewerPixelRatio > 0'));
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
