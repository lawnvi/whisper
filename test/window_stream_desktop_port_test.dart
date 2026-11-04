import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';
import 'package:whisper/window_stream/remote/remote_peer_source.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';
import 'package:whisper/window_stream/remote/window_stream_host.dart';

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
  });

  group('desktop viewers', () {
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
  });
}
