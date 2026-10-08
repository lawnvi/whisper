import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class AppTypography {
  static const windowsFontFamily = 'Noto Sans SC';
  static const windowsFontAsset = 'assets/fonts/NotoSansSC-Compact.ttf';
  static const windowsFontLicense = 'assets/fonts/OFL.txt';

  static Future<void> initialize() async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;

    // This asset is bundled only on Windows. Load before the first frame,
    // including secondary playback windows, to avoid a visible font swap.
    final loader = FontLoader(windowsFontFamily)
      ..addFont(rootBundle.load(windowsFontAsset));
    await loader.load();
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks(const <String>[
        windowsFontFamily,
      ], await rootBundle.loadString(windowsFontLicense));
    });
  }
}
