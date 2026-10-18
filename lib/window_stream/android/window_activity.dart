import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;

import '../core/window_input_event.dart';
import '../core/window_stream_models.dart';
import '../remote/remote_peer_source.dart';
import '../window_stream_coordinator.dart';
import '../window_stream_log.dart';

/// Another device's window as an Android task of its own
/// (WindowStreamActivity): it sits in recents next to other apps, opens in
/// landscape, and the decoder draws straight into it. Its touches, keys and
/// comings and goings arrive here and become the session's input and state.
abstract final class NativeWindowActivity {
  static const _channel = MethodChannel(
    'com.vireen.whisper/window_stream_activity',
  );
  static WindowStreamCoordinator? _coordinator;
  static bool _installed = false;
  static final _watched = <int>{};

  /// Each window's picture as it last looked here (JPEG), by
  /// "source id/window id": its card in recents shows that, upright as it
  /// was shown, the way a phone's recents show apps.
  static final lastFrames = ValueNotifier<Map<String, Uint8List>>(const {});

  static String frameKey(String sourceId, int windowId) =>
      '$sourceId/$windowId';

  /// Mac windows on an Android phone or tablet.
  static bool supports(WindowStreamSession session) =>
      Platform.isAndroid && session.handle is RemoteStreamHandle;

  /// Opens the window's activity, or brings it to the front.
  static Future<bool> open(
    WindowStreamSession session, {
    WindowStreamCoordinator? coordinator,
  }) async {
    _install(coordinator ?? WindowStreamCoordinator.shared);
    _watch(session);
    final title = '${session.handle.title} · ${session.source.info.name}';
    final handle = session.handle;
    // What the activity shows until the picture settles (sent while it
    // opens; a thumbnail or icon fetched meanwhile follows when it comes).
    if (!session.firstFrameShown) {
      unawaited(_sendPlaceholder(session, coordinator));
    }
    if (handle is RemoteStreamHandle && handle.textFocus.value) {
      unawaited(
        _channel.invokeMethod('textFocus', {
          'id': session.surface,
          'typing': true,
        }),
      );
    }
    return await _channel.invokeMethod<bool>('open', {
          'id': session.surface,
          'title': title,
          'scale': RemoteViewport.scale,
          'landscape': RemoteViewport.landscape,
        }) ??
        false;
  }

  /// The window as it last looked here, else the source's thumbnail of
  /// it, else the app's icon; with the words for a long wait.
  static Future<void> _sendPlaceholder(
    WindowStreamSession session,
    WindowStreamCoordinator? coordinator,
  ) async {
    final handle = session.handle;
    final connecting =
        (coordinator ?? WindowStreamCoordinator.shared).strings.connecting;
    Future<void> send({Uint8List? picture, Uint8List? icon}) =>
        _channel.invokeMethod('placeholder', {
          'id': session.surface,
          'picture': picture,
          'icon': icon,
          'connecting': connecting,
        });
    try {
      Uint8List? picture;
      if (handle is RemoteStreamHandle) {
        picture = lastFrames
            .value[frameKey(session.source.info.id, handle.window.id)];
      }
      await send(picture: picture);
      if (picture != null) {
        return;
      }
      if (handle is RemoteStreamHandle && handle.window.id != 0) {
        picture = await session.source
            .snapshot(
              TaskEntry(
                id: handle.window.id,
                appId: handle.window.appId,
                label: handle.title,
              ),
            )
            .timeout(const Duration(seconds: 3), onTimeout: () => null);
        if (picture != null) {
          await send(picture: picture);
          return;
        }
      }
      final icon = await session.source
          .icon(handle.target.appId)
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
      if (icon != null) {
        await send(icon: icon);
      }
    } catch (_) {
      // The spinner alone.
    }
  }

  static Future<void> finish(int surface) =>
      _channel.invokeMethod('finish', {'id': surface});

  static void _install(WindowStreamCoordinator coordinator) {
    _coordinator = coordinator;
    if (_installed) {
      return;
    }
    _installed = true;
    _channel.setMethodCallHandler(_onCall);
  }

  /// The stream ended (closed here, on the Mac, or the connection dropped):
  /// the task goes away with it.
  static void _watch(WindowStreamSession session) {
    final surface = session.surface;
    if (!_watched.add(surface)) {
      return;
    }
    final state = session.handle.state;
    final handle = session.handle;
    // The keyboard comes up by itself when a text field takes focus there.
    final textFocus = handle is RemoteStreamHandle ? handle.textFocus : null;
    void followFocus() {
      unawaited(
        _channel.invokeMethod('textFocus', {
          'id': surface,
          'typing': textFocus!.value,
        }),
      );
    }

    textFocus?.addListener(followFocus);
    // The source's SIZE messages, for the activity's "picture is stable".
    (int, int)? sentSize;
    void followSize() {
      final width = state.value.videoWidth;
      final height = state.value.videoHeight;
      if (width == null || height == null || sentSize == (width, height)) {
        return;
      }
      sentSize = (width, height);
      unawaited(
        _channel.invokeMethod('videoSize', {
          'id': surface,
          'width': width,
          'height': height,
        }),
      );
    }

    state.addListener(followSize);
    followSize();
    void listener() {
      if (state.value.isTerminal) {
        state.removeListener(listener);
        state.removeListener(followSize);
        textFocus?.removeListener(followFocus);
        _watched.remove(surface);
        unawaited(finish(surface));
      }
    }

    state.addListener(listener);
  }

  static Future<void> _onCall(MethodCall call) async {
    final coordinator = _coordinator;
    final args = (call.arguments as Map?)?.cast<String, Object?>();
    if (coordinator == null || args == null) {
      return;
    }
    final surface = (args['id'] as num?)?.toInt();
    WindowStreamSession? session;
    for (final candidate in coordinator.sessions) {
      if (candidate.surface == surface) {
        session = candidate;
        break;
      }
    }
    if (session == null) {
      if (surface != null && args['event'] != 'closed') {
        unawaited(finish(surface));
      }
      return;
    }
    final handle = session.handle;
    final canPause = session.source.info.capabilities.suspend;
    switch (args['event']) {
      case 'input':
        final event = inputOf(args);
        if (event != null) {
          coordinator.input(session.id, event);
        }
      case 'shown':
        if (canPause && session.state.status == StreamStatus.suspended) {
          await coordinator.resume(session);
        }
      case 'hidden':
        if (canPause && session.state.status == StreamStatus.live) {
          await coordinator.pause(session);
        }
      case 'closed':
        await coordinator.close(session);
      case 'viewport':
        if (handle is RemoteStreamHandle) {
          await handle.setViewport(
            width: (args['width'] as num?)?.toInt() ?? 0,
            height: (args['height'] as num?)?.toInt() ?? 0,
          );
        }
      case 'latency':
        // From a key leaving here to the first picture after it.
        WindowStreamLog.write(
          'window ${session.id.substring(0, 8)} keys ${args['keys']}: '
          'key to picture median ${(args['ms'] as num?)?.toInt()} ms, '
          'max ${(args['max'] as num?)?.toInt()} ms',
        );
      case 'snapshot':
        final jpeg = args['jpeg'];
        if (jpeg is Uint8List && handle is RemoteStreamHandle) {
          lastFrames.value = {
            ...lastFrames.value,
            frameKey(session.source.info.id, handle.window.id): jpeg,
          };
        }
      case 'keyboard':
        final inset = (args['inset'] as num?)?.toDouble() ?? 0;
        if (handle is RemoteStreamHandle) {
          await handle.setKeyboardInset(inset);
        }
      case 'orientation':
        // Turned with the window's rotate button: the next ones open so.
        await RemoteViewport.setLandscape(args['landscape'] == true);
      case 'textScale':
        final scale = (args['scale'] as num?)?.toDouble();
        if (handle is RemoteStreamHandle && scale != null) {
          await handle.setTextScale(scale);
        }
    }
  }

  /// One input event as the activity reports it.
  static WindowInputEvent? inputOf(Map<String, Object?> args) {
    double number(String key) => (args[key] as num?)?.toDouble() ?? 0;
    switch (args['type']) {
      case 'pointer':
        final action = switch (args['action']) {
          'down' => PointerAction.down,
          'move' => PointerAction.move,
          'up' => PointerAction.up,
          _ => PointerAction.cancel,
        };
        return PointerInput(
          action: action,
          x: number('x'),
          y: number('y'),
          button: args['button'] == 'secondary'
              ? PointerButton.secondary
              : PointerButton.primary,
        );
      case 'scroll':
        return ScrollInput(
          x: number('x'),
          y: number('y'),
          dx: number('dx'),
          dy: number('dy'),
          phase: switch (args['phase']) {
            'began' => ScrollPhase.began,
            'ended' => ScrollPhase.ended,
            _ => ScrollPhase.changed,
          },
          precise: true,
        );
      case 'key':
        return KeyInput(
          down: args['down'] == true,
          macKeyCode: (args['code'] as num?)?.toInt() ?? 0,
        );
      case 'text':
        final text = args['text'];
        return text is String && text.isNotEmpty ? TextInput(text) : null;
    }
    return null;
  }
}
