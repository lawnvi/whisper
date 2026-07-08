import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mobile app locks orientation to portrait only', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final mobileOrientationBlock = RegExp(
      r'if\s*\(\s*isMobile\(\)\s*\)\s*\{[\s\S]*?SystemChrome\.setPreferredOrientations\([\s\S]*?\);\s*\}',
    ).firstMatch(mainSource)?.group(0);

    expect(mobileOrientationBlock, isNotNull);
    expect(mobileOrientationBlock, contains('DeviceOrientation.portraitUp'));
    expect(mobileOrientationBlock,
        isNot(contains('DeviceOrientation.portraitDown')));
    expect(mobileOrientationBlock,
        isNot(contains('DeviceOrientation.landscapeLeft')));
    expect(mobileOrientationBlock,
        isNot(contains('DeviceOrientation.landscapeRight')));
  });

  test('native mobile runners declare portrait only orientation', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final mainActivity = RegExp(
      r'<activity[\s\S]*?android:name="\.MainActivity"[\s\S]*?>',
    ).firstMatch(manifest)!.group(0)!;

    expect(mainActivity, contains('android:screenOrientation="portrait"'));

    final iosPlist = File('ios/Runner/Info.plist').readAsStringSync();
    final phoneOrientations =
        _plistArrayFor(iosPlist, 'UISupportedInterfaceOrientations');
    final ipadOrientations =
        _plistArrayFor(iosPlist, 'UISupportedInterfaceOrientations~ipad');

    for (final orientations in [phoneOrientations, ipadOrientations]) {
      expect(orientations, contains('UIInterfaceOrientationPortrait'));
      expect(orientations,
          isNot(contains('UIInterfaceOrientationPortraitUpsideDown')));
      expect(
          orientations, isNot(contains('UIInterfaceOrientationLandscapeLeft')));
      expect(orientations,
          isNot(contains('UIInterfaceOrientationLandscapeRight')));
    }
  });
}

String _plistArrayFor(String source, String key) {
  return RegExp(
    '<key>$key</key>\\s*<array>([\\s\\S]*?)</array>',
  ).firstMatch(source)!.group(1)!;
}
