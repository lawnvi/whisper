import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class SendMessageScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CupertinoNavigationBar(
        leading: GestureDetector(
          onTap: () {
            Navigator.pop(context); // 返回按钮
          },
          child: Icon(CupertinoIcons.back),
        ),
        middle: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('Device Name'), // 设备名称
            Text(
              'Device IP', // 设备 IP 地址
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        trailing: GestureDetector(
          onTap: () {
            // 设置按钮操作
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ClientSettingsScreen(),
              ),
            );
          },
          child: Icon(CupertinoIcons.settings), // 设置按钮
        ),
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: 20, // 消息数量
              itemBuilder: (BuildContext context, int index) {
                // 假设 index 为偶数是对面设备发送的消息，奇数是本机发送的消息
                bool isOpponent = index.isEven;

                // 消息类型假设为文本和文件两种
                bool isTextMessage = index % 4 == 0; // 每第 4 条消息是文本消息

                return Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: isTextMessage
                      ? _buildTextMessage(isOpponent)
                      : _buildFileMessage(isOpponent),
                );
              },
            ),
          ),
          // Divider(height: 0.2, color: Colors.grey), // 分割线
          Container(
            padding: EdgeInsets.symmetric(horizontal: 10.0),
            decoration: BoxDecoration(
              color: Colors.white, // 背景颜色设置为白色
            ),

            child: Row(
              children: [
                SizedBox(height: 50,),
                Expanded(
                  child: CupertinoTextField(
                    autofocus: true,
                    autocorrect: true,
                    maxLines: 4,
                    minLines: 1,
                    placeholder: 'Type your message...', // 输入框提示文字
                  ),
                ),
                CupertinoButton(
                  padding: EdgeInsets.all(6.0),
                  onPressed: () {
                    // 发送按钮操作
                  },
                  child: Icon(
                    Icons.send, // 发送按钮图标
                    color: Colors.lightBlue, // 发送按钮颜色
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextMessage(bool isOpponent) {
    return Container(
      alignment: isOpponent ? Alignment.centerLeft : Alignment.centerRight,
      child: Column(
        crossAxisAlignment: isOpponent
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.end,
        children: [
          Card(
            color: isOpponent ? Colors.grey[300] : Colors.blue,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                'Text message content', // 文本消息内容
                style: TextStyle(
                  color: isOpponent ? Colors.black : Colors.white,
                ),
              ),
            ),
          ),
          Text(
            '11:30 AM', // 发送时间
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildFileMessage(bool isOpponent) {
    return Container(
      alignment: isOpponent ? Alignment.centerLeft : Alignment.centerRight,
      child: Column(
        crossAxisAlignment: isOpponent
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.end,
        children: [
          Container(
            constraints: BoxConstraints(maxWidth: 400), // 控制消息宽度
            decoration: BoxDecoration(
              color: isOpponent ? Colors.grey[300] : Colors.grey[300],
              borderRadius: BorderRadius.circular(4),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.insert_drive_file,
                    color: Colors.white,
                  ),
                  SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'File Name', // 文件名
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'File Size', // 文件大小
                        style: TextStyle(color: Colors.black, fontSize: 12),
                      ),
                    ],
                  ),
                  SizedBox(width: 30)
                ],
              ),
            ),
          ),
          SizedBox(height: 4),
          Text(
            '11:30 AM', // 发送时间
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }


}

class ClientSettingsScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          leading: CupertinoNavigationBarBackButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            color: Colors.lightBlue, // 设置返回按钮图标的颜色
          ),
          title: Text('Settings'),
        ),
        body: SafeArea(
          child: Material(
            child: ListView(
              padding: EdgeInsets.all(16.0), // 添加内边距以改善外观
              children: [
                Card(
                    elevation: 2.0, // 设置卡片的阴影
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12.0), // 圆角边框
                    ),
                    child: Column(
                      children: [
                        _buildSettingItem(
                          '允许自动接入',
                          Icon(Icons.wifi_rounded, color: CupertinoColors.systemGrey,),
                          CupertinoSwitch(
                            value: true,
                            onChanged: (bool value) {},
                          ),
                        ),
                        _buildSettingItem(
                          '允许写入剪切板',
                          Icon(Icons.lock_open, color: CupertinoColors.systemGrey),
                          CupertinoSwitch(
                            value: true,
                            onChanged: (bool value) {},
                          ),
                        ),
                      ],
                    ))
              ],
            ),
          ),
        ));
  }

  Widget _buildSettingItem(String title, Icon icon, Widget trailing,
      {bool showDivider = true}) {
    return GestureDetector(
      onTap: () {
        // 处理点击设置项
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          children: [
            Container(
              height: 56.0, // 增加高度以适应 iOS 设置样式
              child: Row(
                children: [
                  icon, // 设置项的图标
                  SizedBox(width: 16.0), // 图标与文字之间的间距
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 17.0,
                        color: CupertinoColors.black,
                        fontWeight: FontWeight.w500, // 尝试更轻的字重
                        fontFamily: 'SF Pro Display', // 使用 iOS 默认字体（若有）), // 设置项的文字样式
                      ),
                      // style: TextStyle(fontSize: 17.0, color: CupertinoColors.black, fontWeight: FontWeight.bold), // 设置项的文字样式
                    ),
                  ),
                  trailing,
                ],
              ),
            ),
            if (showDivider)
              Divider(height: 1, color: Colors.white38), // 分割线
          ],
        ),
      ),
    );
  }


}
