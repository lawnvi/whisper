import 'dart:async';
import 'dart:convert';
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

import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../helper/notification.dart';

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
  String _speed = "";
  int _sentSize = 0;
  int _lastUpdateTime = 0;
  final keyPressedMap = {};
  final key = GlobalKey<AnimatedListState>();
  bool _isLocalhost = false;

  _SendMessageScreen(this.device);

  @override
  void initState() {
    logger.i("init conv: ${socketManager.receiver}-${device.uid}");
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
    logger.i("dispose conv: ${socketManager.receiver}-${device.uid}");
    socketManager.unregisterEvent();
    super.dispose();
  }

  void _updatePercent(double num) {
    // logger.i("percent: ${(100*num).toStringAsFixed(2)}%");
    setState(() {
      percent = num;
    });
  }

  void _loadMessages() async {
    logger.i("current device: ${device.uid}");
    var me = await LocalSetting().instance();
    var isLocal = me.uid == device.uid;
    var temp = isLocal? me: await LocalDatabase().fetchDevice(device.uid);
    var arr = await LocalDatabase().fetchMessageList(me.uid == temp?.uid? "": device.uid, limit: 20);
    setState(() {
      self = me;
      device = temp!;
      _isLocalhost = isLocal;
      // messageList = arr;
    });

    _insertItems(0, arr);

    _scrollController.addListener(_scrollListener);

    // 开启通知监听
    if (Platform.isAndroid && !isLocal && temp?.uid == socketManager.receiver && temp?.syncNotification == true) {
      startAndroidListening();
    }
  }

  void _scrollListener() async {
    if (_scrollController.position.pixels ==
        _scrollController.position.maxScrollExtent) {
      // 用户滑动到了ListView的底部
      // 在这里执行你的操作
      logger.i('滑倒顶部了！${messageList[0].id}');
      var arr = await LocalDatabase().fetchMessageList(device.uid, beforeId: messageList.last.id, limit: 12);
      if (arr.isEmpty) {
        return;
      }

      _insertItems(messageList.length, arr);
    }
    if (_scrollController.position.pixels == 0) {
      // 用户滑动到了ListView的顶部
      // 在这里执行你的操作
      logger.i('滑倒底部了！');
    }
  }

  _insertItem(index, item) {
    messageList.insert(index, item);
    key.currentState?.insertItem(index, duration: const Duration(milliseconds: 500));
  }

  _insertItems(index, items) {
    messageList.insertAll(index, items);
    key.currentState?.insertAllItems(index, items.length, duration: const Duration(milliseconds: 500));
  }

  _clearItems() {
    key.currentState?.removeAllItems((context, animation) {
      //注意先 build 然后再去删除
      messageList.clear();
      return FadeTransition(
        opacity: animation,
        child: null,
      );
    }, duration: const Duration(milliseconds: 100));
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
            // Navigator.pop(context);
            Navigator.popUntil(context, (route) {
              return route.isFirst;
            });
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
                    if(socketManager.receiver == device.uid) const Icon(Icons.wifi_rounded, size: 14, color: Colors.lightBlue)
                  ],
                )
              ],
            ),
          ],
        ),
        // automaticallyImplyLeading: true, // 隐藏返回按钮
        actions: [
          if (percent > 0 && percent < 1 && device.uid == socketManager.receiver)
            Column(
              children: [
                const SizedBox(height: 12),
                Text(_speed, style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 2),
                Text(
                    "${(100 * percent).toStringAsFixed(2)}%",
                    style: const TextStyle(fontSize: 12)
                ),
              ],
            ),
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
                            child: message.type == MessageEnum.File
                                ? _buildFileMessage(message, isOpponent)
                                : _buildTextMessage(message, isOpponent),
                          ),
                          onTap: (){
                            if (isOpponent && message.type == MessageEnum.File) {
                              openDir(name: message.name, isMobile: isMobile());
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
                              title:  AppLocalizations.of(context)?.deleteMessageTitle??"删除消息",
                              description:  AppLocalizations.of(context)?.deleteMessageDesc??"确定删除此消息吗？",
                              confirmButtonText:  AppLocalizations.of(context)?.confirm??"确定",
                              cancelButtonText:  AppLocalizations.of(context)?.cancel??"取消",
                              onConfirm: () async {
                                _deleteItem(message.id);
                                if (isOpponent && message.type == MessageEnum.File) {
                                  var path = "${(await downloadDir()).path}/${message.name}";
                                  logger.i("delete $path");
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
          if(_isLocalhost || device.uid == socketManager.receiver) Container(
            padding: const EdgeInsets.symmetric(horizontal: 10.0),
            decoration: const BoxDecoration(
              color: Colors.white, // 背景颜色设置为白色
            ),
            child: Row(
              children: [
                if (self?.clipboard == true) CupertinoButton(
                  padding: const EdgeInsets.fromLTRB(0, 6, 6, 6),
                  onPressed: () {
                    _sendText("", isClipboard: true);
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
                              await _sendText(_textController.text.trimRight());
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
                        placeholder:  AppLocalizations.of(context)?.sendTips??'发点什么...', // 输入框提示文字
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
                    if (!_isLocalhost && _textController.text.isEmpty) {
                      FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);
                      if (result != null) {
                        for (var item in result.files) {
                          await socketManager.sendFile(item.path??"");
                        }
                      }
                    }else {
                      // 发送按钮操作
                      await _sendText(_textController.text);
                      _textController.text = "";
                    }
                  },
                  child: Icon(
                    !_isLocalhost && isInputEmpty?Icons.add:Icons.send, // 发送按钮图标
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
        if (detail.files.isEmpty || _isLocalhost) {
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

  Future<void> _sendText(String content, {isClipboard=false}) async {
    if (isClipboard) {
      var str = await getClipboardData()??"";
      content = str.trimRight();
    }
    if (content.trim().isEmpty) {
      return;
    }
    if (_isLocalhost) {
      var message = MessageData(id: 0, sender: device.uid, receiver: "", name: "", clipboard: isClipboard, size: 0, type: MessageEnum.Text, content: content, message: "", timestamp: DateTime.now().millisecondsSinceEpoch~/1000, acked: true, uuid: LocalUuid.v4(), path: "", md5: "");
      LocalDatabase().insertMessage(message);
      onMessage(message);
    }else if (socketManager.receiver == device.uid) {
      await socketManager.sendMessage(content, clipboard: true);
    }
  }

  Widget _buildTextMessage(MessageData messageData, bool isOpponent) {
    double screenWidth = MediaQuery.of(context).size.width;
    if (isDesktop()) {
      screenWidth *= 0.618;
    }else {
      screenWidth *= 0.8;
    }
    var content = messageData.content??"";
    if (messageData.type == MessageEnum.Notification) {
      var data = jsonDecode(messageData.content??"{}");
      content = "【${data['app']}】${data['title']}\n${data['text']}";
    }
    return Container(
      alignment: isOpponent ? Alignment.centerLeft : Alignment.centerRight,
      constraints: BoxConstraints(maxWidth: screenWidth), // 控制消息宽度
      child: Card(
        color: isOpponent ? Colors.grey[300] : Colors.blue,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: SelectableText(content, // 文本消息内容
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
    var failed = !isOpponent && !message.acked && message.timestamp < device.lastTime;
    // var isSending = !message.acked && message.timestamp >= device.lastTime;
    return Container(
      width: screenWidth,
      // constraints: BoxConstraints(maxWidth: screenWidth, minWidth: 200), // 控制消息宽度
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      // width: 400,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failed) const SizedBox(width: 8),
            failed? const Icon(
              Icons.error_outline_rounded,
              color: Colors.redAccent,
              size: 24,
            ): const Icon(
              Icons.insert_drive_file,
              color: Colors.white,
              size: 42,
            ),
            if (failed) const SizedBox(width: 8),
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
  void onAuth(DeviceData? deviceData, bool asServer, String msg, var callback) {
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

  var _isAlert = false;
  @override
  void onError(String message) {
    if (_isAlert) {
      return;
    }
    _isAlert = true;
    showConfirmationDialog(context, title:  AppLocalizations.of(context)?.timeoutTitle??"是否释放连接", description: message, confirmButtonText:  AppLocalizations.of(context)?.disconnect??"断开", cancelButtonText:  AppLocalizations.of(context)?.cancel??"取消", onConfirm: (){
      WsSvrManager().close();
      _isAlert = false;
    }, onCancel: () {
      _isAlert = false;
    });
  }

  @override
  void afterAuth(bool allow, DeviceData? deviceData) {
    if (deviceData == null) {
      return;
    }
    if (deviceData.uid != device.uid) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => SendMessageScreen(device: deviceData),
        ),
      );
    }else {
      setState(() {
        device = deviceData;
      });
    }
  }

  @override
  void onMessage(MessageData messageData) {
    logger.i("收到消息: ${messageData.type} content: ${messageData.content}");
    if (_isLocalhost && messageData.receiver.isEmpty || device.uid == socketManager.receiver && (messageData.sender == device.uid || messageData.receiver == device.uid)) {
      _insertItem(0, messageData);
    }
  }

  @override
  void onProgress(int size, length) {
    // TODO: implement onProgress
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastUpdateTime > 1000) {
      if (_lastUpdateTime > 0) {
        String speed = formatSize(1000 * (length - _sentSize)~/(now - _lastUpdateTime));
        setState(() {
          _speed = "$speed/s ";
        });
      }
      _lastUpdateTime = now;
      _sentSize = length;
    }
    _updatePercent(length/size);

    if (length == size) {
      _lastUpdateTime = 0;
      _sentSize = 0;
    }
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
  void initState() {
    _refreshDevice();
    super.initState();
  }

  Future<void> _refreshDevice() async {
    // 数据加载完成后更新状态
    var temp = await LocalDatabase().fetchDevice(device.uid);
    setState(() {
      device = temp!;
    });
  }

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
          title: Text(AppLocalizations.of(context)?.setting??'设置'),
        ),
        body: SafeArea(
          child: Material(
            child: ListView(
              padding: const EdgeInsets.all(16.0), // 添加内边距以改善外观
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
                          AppLocalizations.of(context)?.trust??'自动接入',
                          const Icon(Icons.wifi_rounded, color: CupertinoColors.systemGrey,),
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
                          AppLocalizations.of(context)?.writeClipboard??'写入剪切板',
                          const Icon(Icons.copy, color: CupertinoColors.systemGrey),
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
                        _buildSettingItem(
                          AppLocalizations.of(context)?.pushNotification??'推送安卓通知',
                          const Icon(Icons.notifications, color: CupertinoColors.systemGrey),
                          CupertinoSwitch(
                            value: device.syncNotification == true,
                            onChanged: (bool value) async {
                              LocalDatabase().updateNotification(device.uid, value);
                              var temp = await LocalDatabase().fetchDevice(device.uid);
                              setState(() {
                                device = temp!;
                              });
                              if (Platform.isAndroid && device.uid == WsSvrManager().receiver) {
                                value? startAndroidListening(): stopAndroidListening();
                              }
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
                          AppLocalizations.of(context)?.deleteDevice??'删除设备',
                          const Icon(Icons.delete_rounded, color: CupertinoColors.destructiveRed,),
                          null,
                          onTap: () {
                            showConfirmationDialog(context, title:  AppLocalizations.of(context)?.deleteDeviceTitle(device.name)??"删除${device.name}", description:  AppLocalizations.of(context)?.deleteDeviceDesc??"删除与此设备的所有消息，不可恢复", confirmButtonText:  AppLocalizations.of(context)?.confirm??"确定", cancelButtonText:  AppLocalizations.of(context)?.cancel??"取消", onConfirm: (){
                              LocalDatabase().clearDevices([device.uid]);
                              Navigator.popUntil(context, (route) {
                                return route.isFirst;
                              });
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
