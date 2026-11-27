import 'dart:async';

import 'package:flutter/services.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';

/// Reads the system's count of clipboard changes: `NSPasteboard.changeCount`
/// on macOS, `GetClipboardSequenceNumber` on Windows, and on Linux the
/// changes made by other programs. Null where there is none (phones).
typedef ClipboardChangeTokenReader = Future<int?> Function();

Future<int?> readClipboardChangeToken() async {
  try {
    return await const MethodChannel(
      DesktopClipboardImageReader.channelName,
    ).invokeMethod<int>('changeToken');
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// What clipboard sync has already dealt with, so that nothing goes out
/// twice and nothing comes back.
///
/// Two rules, in this order:
/// - On desktops every change has a token. Each token is dealt with once, and
///   the tokens of Whisper's own writes (what another device sent, a paste's
///   files, what a paste put back) are never sent. Nothing here depends on
///   timing: a write is recognised however late its notice comes.
/// - The text last synced, sent or received, is not sent again. Phones have
///   no tokens and rely on this alone; on desktops it also catches programs
///   that write one copy several times.
final class ClipboardLedger {
  ClipboardLedger({ClipboardChangeTokenReader? readToken})
    : _readToken = readToken ?? readClipboardChangeToken;

  static final ClipboardLedger shared = ClipboardLedger();

  final ClipboardChangeTokenReader _readToken;
  final Set<int> _ownTokens = <int>{};
  int? _handledToken;
  String? _syncedText;

  /// The text last sent to or received from another device.
  String? get syncedText => _syncedText;

  /// Starts from what is on the clipboard now, which is not sent.
  Future<void> start({String? currentText}) async {
    _handledToken = await _readToken();
    _syncedText = currentText;
  }

  /// Runs [write], a change Whisper makes to the clipboard itself, and
  /// remembers it as such.
  Future<T> ownWrite<T>(Future<T> Function() write) async {
    try {
      return await write();
    } finally {
      final token = await _readToken();
      if (token != null) {
        _ownTokens.add(token);
        while (_ownTokens.length > 32) {
          _ownTokens.remove(_ownTokens.first);
        }
      }
    }
  }

  /// Reads the token of the clipboard as it is now. Returns null when this
  /// change has been dealt with or is Whisper's own; otherwise marks it dealt
  /// with and returns the token (0 where there are no tokens).
  Future<int?> takeChange() async {
    final token = await _readToken();
    if (token == null) return 0;
    if (token == _handledToken) return null;
    _handledToken = token;
    if (_ownTokens.remove(token)) return null;
    return token;
  }

  /// [text] went out to, or came in from, another device.
  void noteSynced(String text) {
    _syncedText = text;
  }

  /// Something other than text is on the clipboard now: the same text copied
  /// again later goes out again.
  void noteNotText() {
    _syncedText = null;
  }
}
