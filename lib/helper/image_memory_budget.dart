import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

Future<void> applyImageMemoryBudget({bool background = false}) async {
  final cache = PaintingBinding.instance.imageCache;
  cache.maximumSizeBytes = (background ? 4 : 24) * 1024 * 1024;
  if (background) {
    // Release idle entries; live images still belong to their widgets.
    cache.clear();
  }
  if (defaultTargetPlatform != TargetPlatform.macOS) {
    return;
  }
  try {
    // macOS Skia otherwise scales its GPU cache budget with window pixels.
    await SystemChannels.skia.invokeMethod<void>(
      'Skia.setResourceCacheMaxBytes',
      (background ? 8 : 32) * 1024 * 1024,
    );
  } on MissingPluginException {
    // Other rendering backends may not expose the Skia cache.
  } on PlatformException {
    // A cache hint must not prevent startup or restoring the window.
  }
}

/// Skia keeps what it drew with until its budget is full, and with nothing being
/// drawn nothing ever evicts it: an animation's window-sized layers stay for as
/// long as the window sits there. So after a few seconds without a frame the
/// budget closes, and the next frame opens it again.
class GpuCacheTrimmer {
  GpuCacheTrimmer({required this.setBudget});

  static const activeBytes = 32 * 1024 * 1024;
  static const idleBytes = 4 * 1024 * 1024;
  static const idleAfter = Duration(seconds: 3);

  /// Tells the engine. It frees whatever is over at once.
  final void Function(int bytes) setBudget;
  Timer? _timer;
  bool _trimmed = false;

  /// Frames were drawn.
  void onFrames() {
    if (_trimmed) {
      _trimmed = false;
      setBudget(activeBytes);
    }
    _timer?.cancel();
    _timer = Timer(idleAfter, () {
      _trimmed = true;
      setBudget(idleBytes);
    });
  }

  void dispose() => _timer?.cancel();

  static GpuCacheTrimmer? _shared;

  /// macOS only, for the same reason as [applyImageMemoryBudget].
  static void start() {
    if (defaultTargetPlatform != TargetPlatform.macOS || _shared != null) {
      return;
    }
    final trimmer = _shared = GpuCacheTrimmer(
      setBudget: (bytes) => unawaited(
        SystemChannels.skia
            .invokeMethod<void>('Skia.setResourceCacheMaxBytes', bytes)
            .catchError((Object _) {}),
      ),
    );
    SchedulerBinding.instance.addTimingsCallback((_) => trimmer.onFrames());
    trimmer.onFrames();
  }
}
