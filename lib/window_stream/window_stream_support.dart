import 'dart:io';

import 'core/window_stream_models.dart';
import 'remote/window_stream_host.dart';

/// This device can offer its windows (desktop) or its apps (Android, through
/// whisper-agent) to other peers: a desktop whose native capture backend is
/// ready (`wsn_capture_supported()`), or an Android phone where the feature
/// exists at all — the phone advertises even when the agent is not running
/// yet, so desktops list it and show setup guidance instead of nothing. A
/// platform whose backend is missing or unusable never shows half a feature.
bool supportsWindowStreamSource() =>
    (Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux ||
        Platform.isAndroid) &&
    WindowStreamHost.shared.sharingAllowed &&
    WindowStreamHost.shared.supported;

/// This device can show another peer's windows: phones and tablets in a
/// Flutter page, desktops in native windows.
bool supportsWindowStreamSink() =>
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isMacOS ||
    Platform.isWindows ||
    Platform.isLinux;

WindowStreamPlatform windowStreamPlatformOf(String platform) {
  final value = platform.toLowerCase();
  if (value.contains('mac') || value.contains('darwin')) {
    return WindowStreamPlatform.macos;
  }
  if (value.contains('win')) {
    return WindowStreamPlatform.windows;
  }
  if (value.contains('ios') ||
      value.contains('ipad') ||
      value.contains('iphone')) {
    return WindowStreamPlatform.ios;
  }
  if (value.contains('android')) {
    return WindowStreamPlatform.android;
  }
  return WindowStreamPlatform.linux;
}
