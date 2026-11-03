import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// DESIGN.md「旋转」: a window at least 600 on its shorter side turns freely. A
/// phone and a folded phone stay upright, and that is decided again whenever the
/// window changes, because folding changes it.
abstract final class WhisperOrientation {
  static final Set<Object> _holders = {};
  static bool? _upright;

  @visibleForTesting
  static bool keepsUpright(Size window) =>
      window.shortestSide > 0 &&
      window.shortestSide < WhisperLayout.regularWidth;

  static void sync() {
    if (_holders.isNotEmpty) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null || view.devicePixelRatio <= 0) return;
    final window = view.physicalSize / view.devicePixelRatio;
    if (window.isEmpty) return;
    final upright = keepsUpright(window);
    if (upright == _upright) return;
    _upright = upright;
    unawaited(
      SystemChrome.setPreferredOrientations(
        upright ? const [DeviceOrientation.portraitUp] : const [],
      ),
    );
  }

  /// A page that holds the device its own way, like a window being viewed.
  /// Until [release], a change of window leaves the orientation alone.
  static void hold(Object owner, List<DeviceOrientation> orientations) {
    _holders.add(owner);
    unawaited(SystemChrome.setPreferredOrientations(orientations));
  }

  /// Back to how the app is held everywhere else.
  static void release(Object owner) {
    final held = _holders.remove(owner);

    if (held) _upright = null;
    sync();
  }
}
