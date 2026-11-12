import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/model/LocalDatabase.dart';

/// Names given to other devices on this one, to tell apart several with
/// the same or an unhelpful name ("DESKTOP-1T2E3R7"). Kept here only: the
/// other device and everyone else still see its own name, and its profile
/// keeps overwriting the stored name, so a given one lives apart from it.
class PeerAliases extends ChangeNotifier {
  PeerAliases({SharedPreferences? preferences}) : _preferences = preferences;

  static final PeerAliases shared = PeerAliases();

  static const _key = 'peer_aliases.v1';

  /// As long as a device's own name may be.
  static const maxRunes = 64;

  SharedPreferences? _preferences;
  final _aliases = <String, String>{};
  Future<void>? _loading;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    DeviceData.labelOf = labelOf;
    try {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      final raw = preferences.getString(_key);
      if (raw != null) {
        final map = jsonDecode(raw);
        if (map is Map) {
          for (final MapEntry(:key, :value) in map.entries) {
            if (key is String && value is String && value.isNotEmpty) {
              _aliases[key] = value;
            }
          }
        }
      }
    } catch (_) {
      // Nothing kept: devices go by their own names.
    }
    notifyListeners();
  }

  /// The name given to [peerId] here, or null.
  String? aliasOf(String peerId) => _aliases[peerId];

  /// What to call [peerId], whose own name is [name].
  String labelOf(String peerId, String name) => _aliases[peerId] ?? name;

  /// Calls [peerId] [alias] from now on; empty goes back to its own name.
  Future<void> rename(String peerId, String alias) async {
    final trimmed = alias.trim();
    if (peerId.isEmpty || (_aliases[peerId] ?? '') == trimmed) return;
    if (trimmed.isEmpty) {
      _aliases.remove(peerId);
    } else {
      _aliases[peerId] = trimmed;
    }
    notifyListeners();
    await _save();
  }

  /// A removed device leaves nothing behind.
  Future<void> forget(String peerId) async {
    if (_aliases.remove(peerId) == null) return;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      await preferences.setString(_key, jsonEncode(_aliases));
    } catch (_) {
      // Known for this run.
    }
  }
}
