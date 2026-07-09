import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum LocalNetworkPermissionStatus {
  granted,
  denied,
  restricted,
  unknown,
}

/// Cross-platform boundary for LAN access permission state.
///
/// iOS deliberately starts as [LocalNetworkPermissionStatus.unknown]: Apple
/// exposes no general preflight API, so discovery owns policy-error inference.
final class LocalNetworkPermission {
  LocalNetworkPermission({
    MethodChannel? channel,
    TargetPlatform? targetPlatform,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _targetPlatform = targetPlatform ?? defaultTargetPlatform;

  static const String channelName =
      'com.vireen.whisper/local_network_permission';

  final MethodChannel _channel;
  final TargetPlatform _targetPlatform;

  Future<LocalNetworkPermissionStatus> ensureGranted({
    bool android16CompatTest = false,
  }) {
    return _status(
      method: 'ensureGranted',
      android16CompatTest: android16CompatTest,
    );
  }

  Future<LocalNetworkPermissionStatus> currentStatus({
    bool android16CompatTest = false,
  }) {
    return _status(
      method: 'currentStatus',
      android16CompatTest: android16CompatTest,
    );
  }

  Future<LocalNetworkPermissionStatus> _status({
    required String method,
    required bool android16CompatTest,
  }) async {
    if (_targetPlatform == TargetPlatform.iOS) {
      return LocalNetworkPermissionStatus.unknown;
    }
    if (_targetPlatform != TargetPlatform.android) {
      return LocalNetworkPermissionStatus.granted;
    }

    try {
      final status = await _channel.invokeMethod<String>(
        method,
        <String, Object?>{
          'android16CompatTest': android16CompatTest,
        },
      );
      return _parseStatus(status);
    } on PlatformException catch (error) {
      return switch (error.code) {
        'denied' => LocalNetworkPermissionStatus.denied,
        'restricted' => LocalNetworkPermissionStatus.restricted,
        _ => LocalNetworkPermissionStatus.unknown,
      };
    } on MissingPluginException {
      return LocalNetworkPermissionStatus.unknown;
    }
  }
}

LocalNetworkPermissionStatus _parseStatus(String? status) => switch (status) {
      'granted' => LocalNetworkPermissionStatus.granted,
      'denied' => LocalNetworkPermissionStatus.denied,
      'restricted' => LocalNetworkPermissionStatus.restricted,
      _ => LocalNetworkPermissionStatus.unknown,
    };
