import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:whisper/page/deviceList.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: DeviceListScreen(),
      builder: EasyLoading.init(),
    );
  }
}