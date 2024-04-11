import 'dart:io';

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
  final key = GlobalKey<AnimatedListState>();

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
    var arr = await LocalDatabase().fetchMessageList(device.uid, limit: 20);
    setState(() {
      self = me;
      device = temp!;
      // messageList = arr;
    });

    _insertItems(0, arr);

    _scrollController.addListener(_scrollListener);
  }

  void _scrollListener() async {
    if (_scrollController.position.pixels ==
        _scrollController.position.maxScrollExtent) {
      // 用户滑动到了ListView的底部
      // 在这里执行你的操作
      print('滑倒顶部了！${messageList[0].id}');
      var arr = await LocalDatabase().fetchMessageList(device.uid, beforeId: messageList.last.id, limit: 12);
      if (arr.isEmpty) {
        return;
      }

      _insertItems(messageList.length, arr);
    }
    if (_scrollController.position.pixels == 0) {
      // 用户滑动到了ListView的顶部
      // 在这里执行你的操作
      print('滑倒底部了！');
    }
  }

  _insertItem(index, item) {
    messageList.insert(index, item);
    key.currentState?.insertItem(index, duration: Duration(milliseconds: 500));
  }

  _insertItems(index, items) {
    messageList.insertAll(index, items);
    key.currentState?.insertAllItems(index, items.length, duration: Duration(milliseconds: 500));
  }

  _deleteItem(id) {
    var index = -1;
    for (var i = 0; i < messageList.length; i++) {
      if (messageList[i].id == id) {
        index = i;
        break;
      }
    }
    if (index == -1) {
      return;
    }

    setState(() {
      // 删除过程执行的是反向动画，animation.value 会从1变为0
      key.currentState?.removeItem(index, (context, animation) {
        //注意先 build 然后再去删除
        messageList.removeAt(index);
        return FadeTransition(
          opacity: animation,
          child: null,
        );
      }, duration: const Duration(milliseconds: 500));
    }); //解决快速删除bug 重置flag

    LocalDatabase().deleteMessage(id);
  }

  @Deprecated("use list view reverse")
  void _scrollToBottom({bool isFirst=false}) async {
    if (isFirst) {
      _scrollController.jumpTo(
        _scrollController.position.maxScrollExtent,
        // duration: const Duration(milliseconds: 200),
        // curve: Curves.easeOut,
      );
    }else {
      await _scrollController.animateTo(
        0,
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
                Row(
                  children: [
                    Text(
                      "${device.host}:${device.port}", // 设备 IP 地址
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(width: 4),
                    if(socketManager.receiver == device.uid) Icon(Icons.wifi_rounded, size: socketManager.started ? 14 : 0, color: Colors.lightBlue)
                  ],
                )
              ],
            ),
          ],
        ),
        // automaticallyImplyLeading: true, // 隐藏返回按钮
        actions: [
          CupertinoButton(
            // 使用CupertinoButton
            padding: EdgeInsets.zero,
            child: const Icon(
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
          if (percent > 0 && percent < 1)
            LinearProgressIndicator(
              value: percent,
              color: Colors.lightGreen,
            ),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: AnimatedList(
                key: key,
                controller: _scrollController,
                initialItemCount: messageList.length, // 消息数量
                reverse: true,
                shrinkWrap: true,
                itemBuilder: (context, index, animation) {
                  var message = messageList[index];
                  bool isOpponent = message.receiver == self?.uid;

                  return FadeTransition(opacity: animation, child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                    child: Column(
                      crossAxisAlignment: isOpponent
                          ? CrossAxisAlignment.start
                          : CrossAxisAlignment.end,
                      children: [
                        GestureDetector(
                          child: Container(
                            alignment: isOpponent ? Alignment.centerLeft : Alignment.centerRight,
                            child: message.type == MessageEnum.Text
                                ? _buildTextMessage(message, isOpponent)
                                : _buildFileMessage(message, isOpponent),
                          ),
                          onTap: (){
                            if (message.type == MessageEnum.File) {
                              openDir(name: message.name);
                            }
                          },
                          onDoubleTap: () async {
                            if (await LocalSetting().isDoubleClickDelete()) {
                              _deleteItem(message.id);
                            }
                          },
                          onLongPress: () {
                            showConfirmationDialog(
                              context,
                              title: "删除消息",
                              description: "确定删除此消息吗？",
                              confirmButtonText: "确定",
                              cancelButtonText: "取消",
                              onConfirm: () async {
                                _deleteItem(message.id);
                                if (isOpponent && message.type == MessageEnum.File) {
                                  var path = "${(await downloadDir()).path}/${message.name}";
                                  print("delete $path");
                                  File(path).delete();
                                }
                              },
                            );
                          },
                        ),
                        SizedBox(height: message.type == MessageEnum.File? 4: 2,),
                        Stack(
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(width: isOpponent? isMobile()? 10:0 : 20,),
                                Text(
                                  " ${formatTimestamp(message.timestamp)} ", // 发送时间
                                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                                ),
                                SizedBox(width: isOpponent? 20: isMobile()? 10:0,),
                              ],
                            ),
                            if (message.type == MessageEnum.Text) Positioned(
                              left: isOpponent? null: -12,
                              right: isOpponent?-12: null,
                              top: Platform.isMacOS? -12.2: -14,
                              child: IconButton(
                                hoverColor: Colors.grey.withOpacity(0),
                                focusColor: Colors.grey,
                                highlightColor: Colors.transparent,
                                icon: Icon(Icons.copy, size: (isMobile()? 16: 18), color: Colors.grey,),
                                onPressed: () {
                                  if (message.content?.isNotEmpty == true){
                                    copyToClipboard(message.content!);
                                  }
                                },
                              ),
                            )
                          ],
                        ),
                      ],
                    ),
                  ));
                },
              ),
          ),),
          // Divider(height: 0.2, color: Colors.grey), // 分割线
          if(device.uid == socketManager.receiver) Container(
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
                    if (str.trim().isNotEmpty) {
                      await socketManager.sendMessage(str.trimRight(), true);
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
                      onKey: (RawKeyEvent event) async {
                        if(event.logicalKey == LogicalKeyboardKey.shiftLeft || event.logicalKey == LogicalKeyboardKey.shiftRight) {
                          keyPressedMap[LogicalKeyboardKey.shift.keyLabel] = event is RawKeyDownEvent;
                        }else if (event.logicalKey == LogicalKeyboardKey.enter) {
                          keyPressedMap[LogicalKeyboardKey.enter.keyLabel] = event is RawKeyDownEvent;
                          if (event is RawKeyDownEvent && (keyPressedMap[LogicalKeyboardKey.shift.keyLabel] != true || isMobile())) {
                            if (_textController.text.trim().isNotEmpty) {
                              await socketManager.sendMessage(_textController.text.trimRight(), false);
                              // FocusScope.of(context).unfocus();
                              _textController.text = "";
                            }
                          }
                        }
                      },
                      child: CupertinoTextField(
                        controller: _textController,
                        cursorColor: Colors.black87,
                        autofocus: isDesktop(),
                        autocorrect: true,
                        maxLines: isMobile()? 5: 20,
                        minLines: 1,
                        placeholder: '发点什么...', // 输入框提示文字
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
                        for (var item in result.files) {
                          await socketManager.sendFile(item.path??"");
                        }
                        // await socketManager.sendFile(result.files.first.path??"");
                      }
                    }else {
                      // 发送按钮操作
                      await socketManager.sendMessage(_textController.text, false);
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
          const SizedBox(height: 6,)
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
        // socketManager.sendFile(detail.files.first.path);
        for (var item in detail.files) {
         await socketManager.sendFile(item.path);
        }
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
    return Container(
      alignment: isOpponent ? Alignment.centerLeft : Alignment.centerRight,
      constraints: BoxConstraints(maxWidth: screenWidth), // 控制消息宽度
      child: Card(
        color: isOpponent? Colors.grey[300]: messageData.acked? Colors.blue: Colors.redAccent,
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
    );
  }

  Widget _buildFileMessage(MessageData message, bool isOpponent) {
    // double screenWidth = 0.382*MediaQuery.of(context).size.width;
    double screenWidth = 300;
    if (isMobile()) {
      screenWidth = 0.618*MediaQuery.of(context).size.width;
    }
    return Container(
      width: screenWidth,
      // constraints: BoxConstraints(maxWidth: screenWidth, minWidth: 200), // 控制消息宽度
      decoration: BoxDecoration(
        color: isOpponent || message.acked? Colors.grey[200]: Colors.redAccent,
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
    );
  }

  @override
  void onAuth(DeviceData? deviceData, String msg, var callback) {
    callback(true);
  }

  @override
  void onClose() {
    // TODO: implement onClose
    percent = 0;
    setState(() {

    });
  }

  @override
  void onConnect() {
    // TODO: implement onConnect
  }

  @override
  void onError(String message) {
    // TODO: implement onError
    showConfirmationDialog(context, title: "是否释放连接", description: message, confirmButtonText: "断开", cancelButtonText: "取消", onConfirm: (){
      WsSvrManager().close();
    });
  }

  @override
  void afterAuth(bool allow, DeviceData? device) {
    if (socketManager.receiver == device?.uid) {
      setState(() {

      });
    }
  }

  @override
  void onMessage(MessageData messageData) {
    print("收到消息: ${messageData.type} content: ${messageData.content}");
    if (messageData.receiver == device.uid && messageData.acked) {
      // _ackMessage(messageData);
    }else {
      // _addMessage(messageData);
    }
    _insertItem(0, messageData);
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
                          Icon(Icons.copy, color: CupertinoColors.systemGrey),
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
                if (device.uid != WsSvrManager().receiver) Card(
                    elevation: 2.0, // 设置卡片的阴影
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12.0), // 圆角边框
                    ),
                    child: Column(
                      children: [
                        _buildSettingItem(
                          '删除设备',
                          const Icon(Icons.delete_rounded, color: CupertinoColors.destructiveRed,),
                          null,
                          onTap: () {
                            showConfirmationDialog(context, title: "删除${device.name}", description: "删除与此设备的所有消息，不可恢复", confirmButtonText: "确定", cancelButtonText: "取消", onConfirm: (){
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
