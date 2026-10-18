import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'agent_link.dart';

/// Reads, from the phone's own Whisper, how to reach the persistent
/// whisper-agent on this device (loopback port + link token the agent
/// pushed through the window-stream provider), and hears about new links.
/// The channel is served by `WindowStreamAgentPlugin` on Android.
abstract final class PhoneAgentLink {
  static const _channel = MethodChannel(
    'com.vireen.whisper/window_stream_agent',
  );

  static final _changes = StreamController<AgentLinkInfo?>.broadcast();
  static bool _listening = false;

  /// Fires whenever the agent pushes a fresh link while Whisper runs.
  static Stream<AgentLinkInfo?> get changes {
    _ensureHandler();
    return _changes.stream;
  }

  static void _ensureHandler() {
    if (_listening || !Platform.isAndroid) {
      return;
    }
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'linked') {
        _changes.add(_parse(call.arguments));
      }
      return null;
    });
  }

  /// The current link, or null when the agent has not reported one.
  static Future<AgentLinkInfo?> current() async {
    if (!Platform.isAndroid) {
      return null;
    }
    _ensureHandler();
    try {
      return _parse(await _channel.invokeMethod<Object?>('link'));
    } on PlatformException {
      return null;
    }
  }

  /// Forgets the stored link (e.g. the service was turned off).
  static Future<void> clear() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('clearLink');
    } on PlatformException {
      // Nothing stored.
    }
  }

  static AgentLinkInfo? _parse(Object? value) {
    if (value is! Map) {
      return null;
    }
    final token = value['token'];
    return AgentLinkInfo.fromMap({
      ...value.cast<Object?, Object?>().map((key, v) => MapEntry('$key', v)),
      if (token is Uint8List) 'token': token,
    });
  }
}
