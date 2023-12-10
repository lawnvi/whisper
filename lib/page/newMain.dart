import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';

class NewUI extends StatelessWidget {
  double _opacityLevel = 1.0;
  late Timer _timer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CupertinoNavigationBar(
        middle: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text('Username'), // 替换为实际昵称
                Text(
                  '192.168.1.2', // 替换为实际 IP 地址
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
            Spacer(), // 右侧留有空白区域
            CupertinoSwitch(
              value: false, // 替换为实际开关状态
              activeColor: Colors.lightBlue,
              onChanged: (bool value) {
                // 处理开关状态变化
              },
            ),
          ],
        ),
        automaticallyImplyLeading: false, // 隐藏返回按钮
      ),
      body: Padding(
        padding: EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 加载指示器部分
            Container(
              width: 200,
              height: 200,
              child: SpinKitRing(
                color: Colors.lightBlue, // 指示器颜色
                lineWidth: 2, // 环的宽度
                size: 140,
              ),
            ),
            Text('waiting...'), // 加载指示器下的文本说明
            SizedBox(height: 30),
            // 第一行显示自己的IP
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('localhost: '),
                Text('192.168.1.1', // Replace with actual IP or dynamic value
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(width: 10),
                CupertinoSwitch(
                  value: true, // Replace with actual switch value
                  activeColor: Colors.lightBlue,
                  onChanged: (value) {
                    // Handle switch state change
                  },
                ),
              ],
            ),
            // 第二行显示对方的IP和连接/断开按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('connected: '),
                Text('192.168.1.2', // Replace with actual IP or dynamic value
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                CupertinoButton(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  onPressed: () {
                    // Handle connect/disconnect button tap
                  },
                  child: true?Icon(Icons.signal_wifi_4_bar): Icon(Icons.power_settings_new), // Replace with dynamic text
                ),
                SizedBox(width: 10),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
