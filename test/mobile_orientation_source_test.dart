import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'phones keep portrait while iPad supports rotation and multitasking',
    () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final mainActivity = RegExp(
        r'<activity[\s\S]*?android:name="\.MainActivity"[\s\S]*?>',
      ).firstMatch(manifest)!.group(0)!;

      // DESIGN.md「旋转」: the window decides, from Dart, because folding changes
      // it. A manifest cannot say that.
      expect(mainActivity, isNot(contains('android:screenOrientation')));
      expect(mainActivity, contains('smallestScreenSize'));
      expect(mainActivity, contains('screenLayout'));

      final iosPlist = File('ios/Runner/Info.plist').readAsStringSync();
      final phoneOrientations = _plistArrayFor(
        iosPlist,
        'UISupportedInterfaceOrientations',
      );
      final ipadOrientations = _plistArrayFor(
        iosPlist,
        'UISupportedInterfaceOrientations~ipad',
      );

      expect(phoneOrientations, contains('UIInterfaceOrientationPortrait'));
      expect(
        phoneOrientations,
        isNot(contains('UIInterfaceOrientationPortraitUpsideDown')),
      );
      // Landscape is allowed so a streamed window can turn; the app itself
      // locks an iPhone upright from Dart (test above).
      expect(
        phoneOrientations,
        contains('UIInterfaceOrientationLandscapeLeft'),
      );
      expect(
        ipadOrientations,
        contains('UIInterfaceOrientationPortraitUpsideDown'),
      );
      expect(ipadOrientations, contains('UIInterfaceOrientationLandscapeLeft'));
      expect(
        ipadOrientations,
        contains('UIInterfaceOrientationLandscapeRight'),
      );
      expect(
        iosPlist,
        matches(RegExp(r'<key>UIRequiresFullScreen</key>\s*<false/>')),
      );
    },
  );
}

String _plistArrayFor(String source, String key) {
  return RegExp(
    '<key>$key</key>\\s*<array>([\\s\\S]*?)</array>',
  ).firstMatch(source)!.group(1)!;
}
