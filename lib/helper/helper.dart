import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

Future<String> localUUID() async {
  final SharedPreferences sp = await SharedPreferences.getInstance();
  var uuid = sp.getString("_uuid")?? "";
  if (uuid.isEmpty) {
    uuid = const Uuid().v4();
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

Future<String> getLocalIpAddress() async {
  Completer<String> completer = Completer<String>();

  try {
    for (var interface in await NetworkInterface.list()) {
      for (var addr in interface.addresses) {
        if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
          completer.complete(addr.address);
          return completer.future;
        }
      }
    }
    completer.completeError('No local IP address found');
  } catch (e) {
    completer.completeError('Error getting local IP address: $e');
  }

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
    print('Error getting clipboard data: $error');
    return null;
  });
}

void copyToClipboard(String content) {
  Clipboard.setData(ClipboardData(text: content))
      .then((value) => print('Text copied to clipboard: $content'))
      .catchError((error) => print('Error copying to clipboard: $error'));
}

void pickFile(var callback) async {
  var p = await FilePicker.platform.getDirectoryPath();
  print("current path: $p");
  // 打开文件选择器
  FilePickerResult? result = await FilePicker.platform.pickFiles();

  if (result != null) {
    PlatformFile file = result.files.first;
    print('选择的文件路径: ${file.path}');
    print('选择的文件名: ${file.name}');
    print('选择的文件大小: ${file.size}');
    callback(file.path);
  } else {
    // 用户取消了文件选择
    print('用户取消了文件选择');
  }
}