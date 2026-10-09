import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final plist = XmlDocument.parse(
    File('ios/Runner/Info.plist').readAsStringSync(),
  );

  test('iOS build targets agree and still support iPadOS 17', () {
    final podfile = File('ios/Podfile').readAsStringSync();
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final platform = RegExp(
      r"^platform :ios, '(\d+)\.(\d+)'",
      multiLine: true,
    ).firstMatch(podfile)!;
    final minimum = int.parse(platform.group(1)!);
    expect(minimum, inInclusiveRange(15, 17));
    final podTarget = RegExp(
      r"\['IPHONEOS_DEPLOYMENT_TARGET'\] = '(\d+)\.(\d+)'",
    ).firstMatch(podfile)!;
    expect(podTarget.group(1), platform.group(1));
    final appTargets = RegExp(
      r'IPHONEOS_DEPLOYMENT_TARGET = (\d+)\.(\d+);',
    ).allMatches(project);
    expect(appTargets, isNotEmpty);
    for (final target in appTargets) {
      expect(target.group(1), platform.group(1));
    }
  });

  test('iOS scene startup registers plugins after the engine is ready', () {
    expect(source, contains('FlutterImplicitEngineDelegate'));
    expect(source, contains('didInitializeImplicitFlutterEngine'));
    expect(source, contains('engineBridge.pluginRegistry'));
    expect(source, contains('engineBridge.applicationRegistrar.messenger()'));
    expect(source, isNot(contains('window?.rootViewController')));

    final manifest = plist
        .findAllElements('key')
        .singleWhere((key) => key.innerText == 'UIApplicationSceneManifest')
        .nextElementSibling!;
    expect(manifest.name.local, 'dict');
    expect(
      manifest.findAllElements('string').map((value) => value.innerText),
      containsAll(['FlutterSceneDelegate', 'UIWindowScene', 'Main']),
    );
    final multipleScenes = manifest
        .findAllElements('key')
        .singleWhere(
          (key) => key.innerText == 'UIApplicationSupportsMultipleScenes',
        )
        .nextElementSibling!;
    expect(multipleScenes.name.local, 'false');
  });

  test('first-install system prompts wait for the iOS app to render', () {
    final notifications = File(
      'lib/helper/notification.dart',
    ).readAsStringSync();
    final devices = File('lib/page/deviceList.dart').readAsStringSync();
    expect(notifications, contains('requestAlertPermission: false'));
    expect(notifications, contains('requestBadgePermission: false'));
    expect(notifications, contains('requestSoundPermission: false'));
    final permissions = RegExp(
      r'Future<void> _requestLocalNetworkPermission\([\s\S]*?\n  \}',
    ).firstMatch(devices)!.group(0)!;
    expect(
      permissions.indexOf('waitUntilFirstFrameRasterized'),
      lessThan(permissions.indexOf('ensureGranted()')),
    );
    expect(
      permissions,
      contains('NotificationHelper().requestIOSPermissions()'),
    );
  });
}
