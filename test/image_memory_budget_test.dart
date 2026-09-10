import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/image_memory_budget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'restores macOS cache budgets after the window becomes visible',
    () async {
      final cache = PaintingBinding.instance.imageCache;
      final originalLimit = cache.maximumSizeBytes;
      final gpuLimits = <int>[];
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.skia, (call) async {
        expect(call.method, 'Skia.setResourceCacheMaxBytes');
        gpuLimits.add(call.arguments as int);
        return null;
      });
      addTearDown(() {
        cache.maximumSizeBytes = originalLimit;
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(SystemChannels.skia, null);
      });
      await applyImageMemoryBudget();
      expect(cache.maximumSizeBytes, 24 * 1024 * 1024);
      await applyImageMemoryBudget(background: true);
      expect(cache.maximumSizeBytes, 4 * 1024 * 1024);
      await applyImageMemoryBudget();
      expect(cache.maximumSizeBytes, 24 * 1024 * 1024);
      expect(gpuLimits, [32, 8, 32].map((mb) => mb * 1024 * 1024));
    },
  );
}
