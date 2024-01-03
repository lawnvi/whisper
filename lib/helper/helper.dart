import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

Future<String?> _getClipboardData() async {
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

void _copyToClipboard(String content) {
  Clipboard.setData(ClipboardData(text: content))
      .then((value) => print('Text copied to clipboard: $content'))
      .catchError((error) => print('Error copying to clipboard: $error'));
}

void pickFile() async {
  // 打开文件选择器
  FilePickerResult? result = await FilePicker.platform.pickFiles();

  if (result != null) {
    PlatformFile file = result.files.first;
    print('选择的文件路径: ${file.path}');
    print('选择的文件名: ${file.name}');
    print('选择的文件大小: ${file.size}');
  } else {
    // 用户取消了文件选择
    print('用户取消了文件选择');
  }
}