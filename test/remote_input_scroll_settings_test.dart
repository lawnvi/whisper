import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/helper/local.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('remote input scroll multiplier settings', () {
    test('settings exposes remote input scroll speed configuration', () {
      final settings = File('lib/page/settings.dart').readAsStringSync();

      expect(settings, contains('_remoteInputScrollMultiplier'));
      expect(settings, contains('remoteInputScrollMultiplierSetting('));
      expect(settings, contains('_showRemoteInputScrollMultiplierSheet'));
      expect(settings, contains('showWhisperGlassBottomSheet<void>('));
      expect(settings, contains('WhisperGlassBottomSheet('));
      expect(settings, contains('WhisperSettingsSlider('));
      expect(settings, contains('setRemoteInputScrollMultiplier'));
      expect(
        settings,
        contains('RemoteInputCoordinator.shared.updateScrollMultiplier'),
      );
    });

    test('defaults to native speed and clamps saved values', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      expect(await LocalSetting().remoteInputScrollMultiplier(), 1.0);

      await LocalSetting().setRemoteInputScrollMultiplier(0.1);
      expect(await LocalSetting().remoteInputScrollMultiplier(), 0.5);

      await LocalSetting().setRemoteInputScrollMultiplier(4.5);
      expect(await LocalSetting().remoteInputScrollMultiplier(), 3.0);
    });
  });
}
