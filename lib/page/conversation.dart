import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/page/deviceList.dart';
import 'package:whisper/socket/svrmanager.dart';

import '../helper/file.dart';
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
  DeviceData device;
  DeviceData? self = null;
  List<MessageData> messageList = [];
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _textController = TextEditingController();
  bool isInputEmpty = true;
  double percent = 0;
  final keyPressedMap = {};

  _SendMessageScreen(this.device);

  @override
  void initState() {
    socketManager.registerEvent(this);
    _textController.addListener(() {
      setState(() {
        isInputEmpty = _textController.text.isEmpty;
      });
    });
    _loadMessages();
    super.initState();
  }

  @override
  void dispose() {
    socketManager.unregisterEvent();
    super.dispose();
  }

  void _updatePercent(double num) {
    print("percent: ${(100*num).toStringAsFixed(2)}%");
    setState(() {
      percent = num;
    });
  }

  void _loadMessages() async {
    print("current device: ${device.uid}");
    var me = await LocalSetting().instance();
    var temp = await LocalDatabase().fetchDevice(device.uid);
    var arr = await LocalDatabase().fetchMessageList(device.uid);
    arr = arr.reversed.toList();
    setState(() {
      self = me;
      device = temp!;
      messageList = arr;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 滚动到最后一条消息
      if (_scrollController.position.extentTotal > _scrollController.position.viewportDimension) {
        _scrollToBottom(isFirst: true);
      }
    });

    _scrollController.addListener(_scrollListener);
  }

  void _scrollListener() async {
    if (_scrollController.position.pixels ==
        _scrollController.position.maxScrollExtent) {
      // 用户滑动到了ListView的底部
      // 在这里执行你的操作
      print('滑倒底部了！');
    }
    if (_scrollController.position.pixels == 0) {
      // 用户滑动到了ListView的顶部
      // 在这里执行你的操作
      print('滑倒顶部了！${messageList[0].id}');
      var arr = await LocalDatabase().fetchMessageList(device.uid, beforeId: messageList[0].id, limit: 12);
      if (arr.isEmpty) {
        return;
      }
      arr = arr.reversed.toList();
      setState(() {
        messageList.insertAll(0, arr);
      });
    }
  }

  void _addMessage(MessageData message) {
    setState(() {
      messageList.add(message);
    });
  }

  void _ackMessage(MessageData message) {
    setState(() {
      messageList.add(message);
    });
  }

  void _scrollToBottom({bool isFirst=false}) async {
    if (isFirst) {
      _scrollController.jumpTo(
        _scrollController.position.maxScrollExtent,
        // duration: const Duration(milliseconds: 200),
        // curve: Curves.easeOut,
      );
    }else {
      await _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    var widget = Scaffold(
      appBar: AppBar(
        leading: CupertinoNavigationBarBackButton(
          color: Colors.grey,
          onPressed: () {
            Navigator.pop(context);
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
                  builder: (context) => ClientSettingsScreen(device: device,),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (percent > 0 && percent < 1) LinearProgressIndicator(value: percent, color: Colors.lightGreen,),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: messageList.length, // 消息数量
              itemBuilder: (BuildContext context, int index) {
                // 假设 index 为偶数是对面设备发送的消息，奇数是本机发送的消息
                var message = messageList[index];
                bool isOpponent = message.receiver == self?.uid;

                return Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  child: message.type == MessageEnum.Text
                      ? _buildTextMessage(message, isOpponent)
                      : _buildFileMessage(message, isOpponent),
                );
              },
            ),
          ),
          // Divider(height: 0.2, color: Colors.grey), // 分割线
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10.0),
            decoration: const BoxDecoration(
              color: Colors.white, // 背景颜色设置为白色
            ),
            child: Row(
              children: [
                if (self?.clipboard == true) CupertinoButton(
                  padding: const EdgeInsets.fromLTRB(0, 6, 6, 6),
                  onPressed: () async {
                    var str = await getClipboardData()??"";
                    if (str.isNotEmpty) {
                      socketManager.sendMessage(str, true);
                    }
                  },
                  child: const Icon(
                    Icons.copy, // 按钮图标
                    color: Colors.grey, // 按钮颜色
                  ),
                ),
                const SizedBox(height: 50,),
                Expanded(
                    child: RawKeyboardListener(
                      focusNode: FocusNode(),
                      onKey: (RawKeyEvent event) {
                        if(event.logicalKey == LogicalKeyboardKey.shiftLeft || event.logicalKey == LogicalKeyboardKey.shiftRight) {
                          keyPressedMap[LogicalKeyboardKey.shift.keyLabel] = event is RawKeyDownEvent;
                        }else if (event.logicalKey == LogicalKeyboardKey.enter) {
                          keyPressedMap[LogicalKeyboardKey.enter.keyLabel] = event is RawKeyDownEvent;
                          if (event is RawKeyDownEvent && keyPressedMap[LogicalKeyboardKey.shift.keyLabel] != true) {
                            socketManager.sendMessage(_textController.text, false);
                            // FocusScope.of(context).unfocus();
                            _textController.text = "";
                          }
                        }
                      },
                      child: CupertinoTextField(
                        controller: _textController,
                        cursorColor: Colors.black87,
                        autofocus: isDesktop(),
                        autocorrect: true,
                        maxLines: 4,
                        minLines: 1,
                        placeholder: 'Type your message...', // 输入框提示文字
                        onChanged: (value) {
                          if (value == "\n" && keyPressedMap[keyPressedMap[LogicalKeyboardKey.shift.keyLabel]] != true) {
                            _textController.text = "";
                          }
                        },
                      ),
                    )
                ),
                CupertinoButton(
                  padding: const EdgeInsets.fromLTRB(6, 6, 0, 6),
                  onPressed: () async {
                    if (_textController.text.isEmpty) {
                      FilePickerResult? result = await FilePicker.platform.pickFiles();
                      if (result != null) {
                        socketManager.sendFile(result.files.first.path??"");
                      }
                    }else {
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
          SizedBox(height: 6,)
        ],
      ),
    );

    if (isMobile()) {
      return widget;
    }

    return DropTarget(
      onDragDone: (detail) async {
        if (detail.files.isEmpty) {
          return;
        }
        // todo 多文件发送
        socketManager.sendFile(detail.files.first.path);
      },
      onDragEntered: (detail) {

      },
      onDragExited: (detail) {

      },
      child: widget,
    );
  }

  Widget _buildTextMessage(MessageData messageData, bool isOpponent) {
    double screenWidth = MediaQuery.of(context).size.width;
    if (isDesktop()) {
      screenWidth *= 0.618;
    }else {
      screenWidth *= 0.8;
    }
    return GestureDetector(
      child: Container(
        alignment: isOpponent ? Alignment.centerLeft : Alignment.centerRight,
        child: Column(
          crossAxisAlignment: isOpponent
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            Container(
              alignment: isOpponent ? Alignment.centerLeft : Alignment.centerRight,
              constraints: BoxConstraints(maxWidth: screenWidth), // 控制消息宽度
              child: Card(
                color: isOpponent ? Colors.grey[300] : Colors.blue,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: SelectableText(messageData.content??"", // 文本消息内容
                    style: TextStyle(
                      color: isOpponent ? Colors.black : Colors.white,
                    ),
                    contextMenuBuilder: (context, editableTextState) {
                      return AdaptiveTextSelectionToolbar(
                        anchors: editableTextState.contextMenuAnchors,
                        children: AdaptiveTextSelectionToolbar.getAdaptiveButtons(
                          context,
                          editableTextState.contextMenuButtonItems,
                        ).toList(),
                      );
                    },
                  ),
                ),
              ),
            ),
            Stack(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isOpponent) const SizedBox(width: 20,),
                    Text(
                      " ${formatTimestamp(messageData.timestamp)} ", // 发送时间
                      style: const TextStyle(color: Colors.grey),
                    ),
                    if (isOpponent) const SizedBox(width: 20,),
                  ],
                ),
                Positioned(
                    left: isOpponent? null: -12,
                    right: isOpponent?-12: null,
                    top: -14,
                    child: IconButton(
                      hoverColor: Colors.grey.withOpacity(0),
                      focusColor: Colors.grey,
                      highlightColor: Colors.transparent,
                      icon: const Icon(Icons.copy, size: 14, color: Colors.grey,),
                      onPressed: () {
                        if (messageData.content?.isNotEmpty == true){
                          copyToClipboard(messageData.content!);
                        }
                      },
                    ),
                )
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileMessage(MessageData message, bool isOpponent) {
    // double screenWidth = 0.382*MediaQuery.of(context).size.width;
    double screenWidth = 360;
    if (isMobile()) {
      screenWidth = 0.618*MediaQuery.of(context).size.width;
    }
    return Container(
      alignment: isOpponent ? Alignment.centerLeft : Alignment.centerRight,
      child: GestureDetector(
        onTap: (){
          openDir(name: message.name);
        },
        child: Column(
          crossAxisAlignment: isOpponent
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            Container(
              width: screenWidth,
              // constraints: BoxConstraints(maxWidth: screenWidth, minWidth: 200), // 控制消息宽度
              decoration: BoxDecoration(
                color: isOpponent ? Colors.grey[300] : Colors.grey[300],
                borderRadius: BorderRadius.circular(8),
              ),
              // width: 400,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.insert_drive_file,
                      color: Colors.white,
                      size: 42,
                    ),
                    const SizedBox(width: 6),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: screenWidth-80,
                          // constraints: BoxConstraints(maxWidth: screenWidth-100, minWidth: 80), // 控制消息宽度
                          child: Text(
                            message.name, // 文件名
                            overflow: TextOverflow.clip, // 溢出时的处理方式
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                            maxLines: 4,
                            softWrap: true,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          formatSize(message.size), // 文件大小
                          style: const TextStyle(color: Colors.black, fontSize: 12),
                        ),
                      ],
                    ),
                    // SizedBox(width: 30)
                    const SizedBox(width: 6),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatTimestamp(message.timestamp), // 发送时间
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(width: 12,)
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void onAuth(DeviceData? deviceData, String msg, var callback) {
    callback(true);
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
  void afterAuth(bool allow, DeviceData? device) {

  }

  @override
  void onMessage(MessageData messageData) {
    print("收到消息: ${messageData.type} content: ${messageData.content}");
    if (messageData.receiver == device.uid && messageData.acked) {
      _ackMessage(messageData);
    }else {
      _addMessage(messageData);
    }
    Future.delayed(const Duration(milliseconds: 200), () {
      _scrollToBottom();
    });
  }

  @override
  void onProgress(int size, length) {
    // TODO: implement onProgress
    _updatePercent(length/size);
  }
}

class ClientSettingsScreen extends StatefulWidget {
  final DeviceData device;
  ClientSettingsScreen({required this.device});

  @override
  _ClientSettingsScreen createState() => _ClientSettingsScreen(device);
}

class _ClientSettingsScreen extends State<ClientSettingsScreen> {
  DeviceData device;

  _ClientSettingsScreen(this.device);

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
                    elevation: 1.2, // 设置卡片的阴影
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
                            value: device.auth,
                            onChanged: (bool value) async {
                              LocalDatabase().authDevice(device.uid, value);
                              var temp = await LocalDatabase().fetchDevice(device.uid);
                              setState(() {
                                device = temp!;
                              });
                            },
                          ),
                        ),
                        _buildSettingItem(
                          '写入剪切板',
                          Icon(Icons.lock_open, color: CupertinoColors.systemGrey),
                          CupertinoSwitch(
                            value: device.clipboard,
                            onChanged: (bool value) async {
                              LocalDatabase().clipboardDevice(device.uid, value);
                              var temp = await LocalDatabase().fetchDevice(device.uid);
                              setState(() {
                                device = temp!;
                              });
                            },
                          ),
                        ),
                      ],
                    )),
                const SizedBox(height: 8,),
                Card(
                    elevation: 2.0, // 设置卡片的阴影
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12.0), // 圆角边框
                    ),
                    child: Column(
                      children: [
                        _buildSettingItem(
                          '删除连接',
                          const Icon(Icons.delete_rounded, color: CupertinoColors.destructiveRed,),
                          null,
                          onTap: () {
                            showConfirmationDialog(context, title: "删除${device.name}", description: "删除后消息会全部清理，不可恢复", confirmButtonText: "确定", cancelButtonText: "取消", onConfirm: (){
                              LocalDatabase().clearDevices([device.uid]);
                              Navigator.pop(context);
                              Navigator.pop(context);
                            });
                          }
                        ),
                      ],
                    ))
              ],
            ),
          ),
        ));
  }

  Widget _buildSettingItem(String title, Icon icon, Widget? trailing,
      {bool showDivider = true, onTap}) {
    return GestureDetector(
      onTap: () {
        // 处理点击设置项
        onTap();
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
                  if (trailing != null) trailing,
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
