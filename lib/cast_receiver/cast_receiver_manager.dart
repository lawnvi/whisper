import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:whisper/helper/helper.dart'
    show localNetworkInterfaceDescriptions, selectLocalIpv4Address;
import 'package:whisper/helper/local.dart';
import 'package:whisper/state/ipv4_address_policy.dart';

import 'dlna_backend.dart';
import 'receiver_backend.dart';

export 'receiver_backend.dart';

/// DLNA reception is independent of Whisper pairing and peer sessions.
class CastReceiverManager extends ChangeNotifier {
  CastReceiverManager({
    ReceiverBackend? backend,
    Future<CastReceiverEndpoint?> Function()? endpointResolver,
    Future<bool> Function()? loadEnabled,
    Future<void> Function(bool)? saveEnabled,
  }) : _backend = backend ?? DlnaBackend(),
       _endpointResolver = endpointResolver ?? _desktopEndpoint,
       _loadEnabled = loadEnabled ?? LocalSetting().castReceiverEnabled,
       _saveEnabled = saveEnabled ?? LocalSetting().setCastReceiverEnabled {
    _backend.onChanged = notifyListeners;
  }

  static final shared = CastReceiverManager();
  final ReceiverBackend _backend;
  final Future<CastReceiverEndpoint?> Function() _endpointResolver;
  final Future<bool> Function() _loadEnabled;
  final Future<void> Function(bool) _saveEnabled;
  Future<void> _pending = Future<void>.value();
  bool _initialized = false;
  bool _enabled = false;
  int _operations = 0;

  bool get enabled => _enabled;
  bool get busy => _operations > 0;
  CastReceiverStatus get status => _backend.status;

  Future<void> updateName() async =>
      _backend.updateName(await LocalSetting().castReceiverName());

  Future<void> initialize() => _enqueue(() async {
    if (_initialized) return;
    _initialized = true;
    _enabled = await _loadEnabled();
    if (_enabled) await _start();
  });

  Future<void> setEnabled(bool value) => _enqueue(() async {
    // Persist before applying so a failed preference write cannot leave a
    // receiver running which the user expected to remain disabled.
    await _saveEnabled(value);
    _initialized = true;
    _enabled = value;
    if (value) {
      await _start();
    } else {
      await _backend.stop();
    }
  });

  /// App shutdown releases resources without clearing the saved preference.
  Future<void> stop() => _enqueue(() async {
    _enabled = false;
    await _backend.stop();
  });

  Future<void> _enqueue(Future<void> Function() operation) {
    ++_operations;
    notifyListeners();
    final result = _pending.then((_) async {
      try {
        await operation();
      } on Object {
        _backend.update(
          CastReceiverState.failed,
          issue: CastReceiverIssue.startupFailed,
        );
      } finally {
        --_operations;
        notifyListeners();
      }
    });
    _pending = result;
    return result;
  }

  Future<void> _start() async {
    if (status.state == CastReceiverState.running) return;
    CastReceiverEndpoint? endpoint;
    try {
      endpoint = await _endpointResolver();
    } on Object {
      // The backend reports a missing LAN address in the setting subtitle.
    }
    try {
      await _backend.start(endpoint);
    } on Object {
      try {
        await _backend.stop();
      } finally {
        _backend.update(
          CastReceiverState.failed,
          issue: CastReceiverIssue.startupFailed,
        );
      }
    }
  }

  @override
  void dispose() {
    _backend.onChanged = null;
    super.dispose();
  }

  static Future<CastReceiverEndpoint?> _desktopEndpoint() async {
    final descriptions = await localNetworkInterfaceDescriptions();
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final endpoints = [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (Ipv4AddressPolicy.isPrivate(address.address))
            (address, interface),
    ];
    final preferred = selectLocalIpv4Address(
      endpoints.map(
        (endpoint) => (
          address: endpoint.$1.address,
          interfaceName:
              '${endpoint.$2.name} ${descriptions[endpoint.$2.index] ?? ''}',
        ),
      ),
    );
    for (final endpoint in endpoints) {
      if (endpoint.$1.address == preferred) return endpoint;
    }
    return null;
  }
}
