import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:whisper/global.dart';
import 'package:whisper/helper/ftp.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/page/settings.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_dialogs.dart';
import 'package:whisper/widget/chat_composer.dart';
import 'package:whisper/widget/chat_connection_banner.dart';
import 'package:whisper/widget/chat_message_list.dart';
import 'package:whisper/widget/context_menu_region.dart';

import '../helper/file.dart';
import '../helper/helper.dart';

import '../helper/notification.dart';

import '../l10n/app_localizations.dart';

class SendMessageScreen extends StatefulWidget {
  final DeviceData device;

  const SendMessageScreen({super.key, required this.device});

  @override
  _SendMessageScreen createState() => _SendMessageScreen(device);
}

class _SendMessageScreen extends State<SendMessageScreen>
    implements ISocketEvent {
  final db = LocalDatabase();
  final socketManager = WsSvrManager();
  DeviceData device;
  DeviceData? self;
  List<MessageData> messageList = [];
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _textController = TextEditingController();
  final FocusNode _composerFocusNode = FocusNode();
  bool isInputEmpty = true;
  double percent = 0;
  String _speed = "";
  int _sentSize = 0;
  int _lastUpdateTime = 0;
  final Map<String, bool> keyPressedMap = {};
  final key = GlobalKey<AnimatedListState>();
  bool _isLocalhost = false;
  bool _isLoading = false; // loading file

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
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    _textController.dispose();
    _composerFocusNode.dispose();
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
    final me = await LocalSetting().instance();
    final isLocal = me.uid == device.uid;
    final temp = isLocal ? me : await LocalDatabase().fetchDevice(device.uid);
    if (temp == null) {
      return;
    }
    final arr = await LocalDatabase()
        .fetchMessageList(me.uid == temp.uid ? "" : device.uid, limit: 20);
    if (!mounted) {
      return;
    }
    setState(() {
      self = me;
      device = temp;
      _isLocalhost = isLocal;
    });

    _insertItems(0, arr);

    _scrollController.addListener(_scrollListener);

    // 开启通知监听
    if (Platform.isAndroid &&
        !isLocal &&
        temp.uid == socketManager.receiver &&
        (await LocalSetting().isListenAndroid())) {
      startAndroidListening();
    }
  }

  void _scrollListener() async {
    if (messageList.isEmpty) {
      return;
    }
    if (_scrollController.position.pixels ==
        _scrollController.position.maxScrollExtent) {
      // 用户滑动到了ListView的底部
      // 在这里执行你的操作
      logger.i('滑倒顶部了！${messageList[0].id}');
      var arr = await LocalDatabase().fetchMessageList(device.uid,
          beforeId: messageList.last.id, limit: 12);
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
    key.currentState
        ?.insertItem(index, duration: const Duration(milliseconds: 500));
  }

  _insertItems(index, items) {
    messageList.insertAll(index, items);
    key.currentState?.insertAllItems(index, items.length,
        duration: const Duration(milliseconds: 500));
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

  Future<void> _deleteMessage(MessageData message,
      {bool deleteFile = false}) async {
    if (deleteFile && message.path.isNotEmpty) {
      final file = File(message.path);
      if (await file.exists()) {
        await file.delete();
      }
    }
    _deleteItem(message.id);
  }

  @Deprecated("use list view reverse")
  void _scrollToBottom({bool isFirst = false}) async {
    if (isFirst) {
      _scrollController.jumpTo(
        _scrollController.position.maxScrollExtent,
        // duration: const Duration(milliseconds: 200),
        // curve: Curves.easeOut,
      );
    } else {
      await _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;

    final content = Scaffold(
      appBar: AppBar(
        leading: CupertinoNavigationBarBackButton(
          color: isDark ? Colors.grey[400] : Colors.grey,
          onPressed: () {
            Navigator.popUntil(context, (route) {
              return route.isFirst;
            });
          },
        ),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(device.name,
                    style: TextStyle(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w700)), // 设备名称
                Row(
                  children: [
                    Text(
                      "${device.host}:${device.port}", // 设备 IP 地址
                      style: TextStyle(
                          fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(width: 4),
                    if (socketManager.receiver == device.uid)
                      Icon(Icons.wifi_rounded,
                          size: 14, color: palette.connected)
                  ],
                )
              ],
            ),
          ],
        ),
        actions: [
          if (percent > 0 &&
              percent < 1 &&
              device.uid == socketManager.receiver)
            Column(
              children: [
                const SizedBox(height: 12),
                Text(_speed,
                    style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.grey[400] : Colors.black)),
                const SizedBox(height: 2),
                Text("${(100 * percent).toStringAsFixed(2)}%",
                    style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.grey[400] : Colors.black)),
              ],
            ),
          if (false)
            CupertinoButton(
              // 使用CupertinoButton
              padding: EdgeInsets.zero,
              child: const Icon(
                Icons.loop_rounded,
                size: 30,
                color: Colors.black45,
              ),
              onPressed: () async {
                // todo update device ftp port
                SimpleFtpServer().openClient("${device.host}:$defaultFtpPort");
              },
            ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            child: Icon(
              Icons.settings_outlined,
              size: 30,
              color: colorScheme.onSurfaceVariant,
            ),
            onPressed: () async {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ClientSettingsScreen(
                    device: device,
                  ),
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
              color: palette.trusted,
            ),
          if (!_isLocalhost)
            ChatConnectionBanner(
              connected: socketManager.receiver == device.uid,
            ),
          Expanded(
            child: ChatMessageList(
              buildFileMessage: _buildFileMessage,
              buildTextMessage: _buildTextMessage,
              controller: _scrollController,
              listKey: key,
              messages: messageList,
              onCopyText: copyToClipboard,
              onDeleteMessage: _deleteMessage,
              onOpenContainingFolder: (path) => openDir(path, parent: true),
              onOpenFile: openFile,
              selfUid: self?.uid,
            ),
          ),
          if (_isLocalhost || device.uid == socketManager.receiver)
            ChatComposer(
              clipboardEnabled: self?.clipboard == true,
              controller: _textController,
              focusNode: _composerFocusNode,
              isInputEmpty: isInputEmpty,
              isLoading: _isLoading,
              isLocalhost: _isLocalhost,
              keyPressedMap: keyPressedMap,
              onPickFiles: () async {
                if (_isLocalhost) {
                  return;
                }
                setState(() {
                  _isLoading = true;
                });
                final result =
                    await FilePicker.platform.pickFiles(allowMultiple: true);
                if (!mounted) {
                  return;
                }
                setState(() {
                  _isLoading = false;
                });
                if (result != null) {
                  for (final item in result.files) {
                    await socketManager.sendFile(item.path ?? "");
                  }
                }
              },
              onSendClipboard: () => _sendText("", isClipboard: true),
              onSendText: _sendText,
            ),
          const SizedBox(
            height: 6,
          )
        ],
      ),
    );

    if (isMobile()) {
      return content;
    }

    return DropTarget(
      onDragDone: (detail) async {
        if (detail.files.isEmpty || _isLocalhost) {
          return;
        }
        for (var item in detail.files) {
          await socketManager.sendFile(item.path);
        }
      },
      onDragEntered: (detail) {},
      onDragExited: (detail) {},
      child: content,
    );
  }

  Future<void> _sendText(String content, {isClipboard = false}) async {
    if (isClipboard) {
      var str = await getClipboardText() ?? "";
      content = str.trimRight();
    }
    if (content.trim().isEmpty) {
      return;
    }
    if (_isLocalhost) {
      var message = MessageData(
          id: 0,
          sender: device.uid,
          receiver: "",
          name: "",
          clipboard: isClipboard,
          size: 0,
          type: MessageEnum.Text,
          content: content,
          message: "",
          timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          acked: true,
          uuid: LocalUuid.v4(),
          path: "",
          md5: "");
      LocalDatabase().insertMessage(message);
      onMessage(message);
    } else if (socketManager.receiver == device.uid) {
      await socketManager.sendMessage(content, clipboard: isClipboard);
    }
  }

  // 获取设备横向宽度
  double _screenWidth({physically = false}) {
    if (!physically) {
      return MediaQuery.of(context).size.width;
    }
    return min(
        MediaQuery.of(context).size.width, MediaQuery.of(context).size.height);
  }

  Widget _buildTextMessage(MessageData messageData, bool isOpponent) {
    double screenWidth = _screenWidth();
    if (isDesktop()) {
      screenWidth *= 0.618;
    } else {
      screenWidth *= 0.8;
    }
    var content = messageData.content ?? "";
    if (messageData.type == MessageEnum.Notification) {
      var data = jsonDecode(messageData.content ?? "{}");
      content = "【${data['app']}】${data['title']}\n${data['text']}";
    }
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;

    return IntrinsicWidth(
      child: Container(
        alignment: isOpponent ? Alignment.centerLeft : Alignment.centerRight,
        constraints: BoxConstraints(maxWidth: screenWidth),
        decoration: BoxDecoration(
          color: isOpponent
              ? colorScheme.surfaceContainerHighest
              : palette.connected.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: SelectableText(
            content,
            style: TextStyle(
              color: colorScheme.onSurface,
            ),
            contextMenuBuilder: (context, editableTextState) {
              return AdaptiveTextSelectionToolbar(
                anchors: editableTextState.contextMenuAnchors,
                children: const [],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildFileMessage(MessageData message, bool isOpponent) {
    double screenWidth = 300;
    if (isMobile()) {
      screenWidth = 0.618 * _screenWidth(physically: false);
    }
    var failed =
        !isOpponent && !message.acked && message.timestamp < device.lastTime;
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;

    return Container(
      width: screenWidth,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failed) const SizedBox(width: 8),
            failed
                ? const Icon(
                    Icons.error_outline_rounded,
                    color: Colors.redAccent,
                    size: 24,
                  )
                : Icon(
                    Icons.insert_drive_file,
                    color: failed ? palette.danger : colorScheme.primary,
                    size: 42,
                  ),
            if (failed) const SizedBox(width: 8),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: screenWidth - 80,
                  child: Text(
                    message.name,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 4,
                    softWrap: true,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatSize(message.size),
                  style: TextStyle(
                      color: colorScheme.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
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
    setState(() {});
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
    showConfirmationDialog(context,
        title: AppLocalizations.of(context)?.timeoutTitle ?? "是否释放连接",
        description: message,
        confirmButtonText: AppLocalizations.of(context)?.disconnect ?? "断开",
        cancelButtonText: AppLocalizations.of(context)?.cancel ?? "取消",
        onConfirm: () {
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
    } else {
      setState(() {
        device = deviceData;
      });
    }
  }

  @override
  void onMessage(MessageData messageData) {
    logger.i("收到消息: ${messageData.type} content: ${messageData.content}");
    if (_isLocalhost && messageData.receiver.isEmpty ||
        device.uid == socketManager.receiver &&
            (messageData.sender == device.uid ||
                messageData.receiver == device.uid)) {
      _insertItem(0, messageData);
    }
  }

  @override
  void onProgress(int size, length) {
    if (device.uid != socketManager.receiver) {
      return;
    }
    // TODO: implement onProgress
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastUpdateTime > 1000) {
      if (_lastUpdateTime > 0) {
        String speed =
            formatSize(1000 * (length - _sentSize) ~/ (now - _lastUpdateTime));
        setState(() {
          _speed = "$speed/s ";
        });
      }
      _lastUpdateTime = now;
      _sentSize = length;
    }
    _updatePercent(length / size);

    if (length == size) {
      _lastUpdateTime = 0;
      _sentSize = 0;
    }
  }
}
