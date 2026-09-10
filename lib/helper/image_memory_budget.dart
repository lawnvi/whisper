import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
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
