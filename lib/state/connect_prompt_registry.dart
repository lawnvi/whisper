import 'package:flutter/foundation.dart';

typedef ConnectPromptCallback = void Function(bool allow);

class ConnectPromptRegistry {
  final Map<String, _ConnectPromptEntry> _entries =
      <String, _ConnectPromptEntry>{};

  bool register(String peerId, ConnectPromptCallback callback) {
    final key = _key(peerId);
    final existing = _entries[key];
    if (existing != null) {
      existing.callback = callback;
      return false;
    }
    _entries[key] = _ConnectPromptEntry(callback: callback);
    return true;
  }

  ConnectPromptCallback? latestCallbackFor(String peerId) {
    return _entries[_key(peerId)]?.callback;
  }

  void bindCloser(String peerId, VoidCallback close) {
    final entry = _entries[_key(peerId)];
    if (entry != null) {
      entry.close = close;
    }
  }

  void resolveAndClose(String peerId) {
    final entry = _entries.remove(_key(peerId));
    entry?.close?.call();
  }

  void removeFor(String peerId) {
    _entries.remove(_key(peerId));
  }

  String _key(String peerId) => peerId.trim();
}

class _ConnectPromptEntry {
  _ConnectPromptEntry({required this.callback});

  ConnectPromptCallback callback;
  VoidCallback? close;
}
