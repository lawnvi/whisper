import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/helper/screenshot_shortcut.dart';

// Wayland delegates selection and global shortcut consent to the compositor.
class LinuxScreenshotPortal {
  LinuxScreenshotPortal({required this.onShortcut, DBusClient? client})
    : _client = client ?? DBusClient.session();

  static const _service = 'org.freedesktop.portal.Desktop';
  static const _screenshot = 'org.freedesktop.portal.Screenshot';
  static const _shortcuts = 'org.freedesktop.portal.GlobalShortcuts';
  static const _shortcutId = 'region-screenshot';
  final void Function() onShortcut;
  final DBusClient _client;
  late final _desktop = _object('/org/freedesktop/portal/desktop');
  StreamSubscription<DBusSignal>? _activation;
  String? _session;
  final Set<String> _requests = {};

  DBusRemoteObject _object(String path) =>
      DBusRemoteObject(_client, name: _service, path: DBusObjectPath(path));

  String _token() => 'whisper_${const Uuid().v4().replaceAll('-', '')}';

  Future<Map<String, DBusValue>?> _request(
    String interface,
    String method,
    List<DBusValue> Function(DBusDict options) arguments, {
    Map<String, DBusValue> options = const {},
  }) async {
    await _client.getNameOwner(_service);
    final token = _token();
    var handle =
        '/org/freedesktop/portal/desktop/request/'
        '${_client.uniqueName.substring(1).replaceAll('.', '_')}/$token';
    final completer = Completer<DBusSignal>();
    final earlySignals = <String, DBusSignal>{};
    final subscription =
        DBusSignalStream(
          _client,
          sender: _service,
          interface: 'org.freedesktop.portal.Request',
          name: 'Response',
          signature: DBusSignature('ua{sv}'),
        ).listen(
          (signal) {
            earlySignals[signal.path.value] = signal;
            if (signal.path.value == handle && !completer.isCompleted) {
              completer.complete(signal);
            }
          },
          onError: (Object error) {
            if (!completer.isCompleted) completer.completeError(error);
          },
        );
    _requests.add(handle);
    try {
      // Flush AddMatch before invoking a portal that may reply immediately.
      await _client.getId();
      final reply = await _desktop
          .callMethod(
            interface,
            method,
            arguments(
              DBusDict.stringVariant({
                'handle_token': DBusString(token),
                ...options,
              }),
            ),
            replySignature: DBusSignature('o'),
          )
          .timeout(const Duration(seconds: 15));
      _requests.remove(handle);
      handle = reply.returnValues.first.asObjectPath().value;
      _requests.add(handle);
      final early = earlySignals[handle];
      if (early != null && !completer.isCompleted) completer.complete(early);
      final response = await completer.future.timeout(
        const Duration(minutes: 2),
      );
      final code = response.values[0].asUint32();
      if (code == 1) return null;
      if (code != 0) throw PlatformException(code: 'portal-denied');
      return response.values[1].asStringVariantDict();
    } finally {
      await subscription.cancel();
      _requests.remove(handle);
      await _closeObject(handle, 'org.freedesktop.portal.Request');
    }
  }

  Future<bool> captureRegion() async {
    try {
      final properties = await _desktop.getAllProperties(_screenshot);
      final version = properties['version']?.asUint32() ?? 0;
      if (version < 2 ||
          (version >= 3 &&
              ((properties['AvailableTargets']?.asUint32() ?? 0) & 4) == 0)) {
        throw PlatformException(code: 'unavailable');
      }
      final response = await _request(
        _screenshot,
        'Screenshot',
        (options) => [const DBusString(''), options],
        options: {
          'interactive': const DBusBoolean(true),
          'modal': const DBusBoolean(false),
          if (version >= 3) 'target': const DBusUint32(4),
        },
      );
      if (response == null) return false;
      final uri = Uri.parse(response['uri']!.asString());
      if (uri.scheme != 'file' ||
          (uri.host.isNotEmpty && uri.host != 'localhost')) {
        throw PlatformException(code: 'capture-failed');
      }
      final file = File.fromUri(uri);
      if (!await file.exists() ||
          !await const DesktopClipboardFileWriter().writeFilePaths([
            file.path,
          ], asImage: true)) {
        throw PlatformException(code: 'clipboard-failed');
      }
      // Portal-owned files may be in the user's Pictures directory; do not delete them.
      return true;
    } on DBusMethodResponseException {
      throw PlatformException(code: 'unavailable');
    }
  }

  Future<String?> setShortcut(
    ScreenshotShortcut? shortcut,
    String description,
  ) async {
    if (shortcut == null) {
      final oldSession = _session;
      _session = null;
      if (oldSession != null) {
        await _closeObject(oldSession, 'org.freedesktop.portal.Session');
      }
      await _activation?.cancel();
      _activation = null;
      return null;
    }
    String? pendingSession;
    try {
      // Introspection/property access reports unsupported desktops without assuming success.
      await _desktop.getProperty(_shortcuts, 'version');
      final created = await _request(
        _shortcuts,
        'CreateSession',
        (options) => [options],
        options: {'session_handle_token': DBusString(_token())},
      );
      if (created == null) throw PlatformException(code: 'shortcut-cancelled');
      pendingSession = created['session_handle']!.asString();
      final bound = await _request(
        _shortcuts,
        'BindShortcuts',
        (options) => [
          DBusObjectPath(pendingSession!),
          DBusArray(DBusSignature('(sa{sv})'), [
            DBusStruct([
              const DBusString(_shortcutId),
              DBusDict.stringVariant({
                'description': DBusString(description),
                'preferred_trigger': DBusString(shortcut.portalTrigger),
              }),
            ]),
          ]),
          const DBusString(''),
          options,
        ],
      );
      final bindings = bound?['shortcuts']?.asArray() ?? [];
      String? label;
      var found = false;
      for (final binding in bindings) {
        final values = binding.asStruct();
        if (values[0].asString() == _shortcutId) {
          found = true;
          label = values[1]
              .asStringVariantDict()['trigger_description']
              ?.asString();
        }
      }
      if (!found) throw PlatformException(code: 'shortcut-cancelled');
      _activation ??=
          DBusRemoteObjectSignalStream(
            object: _desktop,
            interface: _shortcuts,
            name: 'Activated',
            signature: DBusSignature('osta{sv}'),
          ).listen((signal) {
            if (signal.values[0].asObjectPath().value == _session &&
                signal.values[1].asString() == _shortcutId) {
              onShortcut();
            }
          });
      final oldSession = _session;
      _session = pendingSession;
      pendingSession = null;
      if (oldSession != null) {
        await _closeObject(oldSession, 'org.freedesktop.portal.Session');
      }
      return label;
    } on DBusMethodResponseException {
      throw PlatformException(code: 'shortcut-unavailable');
    } finally {
      if (pendingSession != null) {
        await _closeObject(pendingSession, 'org.freedesktop.portal.Session');
      }
    }
  }

  Future<void> _closeObject(String path, String interface) async {
    try {
      await _object(path)
          .callMethod(interface, 'Close', [], noReplyExpected: true)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Already completed requests and closed sessions no longer have an object.
    }
  }

  Future<void> close() async {
    await setShortcut(null, '');
    for (final request in _requests.toList()) {
      await _closeObject(request, 'org.freedesktop.portal.Request');
    }
    await _client.close();
  }
}
