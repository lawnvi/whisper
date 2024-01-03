import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';

class SettingsScreen extends StatefulWidget {
  @override
  _SettingsScreen createState() => _SettingsScreen();
}

class _SettingsScreen extends State<SettingsScreen> {
  late DeviceData device;

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  Future<void> _initializeData() async {
    // 数据加载完成后更新状态
    var temp = await LocalSetting().instance();
    setState(() {
      device = temp;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        iconTheme: const IconThemeData(
          color: Colors.red, // 设置返回按钮图标的颜色
        ),
        title: const Text('设置'),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          ListTile(
            title: const Text('作为服务端'),
            trailing: CupertinoSwitch(
              value: device.isServer,
              onChanged: (bool value) {
                // 处理开关状态变化
              },
            ),
          ),
          ListTile(
            title: const Text('访问密码'),
            trailing: IconButton(
              icon: const Icon(Icons.visibility),
              onPressed: () {
                // 处理点击显示密码
              },
            ),
            onTap: () {
              // 处理点击设置密码
            },
          ),
          ListTile(
            title: const Text('允许读取剪切板'),
            trailing: CupertinoSwitch(
              value: true,
              onChanged: (bool value) {
                // 处理开关状态变化
              },
            ),
          ),
          ListTile(
            title: const Text('允许写入剪切板'),
            trailing: CupertinoSwitch(
              value: true,
              onChanged: (bool value) {
                // 处理开关状态变化
              },
            ),
          ),
        ],
      ),
    );
  }
}
