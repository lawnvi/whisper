import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

var logger = Logger();
const LocalUuid = Uuid();

bool isDesktop() {
  return Platform.isMacOS || Platform.isLinux || Platform.isWindows;
}

bool isMobile() {
  return Platform.isAndroid || Platform.isIOS;
}

Future<String> localUUID() async {
  final SharedPreferences sp = await SharedPreferences.getInstance();
  var uuid = sp.getString("_uuid")?? "";
  if (uuid.isEmpty) {
    uuid = LocalUuid.v4();
    sp.setString("_uuid", uuid);
  }
  return uuid;
}

String formatSize(int size) {
  var tb = size / (1024*1024*1024*1024);
  if (tb > 10) {
    return "${tb.toStringAsFixed(1)} TB";
  }
  if (tb >= 0.9) {
    return "${tb.toStringAsFixed(2)} TB";
  }
  var gb = size / (1024*1024*1024);
  if (gb > 10) {
    return "${gb.toStringAsFixed(1)} GB";
  }
  if (gb >= 0.9) {
    return "${gb.toStringAsFixed(2)} GB";
  }
  var mb = size / (1024*1024);
  if (mb > 10) {
    return "${mb.toStringAsFixed(1)} MB";
  }
  if (mb >= 0.9) {
    return "${mb.toStringAsFixed(2)} MB";
  }
  var kb = size / 1024;
  if (kb > 1) {
    return "${kb.toStringAsFixed(2)} KB";
  }
  return "$size B";
}

String formatTimestamp(int timestamp) {
  DateTime dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  // 使用 DateFormat 格式化时间
  return DateFormat('yyyy/MM/dd HH:mm:ss').format(dateTime);
}

IconData platformIcon(platform) {
  return platform.toLowerCase() == "android"? Icons.android_rounded:
  platform.toLowerCase() == "macos"? Icons.laptop_mac_rounded:
  platform.toLowerCase() == "ios"? Icons.apple_rounded:
  platform.toLowerCase() == "windows"? Icons.laptop_windows_rounded: Icons.laptop_rounded;
}

Future<String> deviceName() async {
  final dp = DeviceInfoPlugin();
  try {
    if (kIsWeb) {
      var data = await dp.webBrowserInfo;
      return data.browserName.name;
    } else {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          var android = await dp.androidInfo;
          if (android.model.contains(android.brand)) {
            return android.model;
          }
          return "${android.brand} ${android.model}";
        case TargetPlatform.iOS:
            var ios = await dp.iosInfo;
            return ios.name;
        case TargetPlatform.linux:
            var linux = await dp.linuxInfo;
            return linux.name;
        case TargetPlatform.windows:
            var windows = await dp.windowsInfo;
            return windows.computerName;
        case TargetPlatform.macOS:
            var mac = await dp.macOsInfo;
            return mac.computerName;
        case TargetPlatform.fuchsia:
          return "unknown";
      }
    }
  } on PlatformException {
    return "unknown";
  }
}

Future<bool> isLocalhost(String address) async {
  try {
    for (var interface in await NetworkInterface.list()) {
      for (var addr in interface.addresses) {
        if (!addr.isLoopback && addr.type == InternetAddressType.IPv4 && addr.address == address) {
          return true;
        }
      }
    }
  } catch (e) {
    logger.i("is local err: $e");
  }

  return false;
}

Future<String> getLocalIpAddress() async {
  // var sb = StringBuffer();
  Completer<String> completer = Completer<String>();

  try {
    for (var interface in await NetworkInterface.list()) {
      for (var addr in interface.addresses) {
        if (!addr.isLoopback && addr.type == InternetAddressType.IPv4 && addr.address.startsWith("192.168")) {
          completer.complete(addr.address);
          // if (sb.isNotEmpty) {
          //   sb.write("/");
          // }
          // sb.write(addr.address);
          return completer.future;
        }
      }
    }
  } catch (e) {
    completer.completeError('Error getting local IP address: $e');
  }
  completer.complete("127.0.0.1");

  return completer.future;
}

Future<String?> getClipboardData() async {
  return await Clipboard.getData(Clipboard.kTextPlain).then((value) {
    if (value != null && value.text != null) {
      return value.text;
    } else {
      return null;
    }
  }).catchError((error) {
    logger.i('Error getting clipboard data: $error');
    return null;
  });
}

void copyToClipboard(String content) {
  Clipboard.setData(ClipboardData(text: content))
      .then((value) => {})
      .catchError((error) => {});
}

void pickFile(var callback) async {
  var p = await FilePicker.platform.getDirectoryPath();
  logger.i("current path: $p");
  // 打开文件选择器
  FilePickerResult? result = await FilePicker.platform.pickFiles();

  if (result != null) {
    PlatformFile file = result.files.first;
    logger.i('选择的文件路径: ${file.path}');
    logger.i('选择的文件名: ${file.name}');
    logger.i('选择的文件大小: ${file.size}');
    callback(file.path);
  } else {
    // 用户取消了文件选择
    logger.i('用户取消了文件选择');
  }
}

String pkg2name(String? pkg) {
  if (pkg == null) {
    return "通知";
  }
  return pkgMaps[pkg]?? "通知";
}

var pkgMaps = {'com.tencent.mm': '微信', 'com.tencent.mobileqq': 'QQ', 'com.eg.android.AlipayGphone': '支付宝', 'com.taobao.taobao': '淘宝', 'com.jingdong.app.mall': '京东', 'com.ss.android.ugc.aweme': '抖音', 'com.smile.gifmaker': '快手', 'com.sina.weibo': '微博', 'tv.danmaku.bili': '哔哩哔哩', 'com.netease.cloudmusic': '网易云音乐', 'com.tencent.qqlive': '腾讯视频', 'com.youku.phone': '优酷', 'com.qiyi.video': '爱奇艺', 'com.sankuai.meituan': '美团', 'com.sdu.didi.psnger': '滴滴出行', 'com.ss.android.lark': '飞书', 'com.android.mms': '短信', 'com.coolapk.market': '酷安', 'com.sankuai.meituan.takeoutnew': '美团外卖', 'com.taobao.idlefish': '闲鱼'};