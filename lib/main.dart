import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/page/conversation.dart';
import 'package:whisper/page/deviceList.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'helper/helper.dart';

void main() async {
  if (!isMobile()) {
    WidgetsFlutterBinding.ensureInitialized();
    // 必须加上这一行。
    await windowManager.ensureInitialized();
    var width = await LocalSetting().windowWidth();
    var height = await LocalSetting().windowHeight();

    WindowOptions windowOptions = WindowOptions(
      size: Size(width, height),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });

  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: DeviceListScreen(),
      builder: EasyLoading.init(),
    );
  }
}