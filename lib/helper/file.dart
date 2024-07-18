import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:open_dir/open_dir.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:whisper/helper/local.dart';

import 'helper.dart';


void openFile(String path) async {
  if (path.endsWith(".apk") && Platform.isAndroid) {
    if (await Permission.requestInstallPackages.isDenied) {
      await Permission.requestInstallPackages.request();
    }
  }
  OpenFilex.open(path);
}

void openDir(String path, {parent=false}) async {

  var file = File(path);
  if (!file.existsSync()) {
    var dir = await downloadDir();
    path = dir.path;
  }else if (parent) {
    path = file.parent.path;
  }

  logger.i("打开文件: $path");
  if (Platform.isMacOS) {
    openFinder(path);
  }else if (Platform.isAndroid) {
    // openFolderInFileManager();
    // openFileExplorer(path);
    await openAndroidDir(path);
  }else if (Platform.isIOS) {
    // openFileExplorer(path);
    await openIosDir(path);
  } else if (Platform.isWindows || Platform.isLinux) {
    final openDirPlugin = OpenDir();
    await openDirPlugin.openNativeDir(path: path);
  }
}

void openFinder(String path) async {
  // 使用系统命令打开 Finder 并显示特定文件夹
  ProcessResult result = await Process.run('open', [path]);

  // 处理执行结果
  if (result.exitCode == 0) {
    logger.i('Finder opened successfully');
  } else {
    logger.i('Error opening Finder: ${result.stderr}');
  }
}

Future<String> fileMD5(File file, [int? start, int? end]) async {
  var value = await md5.bind(file.openRead(start, end)).first;
  return value.toString();
}

Future<Directory> downloadDir() async {

  var path = await LocalSetting().savePath();

  if (path.isNotEmpty && Directory(path).existsSync()) {
    return Directory(path);
  }

  Directory? dir;
  if (Platform.isIOS || Platform.isMacOS) {
    return await getApplicationDocumentsDirectory();
  }else if (Platform.isAndroid) {
    dir = Directory("/sdcard/Download/whisper");
  }else {
    dir = await getDownloadsDirectory();
    if (dir == null) {
      return await getApplicationDocumentsDirectory();
    }
    dir = Directory("${dir.path}/whisper");
  }
  if (!dir.existsSync()) {
    dir.createSync();
  }
  return dir;
}

Future<bool> openAndroidDir(String path) async {
  // Native channel
  // 创建一个我们自定义的channel。
  const platform = MethodChannel("com.vireen.whisper/android_dir");

  bool result = false;
  try {
    // 用channel发送调用消息到原生端，调用方法是：testAction1
    await platform.invokeMethod('openFolder', {'path': path});
  } on PlatformException catch (e) {
    logger.i(e.toString());
  }
  return result;
}

Future<String> openIosDir(String path) async {
  // Native channel
  // 创建一个我们自定义的channel。
  const platform = MethodChannel("com.vireen.whisper/ios_dir");

  String result = "";
  try {
    // 用channel发送调用消息到原生端，调用方法是：testAction1
    await platform.invokeMethod('openFolder', {'path': path});
  } on PlatformException catch (e) {
    logger.i(e.toString());
  }
  logger.i(result);
  return result;
}
