import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:whisper/global.dart';
import 'package:whisper/helper/ftp.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/page/deviceList.dart';
import 'package:whisper/page/settings.dart' as app_settings;
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/widget/chat_composer.dart';
import 'package:whisper/widget/context_menu_region.dart';

import '../helper/file.dart';
import '../helper/helper.dart';

import '../helper/notification.dart';

import 'dart:io' show Platform;

import '../l10n/app_localizations.dart';

class SendMessageScreen extends StatefulWidget {
  final DeviceData device;
  final bool embedded;

  const SendMessageScreen({
    super.key,
    required this.device,
    this.embedded = false,
  });

  @override
  _SendMessageScreen createState() => _SendMessageScreen(device, embedded);
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
  final Map<String, bool> keyPressedMap = <String, bool>{};
  final key = GlobalKey<AnimatedListState>();
  bool _isLocalhost = false;
  bool _isLoading = false; // loading file
  final bool embedded;

  _SendMessageScreen(this.device, this.embedded);

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
    socketManager.unregisterEvent(this);
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    _composerFocusNode.dispose();
    _textController.dispose();
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
    var temp = isLocal ? me : await LocalDatabase().fetchDevice(device.uid);
    var arr = await LocalDatabase()
        .fetchMessageList(me.uid == temp?.uid ? "" : device.uid, limit: 20);
    setState(() {
      self = me;
      device = temp!;
      _isLocalhost = isLocal;
      // messageList = arr;
    });

    _insertItems(0, arr);

    _scrollController.addListener(_scrollListener);

    // 开启通知监听
    if (Platform.isAndroid &&
        !isLocal &&
        temp?.uid == socketManager.receiver &&
        (await LocalSetting().isListenAndroid())) {
      startAndroidListening();
    }
  }

  Future<void> _refreshCurrentDeviceState() async {
    final me = await LocalSetting().instance();
    final isLocal = me.uid == device.uid;
    final latestDevice =
        isLocal ? me : await LocalDatabase().fetchDevice(device.uid);
    if (!mounted || latestDevice == null) {
      return;
    }
    setState(() {
      self = me;
      device = latestDevice;
      _isLocalhost = isLocal;
    });
  }

  void _scrollListener() async {
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
    final content = Column(
      children: [
        if (embedded) _buildEmbeddedHeader(isDark),
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
              initialItemCount: messageList.length,
              reverse: true,
              shrinkWrap: true,
              itemBuilder: (context, index, animation) {
                var message = messageList[index];
                bool isOpponent = message.receiver == self?.uid;
                bool isFile = message.type == MessageEnum.File;

                return FadeTransition(
                    opacity: animation,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                      child: Column(
                        crossAxisAlignment: isOpponent
                            ? CrossAxisAlignment.start
                            : CrossAxisAlignment.end,
                        children: [
                          Container(
                            alignment: isOpponent
                                ? Alignment.centerLeft
                                : Alignment.centerRight,
                            child: ContextMenuRegion(
                              child: GestureDetector(
                                child: isFile
                                    ? _buildFileMessage(message, isOpponent)
                                    : _buildTextMessage(message, isOpponent),
                                onTap: () {
                                  if (isFile) {
                                    openFile(message.path);
                                  }
                                },
                                onLongPress: () {},
                              ),
                              items: [
                                if (!isFile)
                                  ContextMenuActionItem(
                                    label: AppLocalizations.of(context)
                                            ?.copyMessage ??
                                        '复制消息',
                                    onSelected: () {
                                      if (message.content?.isNotEmpty == true) {
                                        copyToClipboard(message.content!);
                                      }
                                    },
                                  ),
                                if (!isFile)
                                  ContextMenuActionItem(
                                    label:
                                        AppLocalizations.of(context)?.delete ??
                                            '删除',
                                    onSelected: () {
                                      _deleteItem(message.id);
                                    },
                                  ),
                                if (isFile && (isOpponent || isDesktop()))
                                  ContextMenuActionItem(
                                    label: AppLocalizations.of(context)?.open ??
                                        '打开',
                                    onSelected: () {
                                      logger.i(message.path);
                                      openFile(message.path);
                                    },
                                  ),
                                if (isFile && (isOpponent || isDesktop()))
                                  ContextMenuActionItem(
                                    label: (Platform.isMacOS
                                            ? AppLocalizations.of(context)
                                                ?.openInFinder
                                            : AppLocalizations.of(context)
                                                ?.openInDir) ??
                                        '所在文件夹',
                                    onSelected: () {
                                      logger.i(message.path);
                                      openDir(message.path, parent: true);
                                    },
                                  ),
                                if (isFile && isOpponent)
                                  ContextMenuActionItem(
                                    label:
                                        '${AppLocalizations.of(context)?.delete ?? '删除'} (${AppLocalizations.of(context)?.keepFile ?? '保留文件'})',
                                    onSelected: () {
                                      _deleteItem(message.id);
                                    },
                                  ),
                                if (isFile && isOpponent)
                                  ContextMenuActionItem(
                                    label:
                                        '${AppLocalizations.of(context)?.delete ?? '删除'} (${AppLocalizations.of(context)?.deleteFile ?? '删除文件'})',
                                    onSelected: () {
                                      logger.i("delete ${message.path}");
                                      File(message.path).delete();
                                      _deleteItem(message.id);
                                    },
                                  ),
                                if (isFile && !isOpponent)
                                  ContextMenuActionItem(
                                    label:
                                        AppLocalizations.of(context)?.delete ??
                                            '删除',
                                    onSelected: () {
                                      _deleteItem(message.id);
                                    },
                                  ),
                              ],
                            ),
                          ),
                          SizedBox(
                            height: message.type == MessageEnum.File ? 4 : 2,
                          ),
                          Stack(
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: isOpponent
                                        ? isMobile()
                                            ? 10
                                            : 0
                                        : 20,
                                  ),
                                  Text(
                                    " ${formatTimestamp(message.timestamp)} ",
                                    style: TextStyle(
                                        color: isDark
                                            ? Colors.grey[400]
                                            : Colors.grey,
                                        fontSize: 12),
                                  ),
                                  SizedBox(
                                    width: isOpponent
                                        ? 20
                                        : isMobile()
                                            ? 10
                                            : 0,
                                  ),
                                ],
                              ),
                              if (message.type == MessageEnum.Text)
                                Positioned(
                                  left: isOpponent ? null : -12,
                                  right: isOpponent ? -12 : null,
                                  top: Platform.isMacOS ? -12.2 : -14,
                                  child: IconButton(
                                    hoverColor: Colors.grey.withOpacity(0),
                                    focusColor: Colors.grey,
                                    highlightColor: Colors.transparent,
                                    icon: Icon(
                                      Icons.copy,
                                      size: (isMobile() ? 16 : 18),
                                      color: isDark
                                          ? Colors.grey[400]
                                          : Colors.grey,
                                    ),
                                    onPressed: () {
                                      if (message.content?.isNotEmpty == true) {
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
          ),
        ),
        _buildComposer(isDark),
        if (!embedded)
          const SizedBox(
            height: 6,
          )
      ],
    );

    Widget base = embedded
        ? Material(
            color: isDark ? Colors.black : Colors.white,
            child: content,
          )
        : Scaffold(
            appBar: _buildStandaloneAppBar(isDark),
            body: content,
          );

    if (isMobile()) {
      return base;
    }

    return DropTarget(
      onDragDone: (detail) async {
        if (detail.files.isEmpty || _isLocalhost || !_canSendCurrentDevice) {
          return;
        }
        for (var item in detail.files) {
          await socketManager.sendFile(item.path);
        }
      },
      onDragEntered: (detail) {},
      onDragExited: (detail) {},
      child: base,
    );
  }

  bool get _canSendCurrentDevice {
    return _isLocalhost || device.uid == socketManager.receiver;
  }

  bool get _isConnectedSession {
    return device.uid == socketManager.receiver;
  }

  bool get _canToggleConnection {
    return _isConnectedSession || socketManager.receiver.isEmpty;
  }

  PreferredSizeWidget _buildStandaloneAppBar(bool isDark) {
    return AppBar(
      leading: CupertinoNavigationBarBackButton(
        color: isDark ? Colors.grey[400] : Colors.grey,
        onPressed: () {
          Navigator.popUntil(context, (route) {
            return route.isFirst;
          });
        },
      ),
      title: _buildConversationTitle(isDark),
      actions: _buildHeaderActions(isDark),
    );
  }

  Widget _buildEmbeddedHeader(bool isDark) {
    return Container(
      height: 72,
      padding: const EdgeInsets.fromLTRB(18, 10, 12, 10),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[900] : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isDark ? Colors.grey[800]! : Colors.grey[200]!,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(child: _buildConversationTitle(isDark)),
          ..._buildHeaderActions(isDark),
        ],
      ),
    );
  }

  Widget _buildConversationTitle(bool isDark) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          device.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isDark ? Colors.white : Colors.black,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isConnectedSession
                    ? Colors.lightBlue
                    : (device.around == true ? Colors.green : Colors.grey),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${_connectionStatusText()} · ${device.host}:${device.port}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.grey[400] : Colors.black54,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _buildHeaderActions(bool isDark) {
    final actions = <Widget>[];
    if (percent > 0 && percent < 1 && _isConnectedSession) {
      actions.add(
        Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _speed,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.grey[400] : Colors.black54,
                ),
              ),
              Text(
                "${(100 * percent).toStringAsFixed(2)}%",
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.grey[400] : Colors.black54,
                ),
              ),
            ],
          ),
        ),
      );
    }
    actions.add(
      IconButton(
        onPressed: _canToggleConnection ? _toggleConnection : null,
        tooltip: _isConnectedSession
            ? (AppLocalizations.of(context)?.disconnect ?? '断开')
            : (AppLocalizations.of(context)?.connect ?? '连接'),
        icon: Icon(
          _isConnectedSession
              ? Icons.wifi_rounded
              : (_canToggleConnection
                  ? Icons.wifi_find_rounded
                  : Icons.wifi_off_rounded),
          color: _isConnectedSession
              ? Colors.lightBlue
              : (_canToggleConnection
                  ? (isDark ? Colors.white60 : Colors.black45)
                  : Colors.grey),
        ),
      ),
    );
    actions.add(
      PopupMenuButton<String>(
        tooltip: AppLocalizations.of(context)?.setting ?? '设置',
        onSelected: (value) async {
          if (value == 'settings') {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    app_settings.ClientSettingsScreen(device: device),
              ),
            );
            await _refreshCurrentDeviceState();
            return;
          }
          if (value == 'ftp') {
            SimpleFtpServer().openClient("${device.host}:$defaultFtpPort");
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem<String>(
            value: 'settings',
            child: Text(AppLocalizations.of(context)?.setting ?? '设置'),
          ),
          if (isDesktop())
            const PopupMenuItem<String>(
              value: 'ftp',
              child: Text('FTP'),
            ),
        ],
      ),
    );
    return actions;
  }

  String _connectionStatusText() {
    final l10n = AppLocalizations.of(context);
    if (_isConnectedSession) {
      return l10n?.connectedNow ?? '当前已连接';
    }
    if (device.around == true) {
      return l10n?.nearbyAvailable ?? '附近可连接';
    }
    return l10n?.noMessagesYet ?? '还没有消息';
  }

  Widget _buildComposer(bool isDark) {
    return ChatComposer(
      clipboardEnabled: self?.clipboard == true,
      canSend: _canSendCurrentDevice,
      isInputEmpty: isInputEmpty,
      isLoading: _isLoading,
      isLocalhost: _isLocalhost,
      isDesktopStyle: isDesktop(),
      keyPressedMap: keyPressedMap,
      controller: _textController,
      focusNode: _composerFocusNode,
      onPickFiles: _pickFilesAndSend,
      onSendClipboard: () async {
        await _sendText("", isClipboard: true);
      },
      onSendText: (text) async {
        await _sendText(text);
      },
    );
  }

  Future<void> _pickFilesAndSend() async {
    if (!_canSendCurrentDevice || _isLocalhost) {
      return;
    }
    setState(() {
      _isLoading = true;
    });
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null) {
        return;
      }
      for (final item in result.files) {
        if (item.path == null || item.path!.isEmpty) {
          continue;
        }
        await socketManager.sendFile(item.path!);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _toggleConnection() {
    if (_isConnectedSession) {
      showConfirmationDialog(
        context,
        title: AppLocalizations.of(context)?.brokeConnectTitle ?? "断开连接",
        description:
            '${AppLocalizations.of(context)?.disconnect ?? "断开"} ${device.name}',
        confirmButtonText: AppLocalizations.of(context)?.confirm ?? '确定',
        cancelButtonText: AppLocalizations.of(context)?.cancel ?? '取消',
        onConfirm: () {
          socketManager.close();
        },
      );
      return;
    }
    if (_canToggleConnection) {
      _connectServer(device.host, device.port);
    }
  }

  void _connectServer(String host, int port) async {
    if (await isLocalhost(host)) {
      afterAuth(true, device);
      return;
    }
    socketManager.connectToServer(host, port, (ok, message) {
      if (!ok) {
        showLoadingDialog(
          context,
          title: AppLocalizations.of(context)?.connectFailed ??
              'Connection Failed',
          description: "$message",
          isLoading: true,
          icon: const Icon(
            Icons.warning_rounded,
            color: Colors.red,
          ),
          cancelButtonText: AppLocalizations.of(context)?.cancel ?? 'Cancel',
          onCancel: () {
            Navigator.of(context).pop();
          },
          task: (VoidCallback onCancel) async {},
        );
      }
    });
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return IntrinsicWidth(
      child: Container(
        alignment: isOpponent ? Alignment.centerLeft : Alignment.centerRight,
        constraints: BoxConstraints(maxWidth: screenWidth),
        decoration: BoxDecoration(
          color: isOpponent
              ? (isDark ? Colors.grey[800] : Colors.grey[300])
              : (isDark ? Colors.grey[800] : Colors.blue),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: SelectableText(
            content,
            style: TextStyle(
              color: isOpponent
                  ? (isDark ? Colors.white70 : Colors.black)
                  : (isDark ? Colors.white70 : Colors.white),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: screenWidth,
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[800] : Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
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
                    color: isDark ? Colors.grey[400] : Colors.white,
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
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    maxLines: 4,
                    softWrap: true,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatSize(message.size),
                  style: TextStyle(
                      color: isDark ? Colors.grey[400] : Colors.black,
                      fontSize: 12),
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
    percent = 0;
    _speed = "";
    _refreshCurrentDeviceState();
    if (!mounted) {
      return;
    }
    Fluttertoast.showToast(
      msg:
          '${AppLocalizations.of(context)?.disconnect ?? "Disconnect"} ${device.name}',
    );
    setState(() {});
  }

  @override
  void onConnect() {
    _refreshCurrentDeviceState();
    if (!mounted) {
      return;
    }
    Fluttertoast.showToast(
      msg:
          '${AppLocalizations.of(context)?.connect ?? "Connect"} ${device.name}',
    );
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
    if (!allow || deviceData == null) {
      return;
    }
    if (deviceData.uid != device.uid) {
      if (!embedded) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => SendMessageScreen(device: deviceData),
          ),
        );
      }
    } else {
      setState(() {
        device = deviceData;
      });
    }
    _refreshCurrentDeviceState();
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
