import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/page/deviceList.dart';
import 'package:whisper/socket/svrmanager.dart';

import '../helper/helper.dart';

class SendMessageScreen extends StatefulWidget {
  final DeviceData device;
  SendMessageScreen({required this.device});

  @override
  _SendMessageScreen createState() => _SendMessageScreen(device);
}

class _SendMessageScreen extends State<SendMessageScreen> implements ISocketEvent {
  final db = LocalDatabase();
  final socketManager = WsSvrManager();
  final DeviceData device;
  late DeviceData self;
  List<MessageData> messageList = [];
  final TextEditingController _textController = TextEditingController();
  bool isInputEmpty = true;

  _SendMessageScreen(this.device);

  @override
  void initState() {
    socketManager.registerEvent(this);
    _refreshMessage(onlyMessage: false);
    _textController.addListener(() {
      setState(() {
        isInputEmpty = _textController.text.isEmpty;
      });
    });
    super.initState();
  }

  void _refreshMessage({bool onlyMessage=true}) async {
    print("current device: ${device.uid}, $onlyMessage");
    var me = await LocalSetting().instance();
    var arr = await LocalDatabase().fetchMessageList(device.uid);
    print("current device: ${device.uid} message size: ${arr.length} ----- ${arr[0].sender}");
    setState(() {
      self = me;
      messageList = arr;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: CupertinoNavigationBarBackButton(
          onPressed: () {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => DeviceListScreen(),
              ),
            ); // 返回按钮
          },
          // color: Colors.lightBlue, // 设置返回按钮图标的颜色
        ),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(device.name), // 设备名称
                Text(
                  "${device.host}:${device.port}", // 设备 IP 地址
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ],
        ),
        // automaticallyImplyLeading: true, // 隐藏返回按钮
        actions: [
          CupertinoButton(
            // 使用CupertinoButton
            padding: EdgeInsets.zero,
            child: Icon(
              Icons.settings_outlined,
              size: 30,
              color: Colors.black45,
            ),
            onPressed: () async {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ClientSettingsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: messageList.length, // 消息数量
              itemBuilder: (BuildContext context, int index) {
                // 假设 index 为偶数是对面设备发送的消息，奇数是本机发送的消息
                var message = messageList[index];
                bool isOpponent = message.sender == self.uid;

                print("sdjghk: ${message.content}");

                return Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: message.type == MessageEnum.Text
                      ? _buildTextMessage(message, isOpponent)
                      : _buildFileMessage(message, isOpponent),
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
                    controller: _textController,
                    autofocus: false,
                    autocorrect: true,
                    maxLines: 4,
                    minLines: 1,
                    placeholder: 'Type your message...', // 输入框提示文字
                  ),
                ),
                CupertinoButton(
                  padding: EdgeInsets.all(6.0),
                  onPressed: () async {
                    if (_textController.text.isEmpty) {
                      FilePickerResult? result = await FilePicker.platform.pickFiles();
                      if (result != null) {
                        socketManager.sendFile(result.files.first.path??"");
                      }
                    }else {
                      print("input: ${_textController.text}");
                      // 发送按钮操作
                      socketManager.sendMessage(_textController.text, false);
                      _textController.text = "";
                    }
                  },
                  child: Icon(
                    isInputEmpty?Icons.add:Icons.send, // 发送按钮图标
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

  void showCustomPopupMenu(BuildContext context) async {
    final RenderBox overlay = Overlay.of(context)!.context.findRenderObject() as RenderBox;
    final Offset targetPosition = Offset.zero; // 这里可以根据需要设置菜单的位置

    await showMenu(
      context: context,
      position: RelativeRect.fromLTRB(targetPosition.dx, targetPosition.dy, 0, 0),
      items: [
        PopupMenuItem(
          child: Text('Option 1'),
          value: 1,
        ),
        PopupMenuItem(
          child: Text('Option 2'),
          value: 2,
        ),
        // 添加更多菜单项...
      ],
      // 处理菜单项点击事件
      initialValue: null,
    ).then((value) {
      // 处理菜单项点击事件
      if (value == 1) {
        // 处理 Option 1 的操作
      } else if (value == 2) {
        // 处理 Option 2 的操作
      }
      // 处理更多菜单项...
    });
  }

  Widget _buildTextMessage(MessageData messageData, bool isOpponent) {
    return GestureDetector(
      onLongPress: () {
        if (messageData.content?.isNotEmpty == true){
          copyToClipboard(messageData.content!);
        };
      },
      child: Container(
        alignment: isOpponent ? Alignment.centerLeft : Alignment.centerRight,
        child: Column(
          crossAxisAlignment: isOpponent
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            Card(
              color: isOpponent ? Colors.grey[300] : Colors.blue,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Text(
                  messageData.content??"", // 文本消息内容
                  style: TextStyle(
                    color: isOpponent ? Colors.black : Colors.white,
                  ),
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 10,),
                Text(
                  '2024/01/04 11:30:26', // 发送时间
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileMessage(MessageData message, bool isOpponent) {
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
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.insert_drive_file,
                    color: Colors.white,
                    size: 42,
                  ),
                  SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'sdhgdskfhgkdfhgjkhhhb.jpg', // 文件名
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                        maxLines: 2,
                          softWrap: true,
                      ),
                      SizedBox(height: 7),
                      Text(
                        '18.2 KB', // 文件大小
                        style: TextStyle(color: Colors.black, fontSize: 12),
                      ),
                    ],
                  ),
                  // SizedBox(width: 30)
                ],
              ),
            ),
          ),
          SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '2024/01/04 11:30:26', // 发送时间
                style: TextStyle(color: Colors.grey),
              ),
              SizedBox(width: 10,)
            ],
          ),
        ],
      ),
    );
  }

  @override
  void onAuth(DeviceData? deviceData, String msg, var callback) {
    // TODO: implement onAuth
  }

  @override
  void onClose() {
    // TODO: implement onClose
  }

  @override
  void onConnect() {
    // TODO: implement onConnect
  }

  @override
  void onError() {
    // TODO: implement onError
  }

  @override
  void onMessage(MessageData messageData) {
    print("收到消息: ${messageData.type} content: ${messageData.content}");
    _refreshMessage();
  }

  @override
  void onProgress(int size, length) {
    // TODO: implement onProgress
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
                          '自动接入',
                          Icon(Icons.wifi_rounded, color: CupertinoColors.systemGrey,),
                          CupertinoSwitch(
                            value: true,
                            onChanged: (bool value) {},
                          ),
                        ),
                        _buildSettingItem(
                          '写入剪切板',
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
