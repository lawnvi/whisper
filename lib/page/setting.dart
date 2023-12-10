import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class SettingsScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        iconTheme: IconThemeData(
          color: Colors.red, // 设置返回按钮图标的颜色
        ),
        title: Text('Settings'),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          ListTile(
            title: Text('开启监听'),
            trailing: CupertinoSwitch(
              value: true,
              onChanged: (bool value) {
                // 处理开关状态变化
              },
            ),
          ),
          ListTile(
            title: Text('设置访问密码'),
            trailing: IconButton(
              icon: Icon(Icons.visibility),
              onPressed: () {
                // 处理点击显示密码
              },
            ),
            onTap: () {
              // 处理点击设置密码
            },
          ),
          ListTile(
            title: Text('允许读取剪切板'),
            trailing: CupertinoSwitch(
              value: true,
              onChanged: (bool value) {
                // 处理开关状态变化
              },
            ),
          ),
          ListTile(
            title: Text('允许写入剪切板'),
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
