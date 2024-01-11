import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:open_dir/open_dir.dart';
import 'package:path_provider/path_provider.dart';

void openDir({String name=""}) async {
  var dir = await downloadDir();
  var path = dir.path;

  print("打开文件: $path/$name");
  if (Platform.isMacOS) {
    openFinder(path);
  }else if (Platform.isAndroid) {
    // openFolderInFileManager();
    // openFileExplorer(path);
    await openAndroidDir(path);
  }else if (Platform.isIOS) {
    // openFileExplorer(path);
    await openIosDir("$path/$name");
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
    print('Finder opened successfully');
  } else {
    print('Error opening Finder: ${result.stderr}');
  }
}

Future<String> fileMD5(File file) async {
  var md5 = sha1.convert(await file.readAsBytes());
  return md5.toString();
}

Future<Directory> downloadDir() async {
  if (Platform.isIOS || Platform.isMacOS) {
    return getApplicationDocumentsDirectory();
  }else if (Platform.isAndroid) {
    return Directory("/sdcard/Download");
  }

  return await getDownloadsDirectory()?? await getApplicationDocumentsDirectory();
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
    print(e.toString());
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
    print(e.toString());
  }
  print(result);
  return result;
}
