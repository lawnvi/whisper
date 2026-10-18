import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../adb/adb_host_client.dart';

/// Phone facts read once per connection through `adb shell`.
class AndroidDeviceProps {
  const AndroidDeviceProps({
    required this.sdk,
    required this.release,
    required this.manufacturer,
    required this.model,
    required this.marketName,
    required this.deviceName,
    required this.stableId,
    required this.homePackages,
  });

  final int sdk;
  final String release;
  final String manufacturer;
  final String model;
  final String marketName;

  /// The name the user gave the phone (Settings › About), if any.
  final String deviceName;

  /// Hash of the hardware serial: stable across USB and wireless, and never
  /// the raw serial itself.
  final String stableId;
  final Set<String> homePackages;

  String get displayName => deviceName.isNotEmpty
      ? deviceName
      : (marketName.isNotEmpty ? marketName : model);

  bool get isXiaomi {
    final maker = manufacturer.toLowerCase();
    return maker == 'xiaomi' || maker == 'redmi' || maker == 'poco';
  }

  static const _knownLaunchers = {
    'com.miui.home',
    'com.android.launcher3',
    'com.google.android.apps.nexuslauncher',
    'com.sec.android.app.launcher',
    'com.huawei.android.launcher',
    'com.oppo.launcher',
    'com.bbk.launcher2',
  };

  static Future<AndroidDeviceProps> read(
    AdbHostClient adb,
    String serial, {
    String fallbackModel = '',
  }) async {
    const keys = [
      'ro.build.version.sdk',
      'ro.build.version.release',
      'ro.product.manufacturer',
      'ro.product.model',
      'ro.product.marketname',
      'ro.serialno',
    ];
    final command = [
      for (final key in keys) 'echo "\$(getprop $key)"',
      'cmd package resolve-activity --brief -a android.intent.action.MAIN '
          '-c android.intent.category.HOME 2>/dev/null | tail -1',
      'echo "\$(settings get global device_name 2>/dev/null)"',
    ].join('; ');
    final result = await adb.shell(serial, command);
    return parse(result.stdout, serial: serial, fallbackModel: fallbackModel);
  }

  static AndroidDeviceProps parse(
    String output, {
    required String serial,
    String fallbackModel = '',
  }) {
    final lines = const LineSplitter()
        .convert(output)
        .map((line) => line.trim())
        .toList();
    String at(int index) => index < lines.length ? lines[index] : '';
    final home = at(6);
    final serialNumber = at(5).isNotEmpty ? at(5) : serial;
    return AndroidDeviceProps(
      sdk: int.tryParse(at(0)) ?? 0,
      release: at(1),
      manufacturer: at(2),
      model: at(3).isNotEmpty ? at(3) : fallbackModel,
      marketName: at(4),
      deviceName: at(7) == 'null' ? '' : at(7),
      stableId:
          'android-${sha256.convert(utf8.encode(serialNumber)).toString().substring(0, 16)}',
      homePackages: {
        ..._knownLaunchers,
        if (home.contains('/')) home.substring(0, home.indexOf('/')),
      },
    );
  }
}
