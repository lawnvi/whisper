import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// The redesigned UI's window: no system title bar, and a system material where
/// the platform has one. See DESIGN.md「平台」and flutter.md「隐藏标题栏和云母」.
abstract final class WhisperWindow {
  static const _channel = MethodChannel('com.vireen.whisper/window_theme');

  /// DESIGN.md「布局」: below this the toolbar and window buttons would not fit.
  static const minimumSize = Size(720, 480);

  /// How much of the window's height a sheet leaves clear, half above and half
  /// below: the window's buttons and the island stay on top of everything, so a
  /// sheet that reached them would be covered by them.
  static double get sheetGap {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      return 40;
    }
    return Platform.isLinux && buttonLayout.value.right.isNotEmpty ? 104 : 96;
  }

  /// Whether the system paints the sidebar. False means draw `sidebarSolid`.
  static final ValueNotifier<bool> hasMaterial = ValueNotifier(false);

  /// Which window buttons go where. GTK's setting on Linux, followed live;
  /// macOS has none of its own to draw.
  static final ValueNotifier<WindowButtonLayout> buttonLayout = ValueNotifier(
    Platform.isMacOS ? const WindowButtonLayout() : WindowButtonLayout.windows,
  );

  static WindowButtonStyle get buttonStyle => Platform.isWindows
      ? WindowButtonStyle.windows
      : ((Platform.environment['XDG_CURRENT_DESKTOP'] ?? '')
                .toUpperCase()
                .contains('KDE')
            ? WindowButtonStyle.kde
            : WindowButtonStyle.gnome);

  /// Linux only: reads the button layout and follows it. Needs the runner's
  /// channel, which it only registers with WHISPER_NEW_UI=1 in the environment.
  static Future<void> followDecorationLayout() async {
    if (!Platform.isLinux) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'decorationLayoutChanged') {
        buttonLayout.value = WindowButtonLayout.parse(call.arguments as String);
      }
    });
    try {
      final layout = await _channel.invokeMethod<String>('getDecorationLayout');
      if (layout != null) {
        buttonLayout.value = WindowButtonLayout.parse(layout);
      }
    } on MissingPluginException {
      // Started without WHISPER_NEW_UI=1: buttons on the right.
    }
  }

  static WindowOptions options(Size size) => WindowOptions(
    size: size,
    minimumSize: minimumSize,
    center: true,
    // On Windows it would set an accent over the window that hides the mica.
    backgroundColor: Platform.isWindows ? null : Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: Platform.isMacOS,
  );

  /// Call after window_manager has applied [options]: on Windows it resets what
  /// this sets. Linux has no material to ask for.
  static Future<void> enableMaterial(Brightness brightness) async {
    if (Platform.isLinux) await followDecorationLayout();
    if (!Platform.isMacOS && !Platform.isWindows) return;
    // The material goes by the window's own brightness, not by the theme.
    await applyBrightness(brightness);
    try {
      final enabled = await _channel.invokeMethod<bool>(
        'enableWindowMaterial',
        {'brightness': brightness.name},
      );
      hasMaterial.value = enabled == true;
    } on PlatformException {
      hasMaterial.value = false;
    } on MissingPluginException {
      hasMaterial.value = false;
    }
  }

  /// Appearance only: no window color of its own, the material stays visible.
  static Future<void> applyBrightness(Brightness brightness) async {
    try {
      if (Platform.isWindows) {
        await _channel.invokeMethod<void>('setBrightness', {
          'brightness': brightness.name,
        });
      } else {
        await windowManager.setBrightness(brightness);
      }
    } on PlatformException {
      // The window keeps its appearance; nothing else depends on it.
    } on MissingPluginException {
      // Same.
    }
  }
}

/// With the system title bar hidden, Windows leaves no frame above the content,
/// so nothing there resizes the window: the top edge has to ask for it itself.
class WindowTopResizeEdge extends StatelessWidget {
  const WindowTopResizeEdge({super.key});

  static const double thickness = 4, corner = 8;

  Widget _zone(MouseCursor cursor, ResizeEdge edge) => MouseRegion(
    cursor: cursor,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => unawaited(windowManager.startResizing(edge)),
    ),
  );

  @override
  Widget build(BuildContext context) => SizedBox(
    height: thickness,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: corner,
          child: _zone(
            SystemMouseCursors.resizeUpLeftDownRight,
            ResizeEdge.topLeft,
          ),
        ),
        Expanded(child: _zone(SystemMouseCursors.resizeUpDown, ResizeEdge.top)),
        SizedBox(
          width: corner,
          child: _zone(
            SystemMouseCursors.resizeUpRightDownLeft,
            ResizeEdge.topRight,
          ),
        ),
      ],
    ),
  );
}
