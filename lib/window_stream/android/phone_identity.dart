import 'dart:io';

import 'package:flutter/services.dart';

import '../../helper/local.dart';
import '../../socket/device_identity.dart';

/// Hands this phone's Whisper peer id and identity key (both public) to the
/// window-stream provider, which tells a desktop over adb who this phone is.
/// Desktops stream a phone only once the two are paired and trusted.
abstract final class PhoneStreamIdentity {
  static const _channel = MethodChannel('com.vireen.whisper/window_stream');

  static Future<void> publish() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final local = await LocalSetting().instance();
      final identity = await DeviceIdentityStore().loadOrCreate();
      await _channel.invokeMethod<void>('publishIdentity', {
        'peerId': local.uid,
        'identityKey': identity.publicKeyBase64Url,
      });
    } catch (_) {
      // Desktops then report this phone as not paired; nothing else breaks.
    }
  }
}
