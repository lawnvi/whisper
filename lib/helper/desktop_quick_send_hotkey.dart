import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/helper/helper.dart' show getClipboardText;
import 'package:whisper/state/desktop_quick_send_inbox.dart';

class DesktopQuickSendHotKeyController {
  DesktopQuickSendHotKeyController({
    DesktopQuickSendInbox? inbox,
    DesktopClipboardFileReader? fileReader,
    DesktopClipboardImageReader? imageReader,
    Future<String?> Function()? textReader,
  }) : _inbox = inbox ?? DesktopQuickSendInbox.shared,
       _fileReader = fileReader ?? const DesktopClipboardFileReader(),
       _imageReader = imageReader ?? const DesktopClipboardImageReader(),
       _textReader = textReader ?? getClipboardText;

  final DesktopQuickSendInbox _inbox;
  final DesktopClipboardFileReader _fileReader;
  final DesktopClipboardImageReader _imageReader;
  final Future<String?> Function() _textReader;
  HotKey? _hotKey;
  bool _handling = false;

  String get shortcutLabel => Platform.isMacOS ? '⌘⌥V' : 'Ctrl+Alt+V';

  Future<bool> register({required Future<void> Function() revealWindow}) async {
    if (!(Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
      return false;
    }
    final hotKey = HotKey(
      key: PhysicalKeyboardKey.keyV,
      modifiers: Platform.isMacOS
          ? const <HotKeyModifier>[HotKeyModifier.meta, HotKeyModifier.alt]
          : const <HotKeyModifier>[HotKeyModifier.control, HotKeyModifier.alt],
      scope: HotKeyScope.system,
    );
    try {
      final previous = _hotKey;
      if (previous != null) {
        await hotKeyManager.unregister(previous);
      }
      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (_) async {
          await captureClipboard(revealWindow: revealWindow);
        },
      );
      _hotKey = hotKey;
      return true;
    } on PlatformException {
      return false;
    }
  }

  Future<DesktopQuickSendEnqueueResult> captureClipboard({
    required Future<void> Function() revealWindow,
    String? nativeEntryId,
  }) async {
    if (_handling) {
      return const DesktopQuickSendEnqueueResult.deferred();
    }
    _handling = true;
    try {
      final result = await _captureClipboardContent(
        nativeEntryId: nativeEntryId,
      );
      if (result.isAccepted) {
        await revealWindow();
      }
      return result;
    } finally {
      _handling = false;
    }
  }

  Future<DesktopQuickSendEnqueueResult> _captureClipboardContent({
    String? nativeEntryId,
  }) async {
    final files = await _fileReader.readFileDrafts(includeDirectories: true);
    if (files.isNotEmpty) {
      return _inbox.addClipboard(
        text: '',
        filePaths: files.map((draft) => draft.path),
        nativeEntryId: nativeEntryId,
      );
    }
    final image = await _imageReader.readImageDraft();
    if (image != null) {
      return _inbox.addClipboard(
        text: '',
        filePaths: <String>[image.path],
        nativeEntryId: nativeEntryId,
      );
    }
    return _inbox.addClipboard(
      text: await _textReader() ?? '',
      filePaths: const <String>[],
      nativeEntryId: nativeEntryId,
    );
  }

  Future<void> unregister() async {
    final hotKey = _hotKey;
    _hotKey = null;
    if (hotKey == null) {
      return;
    }
    try {
      await hotKeyManager.unregister(hotKey);
    } on PlatformException {
      // The process may be shutting down after the native registrar is gone.
    }
  }
}
