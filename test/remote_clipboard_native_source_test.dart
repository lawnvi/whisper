import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clipboard frames are encoded before entering the socket layer', () {
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(
      manager,
      contains(
        '_peerConnections.sendToAwaitedIfCurrent(binding, frame.encode())',
      ),
    );
  });

  test('on-demand file paste requires automatic clipboard sync', () {
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    final publishMethod = manager.substring(
      manager.indexOf('Future<bool> publishRemoteClipboard('),
      manager.indexOf(
        'Future<RemoteClipboardPasteResult> prepareRemoteClipboardPaste(',
      ),
    );
    final prepareMethod = manager.substring(
      manager.indexOf(
        'Future<RemoteClipboardPasteResult> prepareRemoteClipboardPaste(',
      ),
      manager.indexOf('Future<void> clearRemoteClipboardSession('),
    );
    final publishItemsMethod = deviceList.substring(
      deviceList.indexOf('Future<void> _publishRemoteClipboardItems('),
      deviceList.indexOf('class DeviceDetailsScreen'),
    );

    expect(publishMethod, contains('clipboardAutoSync'));
    expect(prepareMethod, contains('clipboardAutoSync'));
    expect(
      deviceList,
      contains(
        'final clipboardAutoSyncEnabled = await LocalSetting().clipboardAutoSync()',
      ),
    );
    expect(
      deviceList,
      contains('remoteClipboardTargets.isNotEmpty && clipboardAutoSyncEnabled'),
    );
    expect(publishItemsMethod, isNot(contains('clipboardAutoSync')));
  });

  test('macOS controller intercepts and replays local paste on demand', () {
    final mac = File('macos/Runner/MainFlutterWindow.swift').readAsStringSync();
    final platform = File(
      'lib/remote_input/remote_input_platform.dart',
    ).readAsStringSync();

    expect(mac, contains('onLocalPasteShortcut'));
    expect(mac, contains('"appActive": NSApp.isActive'));
    expect(mac, contains('postLocalPasteShortcut'));
    expect(mac, contains('remoteInputLocalPasteEventMarker'));
    expect(platform, contains('configureLocalPasteHandler'));
  });

  test(
    'desktop plugins can place received temp files on the system clipboard',
    () {
      final mac = File(
        'macos/Runner/MainFlutterWindow.swift',
      ).readAsStringSync();
      final windows = File(
        'windows/runner/desktop_clipboard_image_plugin.cpp',
      ).readAsStringSync();
      final linux = File(
        'linux/desktop_clipboard_image_plugin.cc',
      ).readAsStringSync();

      expect(mac, contains('case "writeFilePaths"'));
      expect(mac, contains('pasteboard.writeObjects'));
      expect(windows, contains('SetClipboardData(CF_HDROP'));
      expect(windows, contains('call.method_name() == "writeFilePaths"'));
      expect(linux, contains('gtk_clipboard_set_with_data'));
      expect(linux, contains('gtk_selection_data_set_uris'));
      expect(linux, contains('std::strcmp(method, "writeFilePaths")'));
    },
  );
}
