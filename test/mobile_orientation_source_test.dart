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
      expect(
        phoneOrientations,
        isNot(contains('UIInterfaceOrientationLandscape')),
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
