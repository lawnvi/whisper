import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/peer_profile.dart';

/// Phones and tablets share a platform name (`android`, `ios`), so each
/// says which it is ([PeerProfile.formFactor]); this keeps what others said
/// so a tablet keeps its picture while it is away.
class DeviceFormFactors extends ChangeNotifier {
  DeviceFormFactors({SharedPreferences? preferences})
    : _preferences = preferences;

  static final DeviceFormFactors shared = DeviceFormFactors();

  static const _key = 'device_form_factors.v1';

  SharedPreferences? _preferences;
  final _known = <String, String>{};
  String _local = '';
  Future<void>? _loading;

  /// This device: [DeviceFormFactor.tablet] or [DeviceFormFactor.phone];
  /// empty on a computer.
  String get local => _local;

  bool get localIsTablet => _local == DeviceFormFactor.tablet;

  bool isTablet(String peerId) => _known[peerId] == DeviceFormFactor.tablet;

  /// Reads what was kept and what this device is (once).
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    _local = await detectLocalFormFactor();
    try {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      final raw = preferences.getString(_key);
      if (raw != null) {
        final map = jsonDecode(raw);
        if (map is Map) {
          for (final entry in map.entries) {
            if (entry.key is String && _valid(entry.value)) {
              _known[entry.key as String] = entry.value as String;
            }
          }
        }
      }
    } catch (_) {
      // Nothing kept: devices show as phones until they say otherwise.
    }
    notifyListeners();
  }

  /// [peerId] said what it is (its profile).
  Future<void> record(String peerId, String formFactor) async {
    if (peerId.isEmpty || !_valid(formFactor) || _known[peerId] == formFactor) {
      return;
    }
    _known[peerId] = formFactor;
    notifyListeners();
    try {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      await preferences.setString(_key, jsonEncode(_known));
    } catch (_) {
      // Known for this run.
    }
  }

  static bool _valid(Object? value) =>
      value == DeviceFormFactor.phone || value == DeviceFormFactor.tablet;
}

/// What this device is: an iPad by its model, an Android device by its
/// screen (600 dp across or more, Android's own line for tablets).
Future<String> detectLocalFormFactor() async {
  if (kIsWeb) {
    return '';
  }
  if (Platform.isIOS) {
    try {
      final info = await DeviceInfoPlugin().iosInfo;
      return info.model.toLowerCase().contains('ipad')
          ? DeviceFormFactor.tablet
          : DeviceFormFactor.phone;
    } catch (_) {
      return DeviceFormFactor.phone;
    }
  }
  if (Platform.isAndroid) {
    final display = PlatformDispatcher.instance.implicitView?.display;
    if (display == null || display.devicePixelRatio <= 0) {
      return DeviceFormFactor.phone;
    }
    return formFactorForScreen(display.size / display.devicePixelRatio);
  }
  return '';
}

/// A screen at least 600 dp on its shorter side is a tablet's.
@visibleForTesting
String formFactorForScreen(Size logical) => logical.shortestSide >= 600
    ? DeviceFormFactor.tablet
    : DeviceFormFactor.phone;
