import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only Android forces orientation from Dart', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final mobileOrientationBlock = RegExp(
      r'if\s*\(\s*Platform\.isAndroid\s*\)\s*\{[\s\S]*?SystemChrome\.setPreferredOrientations\([\s\S]*?\);\s*\}',
    ).firstMatch(mainSource)?.group(0);

    expect(mobileOrientationBlock, isNotNull);
    expect(mobileOrientationBlock, contains('DeviceOrientation.portraitUp'));
    expect(
      mobileOrientationBlock,
      isNot(contains('DeviceOrientation.portraitDown')),
    );
    expect(
      mobileOrientationBlock,
      isNot(contains('DeviceOrientation.landscapeLeft')),
    );
    expect(
      mobileOrientationBlock,
      isNot(contains('DeviceOrientation.landscapeRight')),
    );
  });

  test('an iPhone stays upright except in a streamed window', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    // The plist lets an iPhone turn (a window being viewed may), and the
    // app keeps itself upright everywhere else.
    final iosBlock = RegExp(
      r'if\s*\(\s*Platform\.isIOS\s*\)\s*\{[\s\S]*?shortestSide < 600[\s\S]*?SystemChrome\.setPreferredOrientations\(\[DeviceOrientation\.portraitUp\]\)',
    ).firstMatch(mainSource);
    expect(iosBlock, isNotNull);
  });

  test(
    'phones keep portrait while iPad supports rotation and multitasking',
    () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final mainActivity = RegExp(
        r'<activity[\s\S]*?android:name="\.MainActivity"[\s\S]*?>',
      ).firstMatch(manifest)!.group(0)!;

      expect(mainActivity, contains('android:screenOrientation="portrait"'));

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
