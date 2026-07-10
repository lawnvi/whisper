import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dart helper reads desktop clipboard images through a method channel',
      () {
    final source =
        File('lib/helper/desktop_clipboard_image.dart').readAsStringSync();

    expect(source, contains('DesktopClipboardImageReader'));
    expect(source, contains('DesktopClipboardFileReader'));
    expect(source, contains('com.vireen.whisper/desktop_clipboard_image'));
    expect(source, contains('readImagePng'));
    expect(source, contains('readFilePaths'));
    expect(source, contains('MissingPluginException'));
    expect(source, contains('Directory.systemTemp'));
    expect(source, contains('Screenshot'));
  });

  test('conversation owns one typed clipboard draft and manual preview path',
      () {
    final conversation = File('lib/page/conversation.dart').readAsStringSync();
    final composer = File('lib/widget/chat_composer.dart').readAsStringSync();

    expect(conversation,
        contains('PendingClipboardDraft? _pendingClipboardDraft'));
    expect(conversation,
        contains('pendingClipboardDraft: _pendingClipboardDraft'));
    expect(conversation, contains('onPreviewClipboard: _previewClipboard'));
    expect(
      conversation,
      contains('onSendClipboardDraft: _sendPendingClipboardDraft'),
    );
    expect(
      conversation,
      contains('onClearClipboardDraft: _clearPendingClipboardDraft'),
    );
    expect(conversation, contains('onPasteClipboard: _pasteClipboard'));
    expect(conversation, isNot(contains('onPasteClipboardFiles:')));
    expect(conversation, isNot(contains('onPasteClipboardImage:')));
    expect(
      conversation,
      contains('final ChatComposerSendGate _composerSendGate'),
    );
    expect(conversation, contains('onSendText: _sendComposerText'));
    expect(conversation, contains('_composerSendGate.run('));
    expect(composer, isNot(contains('isMobile()')));
    final pasteStart =
        conversation.indexOf('Future<String?> _pasteClipboard()');
    final pasteEnd = conversation.indexOf(
      'void _clearPendingClipboardDraft()',
      pasteStart,
    );
    final pasteSource = conversation.substring(pasteStart, pasteEnd);
    expect(pasteSource, isNot(contains('|| _isLocalhost')));
    expect(pasteSource, contains('readFiles: _isLocalhost'));
    expect(pasteSource, contains('readImage: _isLocalhost'));
    expect(conversation, isNot(contains('onSendClipboard:')));
    expect(composer, contains('detectPendingClipboardDraft'));
    expect(composer, contains('PendingClipboardTextDraft'));
    expect(composer, contains('PendingClipboardImageDraft'));
    expect(composer, contains('PendingClipboardFilesDraft'));
    expect(conversation, contains('sendFileTo(device.uid, draft.path)'));
  });

  test('conversation consumes text drafts only after a successful send', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final start = source.indexOf(
      'Future<bool> _sendPendingClipboardDraftOnce()',
    );
    final end = source.indexOf(
      'Future<bool> _sendPendingClipboardFiles(',
      start,
    );

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final method = source.substring(start, end);
    final send = method.indexOf(
      'final sent = await _sendText(pending.text, isClipboard: true);',
    );
    final failure = method.indexOf('if (!sent)');
    final consume = method.indexOf('_pendingClipboardDraft = null');
    expect(send, greaterThanOrEqualTo(0));
    expect(failure, greaterThan(send));
    expect(consume, greaterThan(failure));
    expect(method.substring(failure, consume), contains('return false;'));
  });

  test('text sends await persistence and report remote send failures', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final start = source.indexOf('Future<bool> _sendText(');
    final end = source.indexOf('// 获取设备横向宽度', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final method = source.substring(start, end);
    expect(method, contains('insertMessageReturning(message)'));
    expect(method, contains('onMessage(persisted)'));
    expect(method, contains('await socketManager.sendMessageTo('));
    expect(method, contains('return sent;'));
    expect(method, contains('return false;'));
    expect(method, contains('catch (error, stackTrace)'));
    expect(method, contains('l10n.messageSendFailed'));
  });

  test('watcher and tray clipboard sends stay outside composer drafts', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(source, contains('final text = await readClipboardTextForSync();'));
    expect(
        source, contains('socketManager.sendMessage(text, clipboard: true)'));
    expect(source, contains('socketManager.sendMessage("", clipboard: true)'));
    expect(source, isNot(contains('PendingClipboardDraft')));
  });

  test('macOS runner exposes NSPasteboard images as PNG bytes', () {
    final source =
        File('macos/Runner/MainFlutterWindow.swift').readAsStringSync();

    expect(source, contains('DesktopClipboardImagePlugin.register'));
    expect(source, contains('com.vireen.whisper/desktop_clipboard_image'));
    expect(source, contains('NSPasteboard.general'));
    expect(source, contains('readImagePng'));
    expect(source, contains('readFilePaths'));
    expect(source, contains('urlReadingFileURLsOnly'));
    expect(source, contains('NSBitmapImageRep'));
    expect(source, contains('FlutterStandardTypedData'));
  });

  test('Windows runner exposes PNG and DIB clipboard images', () {
    final plugin = File('windows/runner/desktop_clipboard_image_plugin.cpp')
        .readAsStringSync();
    final header = File('windows/runner/desktop_clipboard_image_plugin.h')
        .readAsStringSync();
    final window = File('windows/runner/flutter_window.cpp').readAsStringSync();
    final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();

    expect(
        header, contains('DesktopClipboardImagePluginRegisterWithRegistrar'));
    expect(
        window, contains('DesktopClipboardImagePluginRegisterWithRegistrar'));
    expect(cmake, contains('desktop_clipboard_image_plugin.cpp'));
    expect(cmake, contains('windowscodecs.lib'));
    expect(plugin, contains('com.vireen.whisper/desktop_clipboard_image'));
    expect(plugin, contains('readImagePng'));
    expect(plugin, contains('readFilePaths'));
    expect(plugin, contains('CF_HDROP'));
    expect(plugin, contains('DragQueryFileW'));
    expect(plugin, contains('CF_DIBV5'));
    expect(plugin, contains('CF_DIB'));
    expect(plugin, contains('IWICImagingFactory'));
  });

  test('Linux runner exposes GTK clipboard images as PNG bytes', () {
    final plugin =
        File('linux/desktop_clipboard_image_plugin.cc').readAsStringSync();
    final header =
        File('linux/desktop_clipboard_image_plugin.h').readAsStringSync();
    final app = File('linux/my_application.cc').readAsStringSync();
    final cmake = File('linux/CMakeLists.txt').readAsStringSync();

    expect(header, contains('desktop_clipboard_image_plugin_register'));
    expect(app, contains('desktop_clipboard_image_plugin_register'));
    expect(cmake, contains('desktop_clipboard_image_plugin.cc'));
    expect(plugin, contains('com.vireen.whisper/desktop_clipboard_image'));
    expect(plugin, contains('readImagePng'));
    expect(plugin, contains('readFilePaths'));
    expect(plugin, contains('gtk_clipboard_wait_for_uris'));
    expect(plugin, contains('g_filename_from_uri'));
    expect(plugin, contains('gtk_clipboard_wait_for_image'));
    expect(plugin, contains('gdk_pixbuf_save_to_buffer'));
  });
}
