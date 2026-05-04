import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/global.dart';
import 'package:whisper/helper/android_background.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/page/deviceList.dart';
import 'package:whisper/page/settings.dart' as app_settings;
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/chat_composer.dart';
import 'package:whisper/widget/chat_message_list.dart';

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
    with WidgetsBindingObserver
    implements ISocketEvent {
  static const int _transferUiSpeedRefreshMs = 300;

  final db = LocalDatabase();
  final socketManager = WsSvrManager();
  final AudioShareCoordinator _audioCoordinator = AudioShareCoordinator.shared;
  final RemoteInputCoordinator _remoteInputCoordinator =
      RemoteInputCoordinator.shared;
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
  final Map<String, TransferSnapshot> _transferSnapshots =
      <String, TransferSnapshot>{};
  String? _activeTransferId;
  final Map<String, bool> keyPressedMap = <String, bool>{};
  final key = GlobalKey<AnimatedListState>();
  bool _isLocalhost = false;
  bool _isLoading = false; // loading file
  final bool embedded;
  bool _resumeReconnectPending = false;
  bool _pickerReconnectPending = false;

  bool get _isCurrentRoute {
    final route = ModalRoute.of(context);
    return route?.isCurrent ?? mounted;
  }

  Future<void> _syncAndroidKeepAliveService() async {
    if (!Platform.isAndroid) {
      return;
    }
    final enabled = await LocalSetting().androidBackgroundKeepAlive();
    if (!enabled || !_isConnectedSession) {
      await stopAndroidBackgroundKeepAlive();
      return;
    }
    final notificationPermission = await Permission.notification.status;
    if (notificationPermission.isDenied) {
      await Permission.notification.request();
    }
    await startAndroidBackgroundKeepAlive(
      title:
          AppLocalizations.of(context)?.androidBackgroundKeepAliveActiveTitle ??
              'Whisper is keeping the connection alive',
      description:
          AppLocalizations.of(context)?.androidBackgroundKeepAliveActiveDesc ??
              'Active while a device session is connected',
    );
  }

  _SendMessageScreen(this.device, this.embedded);

  @override
  void initState() {
    logger.i("init conv: ${socketManager.receiver}-${device.uid}");
    WidgetsBinding.instance.addObserver(this);
    socketManager.registerEvent(this);
    _audioCoordinator.addListener(_handleAudioShareChanged);
    _remoteInputCoordinator.addListener(_handleRemoteInputChanged);
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
    WidgetsBinding.instance.removeObserver(this);
    socketManager.unregisterEvent(this);
    _audioCoordinator.removeListener(_handleAudioShareChanged);
    _remoteInputCoordinator.removeListener(_handleRemoteInputChanged);
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    _composerFocusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _handleAudioShareChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _handleRemoteInputChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) {
      return;
    }

    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _resumeReconnectPending = _isConnectedSession;
        socketManager.refreshConnectionLiveness();
        break;
      case AppLifecycleState.resumed:
        final shouldReconnect =
            _resumeReconnectPending || _pickerReconnectPending;
        _resumeReconnectPending = false;
        if (shouldReconnect && !_isConnectedSession && _canToggleConnection) {
          _restoreConnectionIfNeeded();
          return;
        }
        if (_isConnectedSession) {
          socketManager.refreshConnectionLiveness();
        }
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  void _updatePercent(double num) {
    // logger.i("percent: ${(100*num).toStringAsFixed(2)}%");
    setState(() {
      percent = num;
    });
  }

  Future<void> _loadTransferSnapshotsForMessages(
    Iterable<MessageData> messages,
  ) async {
    final transferIds = messages
        .where((item) => item.type == MessageEnum.File)
        .map((item) => item.uuid)
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    if (transferIds.isEmpty) {
      return;
    }
    final transfers = await db.fetchFileTransfersByIds(transferIds);
    if (!mounted) {
      return;
    }
    setState(() {
      for (final entry in transfers.entries) {
        _transferSnapshots[entry.key] = db.snapshotForTransfer(entry.value);
      }
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
    unawaited(_loadTransferSnapshotsForMessages(arr));

    _scrollController.addListener(_scrollListener);

    // 开启通知监听
    if (Platform.isAndroid &&
        !isLocal &&
        temp?.uid == socketManager.receiver &&
        (await LocalSetting().isListenAndroid())) {
      startAndroidListening();
    }
    await _syncAndroidKeepAliveService();
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
    await _syncAndroidKeepAliveService();
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

  TransferSnapshot? _transferForMessage(MessageData message) {
    return _transferSnapshots[message.uuid];
  }

  bool _isTransferTerminal(FileTransferState state) {
    return state == FileTransferState.completed ||
        state == FileTransferState.failed ||
        state == FileTransferState.canceled;
  }

  String _fileStatusText(MessageData message, TransferSnapshot? transfer) {
    if (transfer == null) {
      if (_isConnectedSession &&
          !socketManager.supportsResumableTransfer &&
          !message.acked) {
        return '旧协议传输中';
      }
      return formatSize(message.size);
    }
    switch (transfer.state) {
      case FileTransferState.queued:
        return '排队中';
      case FileTransferState.negotiating:
        return transfer.committedBytes > 0
            ? '准备续传 ${(transfer.progress * 100).toStringAsFixed(0)}%'
            : '协商中';
      case FileTransferState.transferring:
        return '${formatSize(message.size)}  ${(transfer.progress * 100).toStringAsFixed(0)}%';
      case FileTransferState.waitingReconnect:
        return '等待重连 ${(transfer.progress * 100).toStringAsFixed(0)}%';
      case FileTransferState.paused:
        return '已暂停';
      case FileTransferState.verifying:
        return '校验中';
      case FileTransferState.completed:
        return formatSize(message.size);
      case FileTransferState.failed:
        return transfer.lastError.isEmpty ? '失败，可重试' : transfer.lastError;
      case FileTransferState.canceled:
        return '已取消';
    }
  }

  Future<void> _retryTransfer(String transferId) async {
    await socketManager.retryTransfer(transferId);
  }

  Future<void> _cancelTransfer(String transferId) async {
    await socketManager.cancelTransfer(transferId);
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
    final colorScheme = Theme.of(context).colorScheme;
    final content = Column(
      children: [
        if (embedded) _buildEmbeddedHeader(isDark),
        if (percent > 0 && percent < 1)
          LinearProgressIndicator(
            value: percent,
            color: Colors.lightGreen,
          ),
        Expanded(
          child: ChatMessageList(
            buildFileMessage: _buildFileMessage,
            buildTextMessage: _buildTextMessage,
            controller: _scrollController,
            listKey: key,
            messages: messageList,
            onOpenContainingFolder: (path) => openDir(path, parent: true),
            onOpenFile: openFile,
            onCopyText: copyToClipboard,
            onDeleteMessage: (message, {deleteFile = false}) async {
              if (deleteFile && message.path.isNotEmpty) {
                logger.i("delete ${message.path}");
                await File(message.path).delete();
              }
              _deleteItem(message.id);
            },
            selfUid: self?.uid,
          ),
        ),
        if (_canSendCurrentDevice) _buildComposer(isDark),
        if (!embedded && _canSendCurrentDevice)
          const SizedBox(
            height: 6,
          )
      ],
    );

    Widget base = embedded
        ? Material(
            color: colorScheme.surface,
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
    final colorScheme = Theme.of(context).colorScheme;
    return AppBar(
      leading: CupertinoNavigationBarBackButton(
        color: colorScheme.primary,
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
    final palette = context.whisperPalette;
    return Container(
      height: 72,
      padding: const EdgeInsets.fromLTRB(18, 10, 12, 10),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        border: Border(
          bottom: BorderSide(
            color: palette.borderSubtle,
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
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          device.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: colorScheme.onSurface,
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
                  color: palette.textMuted,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _buildHeaderActions(bool isDark) {
    final palette = context.whisperPalette;
    final compactActions = !isDesktop();
    final actionPadding = compactActions ? EdgeInsets.zero : null;
    final actionConstraints = compactActions
        ? const BoxConstraints.tightFor(width: 36, height: 48)
        : null;
    final actionVisualDensity = compactActions ? VisualDensity.compact : null;
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
                  color: palette.textMuted,
                ),
              ),
              Text(
                "${(100 * percent).toStringAsFixed(2)}%",
                style: TextStyle(
                  fontSize: 12,
                  color: palette.textMuted,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_isConnectedSession && !socketManager.supportsResumableTransfer) {
      actions.add(
        IconButton(
          padding: actionPadding,
          constraints: actionConstraints,
          visualDensity: actionVisualDensity,
          tooltip: '对端不支持断点续传',
          icon: Icon(
            Icons.history_toggle_off_rounded,
            color: palette.textMuted,
          ),
          onPressed: () {
            showAppToast('当前连接设备不支持断点续传');
          },
        ),
      );
    }
    if (_shouldShowAudioShareAction) {
      final audioState = _audioCoordinator.state;
      final isCurrentAudioSession = audioState.isForPeer(device.uid);
      final isActive = isCurrentAudioSession && audioState.isActive;
      final isBusy = isCurrentAudioSession && audioState.isBusy;
      final role = isCurrentAudioSession
          ? audioState.role
          : AudioShareRuntimeRole.source;
      actions.add(
        IconButton(
          padding: actionPadding,
          constraints: actionConstraints,
          visualDensity: actionVisualDensity,
          onPressed: isBusy ? null : _toggleAudioShare,
          tooltip: _audioShareTooltip(role, isActive: isActive, isBusy: isBusy),
          icon: Icon(_audioShareIcon(role)),
          color: _audioShareIconColor(
            isActive: isActive,
            isBusy: isBusy,
            isDark: isDark,
          ),
        ),
      );
    }
    if (_shouldShowRemoteInputAction) {
      final inputState = _remoteInputCoordinator.state;
      final isCurrentInputSession = inputState.isForPeer(device.uid);
      final isActive = isCurrentInputSession && inputState.isActive;
      final isBusy = isCurrentInputSession && inputState.isBusy;
      actions.add(
        IconButton(
          padding: actionPadding,
          constraints: actionConstraints,
          visualDensity: actionVisualDensity,
          onPressed: isBusy ? null : () => _toggleRemoteInput(),
          tooltip: _remoteInputTooltip(
            inputState.role,
            isActive: isActive,
            isBusy: isBusy,
            isArmed: isCurrentInputSession &&
                inputState.status == RemoteInputRuntimeStatus.armed,
          ),
          icon: const Icon(Icons.keyboard_option_key_rounded),
          color: _remoteInputIconColor(
            isActive: isActive,
            isBusy: isBusy,
            isArmed: isCurrentInputSession &&
                inputState.status == RemoteInputRuntimeStatus.armed,
          ),
        ),
      );
    }
    actions.add(
      IconButton(
        padding: actionPadding,
        constraints: actionConstraints,
        visualDensity: actionVisualDensity,
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
              : (_canToggleConnection ? palette.textMuted : Colors.grey),
        ),
      ),
    );
    actions.add(
      IconButton(
        padding: actionPadding,
        constraints: actionConstraints,
        visualDensity: actionVisualDensity,
        tooltip: AppLocalizations.of(context)?.setting ?? '设置',
        icon: Icon(
          Icons.settings_outlined,
          color: palette.textMuted,
        ),
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  app_settings.ClientSettingsScreen(device: device),
            ),
          );
          await _refreshCurrentDeviceState();
        },
      ),
    );
    return actions;
  }

  bool get _shouldShowAudioShareAction {
    final audioState = _audioCoordinator.state;
    return !_isLocalhost &&
        _isConnectedSession &&
        (isDesktop() || audioState.isForPeer(device.uid));
  }

  bool get _shouldShowRemoteInputAction {
    final inputState = _remoteInputCoordinator.state;
    return !_isLocalhost &&
        _isConnectedSession &&
        supportsNativeRemoteInput() &&
        (socketManager.supportsRemoteInput || inputState.isForPeer(device.uid));
  }

  IconData _audioShareIcon(AudioShareRuntimeRole role) {
    switch (role) {
      case AudioShareRuntimeRole.source:
        return Icons.volume_up_outlined;
      case AudioShareRuntimeRole.sink:
        return Icons.volume_up_rounded;
      case AudioShareRuntimeRole.none:
        return Icons.volume_up_outlined;
    }
  }

  Color _audioShareIconColor({
    required bool isActive,
    required bool isBusy,
    required bool isDark,
  }) {
    if (!isActive && !isBusy) {
      return context.whisperPalette.textMuted;
    }
    return Colors.lightBlue;
  }

  String _audioShareTooltip(
    AudioShareRuntimeRole role, {
    required bool isActive,
    required bool isBusy,
  }) {
    if (isBusy) {
      return role == AudioShareRuntimeRole.source
          ? '采集端：正在连接远端扬声器'
          : '播放端：正在准备播放共享声音';
    }
    if (isActive) {
      return role == AudioShareRuntimeRole.source
          ? '采集端：正在共享本机声音，点击停止'
          : '播放端：正在作为扬声器播放，点击停止';
    }
    return '共享本机声音到此设备';
  }

  Color _remoteInputIconColor({
    required bool isActive,
    required bool isBusy,
    required bool isArmed,
  }) {
    if (!isActive && !isBusy && !isArmed) {
      return context.whisperPalette.textMuted;
    }
    return Colors.lightBlue;
  }

  String _remoteInputTooltip(
    RemoteInputRuntimeRole role, {
    required bool isActive,
    required bool isBusy,
    required bool isArmed,
  }) {
    if (isBusy) {
      return role == RemoteInputRuntimeRole.source
          ? '键鼠共享：正在连接对端'
          : '键鼠共享：正在准备接收控制';
    }
    if (isArmed) {
      return '键鼠共享：边缘穿越已启用，点击停止';
    }
    if (isActive) {
      return role == RemoteInputRuntimeRole.source
          ? '键鼠共享：正在控制对端，点击停止'
          : '键鼠共享：正在接收控制，点击停止';
    }
    return '启用键鼠共享';
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
    final shouldReconnectAfterPicker = _isConnectedSession;
    _pickerReconnectPending = shouldReconnectAfterPicker;
    if (_isConnectedSession) {
      await socketManager.refreshConnectionLiveness();
    }
    setState(() {
      _isLoading = true;
    });
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null) {
        return;
      }
      if (shouldReconnectAfterPicker) {
        final restored = await _restoreConnectionIfNeeded();
        if (!restored) {
          if (mounted) {
            showAppToast(
              AppLocalizations.of(context)?.connectFailed ??
                  'Connection Failed',
            );
          }
          return;
        }
      }
      for (final item in result.files) {
        if (item.path == null || item.path!.isEmpty) {
          continue;
        }
        await socketManager.sendFile(item.path!);
      }
    } catch (error, stackTrace) {
      logger.e('pick files failed', error: error, stackTrace: stackTrace);
      if (mounted) {
        showAppToast(
          AppLocalizations.of(context)?.filePickerOpenFailed ??
              'Unable to open the file picker',
        );
      }
    } finally {
      _pickerReconnectPending = false;
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

  Future<bool> _connectServer(String host, int port) async {
    if (await isLocalhost(host)) {
      afterAuth(true, device);
      return true;
    }
    final completer = Completer<bool>();
    socketManager.connectToServer(host, port, (ok, message) {
      if (!ok) {
        if (!completer.isCompleted) {
          completer.complete(false);
        }
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
        return;
      }
      if (!completer.isCompleted) {
        completer.complete(true);
      }
    });
    return completer.future;
  }

  Future<bool> _restoreConnectionIfNeeded() async {
    if (_isConnectedSession) {
      return true;
    }
    if (!_canToggleConnection) {
      return false;
    }
    final connected = await _connectServer(device.host, device.port);
    if (!connected) {
      return false;
    }
    for (var i = 0; i < 20; i++) {
      if (!mounted) {
        return false;
      }
      if (_isConnectedSession || socketManager.receiver == device.uid) {
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return _isConnectedSession;
  }

  Future<void> _toggleAudioShare() async {
    if (!_isConnectedSession || _isLocalhost) {
      return;
    }
    final audioState = _audioCoordinator.state;
    final isCurrentAudioSession = audioState.isForPeer(device.uid);
    try {
      if (isCurrentAudioSession) {
        final role = audioState.role;
        await _audioCoordinator.stopSharing(
          sendControl: socketManager.sendAudioControl,
        );
        if (mounted) {
          showAppToast(
            role == AudioShareRuntimeRole.sink ? '已停止播放共享声音' : '已停止共享声音',
          );
        }
        return;
      }
      if (!supportsNativeRemoteInput()) {
        showAppToast('当前设备只能作为扬声器播放端');
        return;
      }
      final self = this.self ?? await LocalSetting().instance();
      await _audioCoordinator.startSharingToConnectedPeer(
        sourcePeerId: self.uid,
        sinkPeerId: device.uid,
        sinkHost: device.host,
        sinkPort: device.port,
        sendControl: socketManager.sendAudioControl,
      );
      if (mounted) {
        showAppToast('正在请求对端播放本机声音');
      }
    } catch (error, stackTrace) {
      logger.e('audio share toggle failed',
          error: error, stackTrace: stackTrace);
      if (mounted) {
        showAppToast('共享声音失败：$error');
      }
    }
  }

  Future<void> _toggleRemoteInput({bool showToast = true}) async {
    if (!_isConnectedSession || _isLocalhost) {
      return;
    }
    final inputState = _remoteInputCoordinator.state;
    final isCurrentInputSession = inputState.isForPeer(device.uid);
    try {
      if (isCurrentInputSession) {
        await _remoteInputCoordinator.stopSharing(
          sendControl: socketManager.sendRemoteInputControl,
        );
        if (mounted && showToast) {
          showAppToast('已停止键鼠共享');
        }
        return;
      }
      if (!isDesktop()) {
        if (showToast) {
          showAppToast('当前设备不支持键鼠共享');
        }
        return;
      }
      if (!socketManager.supportsRemoteInput) {
        if (showToast) {
          showAppToast('当前连接设备不支持键鼠共享');
        }
        return;
      }
      final self = this.self ?? await LocalSetting().instance();
      final storedDevice = await LocalDatabase().fetchDevice(device.uid);
      if (storedDevice?.auth != true) {
        if (showToast) {
          showAppToast('键鼠共享需要互信设备');
        }
        return;
      }
      final layout = await _remoteInputLayoutForCurrentPeer();
      final edge = RemoteInputLayoutGeometry.adjacentEdge(
        local: const RemoteInputScreenRect(
          x: 0,
          y: 0,
          width: 1000,
          height: 800,
        ),
        peer: RemoteInputScreenRect(
          x: layout.x,
          y: layout.y,
          width: layout.width,
          height: layout.height,
        ),
      );
      if (edge == null) {
        if (showToast) {
          showAppToast('请先在设备设置里把对端屏幕贴到本机边缘');
        }
        return;
      }
      await _remoteInputCoordinator.startSharingToConnectedPeer(
        sourcePeerId: self.uid,
        sinkPeerId: device.uid,
        sinkHost: device.host,
        sinkPort: device.port,
        layoutEdge: edge,
        releaseHotkey: layout.releaseHotkey,
        isMutuallyTrusted: true,
        remoteCanInject: true,
        sendControl: socketManager.sendRemoteInputControl,
      );
      if (mounted && showToast) {
        showAppToast('键鼠共享已启用，移动到屏幕边缘开始控制对端');
      }
    } catch (error, stackTrace) {
      logger.e('remote input toggle failed',
          error: error, stackTrace: stackTrace);
      if (mounted && showToast) {
        showAppToast('键鼠共享失败：$error');
      }
    }
  }

  Future<void> _maybeAutoStartRemoteInput() async {
    if (!mounted ||
        !_isConnectedSession ||
        _isLocalhost ||
        !supportsNativeRemoteInput()) {
      return;
    }
    if (_remoteInputCoordinator.state.isForPeer(device.uid)) {
      return;
    }
    final layout = await LocalDatabase().fetchRemoteInputLayout(device.uid);
    if (!mounted ||
        layout?.autoActivate != true ||
        layout?.autoRoleValue != RemoteInputAutoRole.source) {
      return;
    }
    await _toggleRemoteInput(showToast: false);
  }

  Future<RemoteInputLayoutData> _remoteInputLayoutForCurrentPeer() async {
    final saved = await LocalDatabase().fetchRemoteInputLayout(device.uid);
    if (saved != null) {
      return saved;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final layout = RemoteInputLayoutData(
      peerId: device.uid,
      peerName: device.name,
      x: 1000,
      y: 0,
      width: 900,
      height: 600,
      enabled: true,
      autoActivate: false,
      autoRole: RemoteInputAutoRole.source.name,
      edgeThresholdPx: 6,
      releaseHotkey: 'ctrl+alt+esc',
      updatedAt: now,
    );
    await LocalDatabase().upsertRemoteInputLayout(layout);
    return layout;
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
      screenWidth *= 0.6;
    } else {
      screenWidth *= 0.78;
    }
    var content = messageData.content ?? "";
    if (messageData.type == MessageEnum.Notification) {
      var data = jsonDecode(messageData.content ?? "{}");
      content = "【${data['app']}】${data['title']}\n${data['text']}";
    }
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final receivedBubbleColor = palette.messageIncoming;
    final receivedBorderColor = palette.borderSubtle;
    final sentBubbleColor = palette.messageOutgoing;

    return Container(
      alignment: isOpponent ? Alignment.centerLeft : Alignment.centerRight,
      constraints: BoxConstraints(maxWidth: screenWidth),
      padding:
          EdgeInsets.fromLTRB(isOpponent ? 2 : 18, 2, isOpponent ? 18 : 2, 2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isOpponent ? receivedBubbleColor : sentBubbleColor,
          borderRadius: BorderRadius.circular(18),
          border: isOpponent
              ? Border.all(
                  color: receivedBorderColor,
                )
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: SelectableText(
            content,
            style: TextStyle(
              color: colorScheme.onSurface,
              fontSize: isDesktop() ? 17 : 16.5,
              height: 1.55,
            ),
            textAlign: TextAlign.left,
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
    final transfer = _transferForMessage(message);
    final isActiveTransfer = transfer != null &&
        !_isTransferTerminal(transfer.state) &&
        transfer.state != FileTransferState.queued;
    final missingLocalFile = isOpponent &&
        message.path.isNotEmpty &&
        (transfer == null || transfer.state == FileTransferState.completed) &&
        !File(message.path).existsSync();
    var failed = !isOpponent &&
        !_isConnectedSession &&
        transfer == null &&
        !message.acked &&
        message.timestamp < device.lastTime;
    failed = failed ||
        missingLocalFile ||
        (transfer != null &&
            (transfer.state == FileTransferState.failed ||
                transfer.state == FileTransferState.canceled));
    final showRetry = transfer != null &&
        (transfer.state == FileTransferState.failed ||
            transfer.state == FileTransferState.paused ||
            transfer.state == FileTransferState.waitingReconnect);
    final showCancel = transfer != null && !_isTransferTerminal(transfer.state);
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final cardColor =
        isOpponent ? palette.messageIncoming : palette.messageOutgoing;
    final cardBorderColor = palette.borderSubtle;

    return Container(
      width: screenWidth,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cardBorderColor),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failed || isActiveTransfer) const SizedBox(width: 8),
            if (failed)
              const Icon(
                Icons.error_outline_rounded,
                color: Colors.redAccent,
                size: 24,
              )
            else if (isActiveTransfer)
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  value: transfer.progress.clamp(0, 1),
                  strokeWidth: 2.4,
                  color: colorScheme.primary,
                  backgroundColor: colorScheme.primary.withValues(alpha: 0.18),
                ),
              )
            else
              Icon(
                Icons.insert_drive_file,
                color: colorScheme.primary.withValues(alpha: 0.86),
                size: 34,
              ),
            if (failed || isActiveTransfer) const SizedBox(width: 8),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: screenWidth - 80,
                    child: Text(
                      message.name,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                      maxLines: 4,
                      softWrap: true,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _fileStatusText(message, transfer),
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (showRetry)
              IconButton(
                tooltip: '重试',
                onPressed: () => _retryTransfer(message.uuid),
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            if (showCancel)
              IconButton(
                tooltip: '取消',
                onPressed: () => _cancelTransfer(message.uuid),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
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
    stopAndroidBackgroundKeepAlive();
    _refreshCurrentDeviceState();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void onConnect() {
    _refreshCurrentDeviceState();
    _syncAndroidKeepAliveService();
    unawaited(_maybeAutoStartRemoteInput());
  }

  var _isAlert = false;

  @override
  void onError(String message) {
    if (_isAlert || !_isCurrentRoute) {
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
  void onNotice(String message) {
    if (!_isCurrentRoute) {
      return;
    }
    showAppToast(message);
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
    unawaited(_maybeAutoStartRemoteInput());
  }

  @override
  void onMessage(MessageData messageData) {
    logger.i("收到消息: ${messageData.type} content: ${messageData.content}");
    if (_isLocalhost && messageData.receiver.isEmpty ||
        device.uid == socketManager.receiver &&
            (messageData.sender == device.uid ||
                messageData.receiver == device.uid)) {
      _insertItem(0, messageData);
      unawaited(_loadTransferSnapshotsForMessages(<MessageData>[messageData]));
    }
  }

  @override
  void onProgress(int size, length) {
    if (device.uid != socketManager.receiver) {
      return;
    }
    // TODO: implement onProgress
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastUpdateTime >= _transferUiSpeedRefreshMs) {
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

  @override
  void onTransferUpdated(TransferSnapshot snapshot) {
    if (snapshot.peerUid != device.uid) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_activeTransferId == snapshot.transferId &&
        now - _lastUpdateTime >= _transferUiSpeedRefreshMs &&
        snapshot.state == FileTransferState.transferring) {
      if (_lastUpdateTime > 0) {
        final speed = formatSize(
          1000 *
              (snapshot.committedBytes - _sentSize) ~/
              (now - _lastUpdateTime),
        );
        _speed = '$speed/s ';
      }
      _lastUpdateTime = now;
      _sentSize = snapshot.committedBytes;
    } else if (_activeTransferId != snapshot.transferId) {
      _lastUpdateTime = now;
      _sentSize = snapshot.committedBytes;
    }

    if (_isTransferTerminal(snapshot.state)) {
      if (_activeTransferId == snapshot.transferId) {
        _activeTransferId = null;
        percent = 0;
        _speed = '';
        _lastUpdateTime = 0;
        _sentSize = 0;
      }
    } else {
      _activeTransferId = snapshot.transferId;
      percent = snapshot.progress.clamp(0, 1);
    }

    if (mounted) {
      setState(() {
        _transferSnapshots[snapshot.transferId] = snapshot;
      });
    }
  }
}
