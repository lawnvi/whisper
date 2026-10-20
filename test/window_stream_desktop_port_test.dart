import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/window_stream/core/window_source.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';
import 'package:whisper/window_stream/remote/remote_peer_source.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';
import 'package:whisper/window_stream/remote/window_stream_host.dart';
import 'package:whisper/window_stream/window_stream_coordinator.dart';
import 'package:whisper/window_stream/window_stream_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('failure reasons', () {
    test('native codes map to wire reasons and back', () {
      const expected = {
        WindowStreamCaptureCode.unknown: null,
        WindowStreamCaptureCode.unsupported:
            WindowStreamFailureReason.hostUnsupported,
        WindowStreamCaptureCode.permission:
            WindowStreamFailureReason.capturePermission,
        WindowStreamCaptureCode.encoder:
            WindowStreamFailureReason.encoderFailed,
        WindowStreamCaptureCode.helper:
            WindowStreamFailureReason.helperUnavailable,
        WindowStreamCaptureCode.desktop:
            WindowStreamFailureReason.desktopUnsupported,
        WindowStreamCaptureCode.elevated:
            WindowStreamFailureReason.elevatedWindow,
        WindowStreamCaptureCode.protectedContent:
            WindowStreamFailureReason.windowProtected,
        WindowStreamCaptureCode.locked: WindowStreamFailureReason.sourceLocked,
      };
      for (final entry in expected.entries) {
        final wire = WindowStreamCaptureCode.wireReason(entry.key);
        expect(
          windowStreamFailureForWire(wire, stopping: true),
          entry.value,
          reason: 'code ${entry.key} ($wire)',
        );
      }
      // Unknown reasons from newer hosts still fail an open...
      expect(
        windowStreamFailureForWire('somethingNew'),
        WindowStreamFailureReason.appNotFound,
      );
      // ...but a stream that simply ended carries no failure.
      for (final reason in ['windowGone', 'timeout', 'overflow', '', null]) {
        expect(windowStreamFailureForWire(reason, stopping: true), isNull);
      }
    });

    test('texts name the other device and fit its platform', () {
      final zh = lookupAppLocalizations(const Locale('zh'));
      final en = lookupAppLocalizations(const Locale('en'));
      String text(
        AppLocalizations l10n,
        WindowStreamFailureReason reason,
        WindowStreamPlatform platform,
      ) => windowStreamFailureText(
        l10n,
        reason,
        platform: platform,
        device: 'loop-pc',
      );

      expect(
        text(
          zh,
          WindowStreamFailureReason.helperUnavailable,
          WindowStreamPlatform.linux,
        ),
        startsWith('loop-pc 还差一步'),
      );
      expect(
        text(
          en,
          WindowStreamFailureReason.desktopUnsupported,
          WindowStreamPlatform.linux,
        ),
        contains('GNOME on Wayland'),
      );
      // A Mac's permission text points at System Settings; Windows does not.
      expect(
        text(
          en,
          WindowStreamFailureReason.capturePermission,
          WindowStreamPlatform.macos,
        ),
        contains('System Settings'),
      );
      expect(
        text(
          en,
          WindowStreamFailureReason.capturePermission,
          WindowStreamPlatform.windows,
        ),
        isNot(contains('System Settings')),
      );
      expect(
        text(
          zh,
          WindowStreamFailureReason.hostUnsupported,
          WindowStreamPlatform.windows,
        ),
        contains('Windows 10'),
      );
      expect(
        text(
          en,
          WindowStreamFailureReason.elevatedWindow,
          WindowStreamPlatform.windows,
        ),
        contains('On loop-pc,'),
      );
      // A Linux source names what it is missing.
      expect(
        text(
          zh,
          WindowStreamFailureReason.encoderFailed,
          WindowStreamPlatform.linux,
        ),
        allOf(contains('FFmpeg'), contains('x264'), contains('openh264')),
      );
      expect(
        text(
          en,
          WindowStreamFailureReason.encoderFailed,
          WindowStreamPlatform.windows,
        ),
        isNot(contains('FFmpeg')),
      );
      // Without a name the sentence still reads well.
      expect(
        windowStreamFailureText(en, WindowStreamFailureReason.encoderFailed),
        startsWith("That device couldn't"),
      );
      // Old callers without a source keep their texts.
      expect(
        windowStreamFailureText(en, WindowStreamFailureReason.sourceLocked),
        en.windowStreamSourceLocked,
      );
      expect(
        windowStreamFailureText(
          en,
          WindowStreamFailureReason.capturePermission,
        ),
        en.windowStreamCapturePermission,
      );
      expect(
        windowStreamFailureText(en, WindowStreamFailureReason.adbUnavailable),
        en.windowStreamAdbMissing,
      );
    });
  });

  group('desktop viewers', () {
    test('every desktop and mobile platform can show windows', () {
      expect(supportsWindowStreamSink(), isTrue);
      final support = File(
        'lib/window_stream/window_stream_support.dart',
      ).readAsStringSync();
      expect(
        support,
        contains(
          '(Platform.isMacOS ||\n'
          '        Platform.isWindows ||\n'
          '        Platform.isLinux ||\n'
          '        Platform.isAndroid) &&\n'
          '    WindowStreamHost.shared.sharingAllowed &&\n'
          '    WindowStreamHost.shared.supported',
        ),
      );
    });

    test('a native window opens at the picture shape, bounded', () {
      const work = Size(1710, 993);
      // A landscape window is limited by 60 % of the width.
      expect(
        RemoteViewport.fitDesktopWindow(work, const Size(1400, 900)),
        const Size(1026, 660),
      );
      // A portrait one by 900 points of height.
      expect(
        RemoteViewport.fitDesktopWindow(work, const Size(1080, 2400)),
        const Size(366, 814),
      );
      // Tall screens stop at 900 points.
      expect(
        RemoteViewport.fitDesktopWindow(
          const Size(2560, 1400),
          const Size(800, 600),
        ),
        const Size(1200, 900),
      );
      // Tiny work areas still give a usable window.
      expect(
        RemoteViewport.fitDesktopWindow(
          const Size(300, 200),
          const Size(800, 600),
        ).height,
        greaterThanOrEqualTo(240),
      );
    });

    test('a desktop viewer gets one display per window, a phone one', () {
      int key(String session, WindowStreamViewerKind? kind) =>
          WindowStreamHost.screenKeyForViewer(
            viewerPeerId: 'viewer',
            sessionId: session,
            kind: kind,
          );
      const desktop = WindowStreamViewerKind.desktop;
      expect(key('a', desktop), isNot(key('b', desktop)));
      expect(key('a', desktop), key('a', desktop));
      const phone = WindowStreamViewerKind.phone;
      expect(key('a', phone), key('b', phone));
      // Viewers without the field keep sharing one display.
      expect(key('a', null), key('b', null));
      expect(key('a', null), key('a', phone));
      expect(WindowStreamViewerKind.parse('desktop'), desktop);
      expect(WindowStreamViewerKind.parse('watch'), isNull);
      expect(WindowStreamViewerKind.parse(7), isNull);
    });

    test('open says what kind of viewer and how big its window is', () async {
      SharedPreferences.setMockInitialValues({});
      final sent = <WindowStreamControlMessage>[];
      final viewer = WindowStreamViewer.shared
        ..sender = (peerId, message) async {
          sent.add(message);
          return true;
        }
        ..localPeerId = (_) => 'me';
      viewer.peerAvailable(
        peerId: 'host',
        name: 'loop-pc',
        platform: WindowStreamPlatform.linux,
        host: '127.0.0.1',
        port: 10002,
      );
      final source = viewer.sourceFor('host')!;
      final listing = source.tasks();
      await pumpEventQueue();
      final browse = sent.single;
      expect(browse.action, WindowStreamControlAction.browse);
      void reply(
        WindowStreamControlAction action,
        String session,
        Map<String, Object?> payload,
      ) {
        viewer.handleControl(
          WindowStreamControlMessage(
            action: action,
            sessionId: session,
            viewerPeerId: 'me',
            hostPeerId: 'host',
            payload: payload,
          ),
          remotePeerId: 'host',
          remoteHost: '127.0.0.1',
          sendKey: Uint8List(32),
          receiveKey: Uint8List(32),
        );
      }

      reply(WindowStreamControlAction.catalog, browse.sessionId, {
        'windows': [
          {
            'id': 42,
            'appId': 'org.gnome.TextEditor',
            'appName': 'Text Editor',
            'title': 'notes',
            'width': 1400,
            'height': 900,
          },
        ],
        'apps': [],
      });
      final tasks = await listing;
      expect(tasks.single.id, 42);

      final opening = source.open(
        OpenTask(tasks.single),
        const StreamOptions(),
      );
      await pumpEventQueue();
      final open = sent.last;
      expect(open.action, WindowStreamControlAction.open);
      expect(open.payload['viewerKind'], 'desktop');
      final planned = RemoteViewport.desktopWindow(1400, 900);
      expect(open.payload['viewportWidth'], planned.width.round());
      expect(open.payload['viewportHeight'], planned.height.round());

      // The host's reason reaches the caller as a failure it can explain.
      reply(WindowStreamControlAction.reject, open.sessionId, {
        'reason': 'helper',
      });
      await expectLater(
        opening,
        throwsA(
          isA<WindowStreamFailure>().having(
            (failure) => failure.reason,
            'reason',
            WindowStreamFailureReason.helperUnavailable,
          ),
        ),
      );

      // A browse refused for a reason to fix over there shows on the device.
      final again = source.apps();
      await pumpEventQueue();
      reply(WindowStreamControlAction.error, sent.last.sessionId, {
        'reason': 'desktopUnsupported',
      });
      await expectLater(again, throwsA(isA<WindowStreamFailure>()));
      expect(
        source.state.value.failure?.reason,
        WindowStreamFailureReason.desktopUnsupported,
      );
      viewer.peerGone('host');
    });

    test('a capture that fails on the host ends the window with why', () async {
      SharedPreferences.setMockInitialValues({});
      final sent = <WindowStreamControlMessage>[];
      final viewer = WindowStreamViewer.shared
        ..sender = (peerId, message) async {
          sent.add(message);
          return true;
        }
        ..localPeerId = (_) => 'me';
      viewer.peerAvailable(
        peerId: 'host2',
        name: 'win-pc',
        platform: WindowStreamPlatform.windows,
        host: '127.0.0.1',
        port: 10002,
      );
      final source = viewer.sourceFor('host2')!;
      Future<RemoteStreamHandle> openOne(int id) async {
        final opening = source.open(
          OpenTask(TaskEntry(id: id, appId: 'app', label: 'App')),
          const StreamOptions(),
        );
        await pumpEventQueue();
        if (sent.last.action == WindowStreamControlAction.browse) {
          viewer.handleControl(
            WindowStreamControlMessage(
              action: WindowStreamControlAction.catalog,
              sessionId: sent.last.sessionId,
              viewerPeerId: 'me',
              hostPeerId: 'host2',
              payload: const {'windows': [], 'apps': []},
            ),
            remotePeerId: 'host2',
            remoteHost: '127.0.0.1',
            sendKey: Uint8List(32),
            receiveKey: Uint8List(32),
          );
          await pumpEventQueue();
        }
        final open = sent.last;
        expect(open.action, WindowStreamControlAction.open);
        viewer.handleControl(
          WindowStreamControlMessage(
            action: WindowStreamControlAction.accept,
            sessionId: open.sessionId,
            viewerPeerId: 'me',
            hostPeerId: 'host2',
            payload: {'windowId': id, 'width': 800, 'height': 600},
            transportToken: 'token',
          ),
          remotePeerId: 'host2',
          remoteHost: '127.0.0.1',
          sendKey: Uint8List(32),
          receiveKey: Uint8List(32),
        );
        return await opening as RemoteStreamHandle;
      }

      void stop(RemoteStreamHandle handle, String reason) {
        viewer.handleControl(
          WindowStreamControlMessage(
            action: WindowStreamControlAction.stop,
            sessionId: handle.id,
            viewerPeerId: 'me',
            hostPeerId: 'host2',
            payload: {'reason': reason},
          ),
          remotePeerId: 'host2',
          remoteHost: '127.0.0.1',
          sendKey: Uint8List(32),
          receiveKey: Uint8List(32),
        );
      }

      final elevated = await openOne(5);
      stop(elevated, 'elevated');
      expect(elevated.state.value.status, StreamStatus.closed);
      expect(
        elevated.state.value.failure?.reason,
        WindowStreamFailureReason.elevatedWindow,
      );
      final closed = await openOne(6);
      stop(closed, 'windowGone');
      expect(closed.state.value.status, StreamStatus.closed);
      expect(closed.state.value.failure, isNull);
      viewer.peerGone('host2');
    });

    test('native resize events reach the host, without feedback loops', () {
      final backend = File(
        'lib/window_stream/pipeline/surface_backend.dart',
      ).readAsStringSync();
      expect(backend, contains('WsnWindowEvent.resized when a > 0 && b > 0'));
      final coordinator = File(
        'lib/window_stream/window_stream_coordinator.dart',
      ).readAsStringSync();
      expect(
        coordinator,
        contains('_onWindowResized(session, Size(width, height), scale)'),
      );
      // Whisper peers' windows follow; an adb phone's display takes the
      // window's shape at its own density.
      expect(coordinator, contains('handle.setPixelRatio(scale);'));
      expect(
        coordinator,
        contains('!session.source.info.capabilities.resizeReflow'),
      );
      expect(coordinator, contains('resizing too often; keeping its size'));
      final host = File(
        'lib/window_stream/remote/window_stream_host.dart',
      ).readAsStringSync();
      // Every desktop sets the capture callback (it triggers crash rescue).
      expect(host, contains('if (_isDesktop) {\n      _attachNative();'));
    });
  });
}
