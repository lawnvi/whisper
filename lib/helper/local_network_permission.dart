import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum LocalNetworkPermissionStatus {
  granted,
  denied,
  restricted,
  unavailable,
  retryable,
  unknown,
}

/// Cross-platform boundary for LAN access permission state.
///
/// Apple platforms deliberately start as
/// [LocalNetworkPermissionStatus.unknown]: Apple exposes no general preflight
/// API, so discovery owns policy-error inference.
final class LocalNetworkPermission {
  LocalNetworkPermission({
    MethodChannel? channel,
    EventChannel? eventChannel,
    TargetPlatform? targetPlatform,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _eventChannel = eventChannel ?? const EventChannel(eventChannelName),
       _targetPlatform = targetPlatform ?? defaultTargetPlatform;

  static const String channelName =
      'com.vireen.whisper/local_network_permission';
  static const String eventChannelName =
      'com.vireen.whisper/local_network_permission/events';

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  final TargetPlatform _targetPlatform;

  Stream<LocalNetworkPermissionStatus> get statusChanges {
    if (_targetPlatform != TargetPlatform.android) {
      return const Stream<LocalNetworkPermissionStatus>.empty();
    }
    return _eventChannel.receiveBroadcastStream().map(
      (event) => _parseStatus(event as String?),
    );
  }

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

  Future<String?> currentLanAddress() async {
    if (_targetPlatform != TargetPlatform.android) {
      return null;
    }
    try {
      final address = (await _channel.invokeMethod<String>(
        'currentLanAddress',
      ))?.trim();
      return address == null || address.isEmpty ? null : address;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<LocalNetworkPermissionStatus> _status({
    required String method,
    required bool android16CompatTest,
  }) async {
    if (_targetPlatform == TargetPlatform.macOS ||
        (_targetPlatform == TargetPlatform.iOS && method == 'currentStatus')) {
      return LocalNetworkPermissionStatus.unknown;
    }
    if (_targetPlatform != TargetPlatform.android &&
        _targetPlatform != TargetPlatform.iOS) {
      return LocalNetworkPermissionStatus.granted;
    }

    try {
      final status = await _channel.invokeMethod<String>(
        method,
        <String, Object?>{'android16CompatTest': android16CompatTest},
      );
      return _parseStatus(status);
    } on PlatformException catch (error) {
      return switch (error.code) {
        'denied' => LocalNetworkPermissionStatus.denied,
        'restricted' => LocalNetworkPermissionStatus.restricted,
        'unavailable' => LocalNetworkPermissionStatus.unavailable,
        'retryable' => LocalNetworkPermissionStatus.retryable,
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
  'unavailable' => LocalNetworkPermissionStatus.unavailable,
  'retryable' => LocalNetworkPermissionStatus.retryable,
  _ => LocalNetworkPermissionStatus.unknown,
};
