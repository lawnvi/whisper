import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/global.dart';
import 'package:whisper/helper/android_background.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/whisper_file_picker.dart';
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
import 'package:whisper/widget/desktop_file_drag_source.dart';

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

DeviceData resolveConversationDeviceSnapshot({
  required DeviceData localDevice,
  required DeviceData selectedDevice,
  required DeviceData? storedDevice,
}) {
  if (localDevice.uid == selectedDevice.uid) {
    return localDevice;
  }
  return storedDevice ?? selectedDevice;
}

class _SendMessageScreen extends State<SendMessageScreen>
    with WidgetsBindingObserver
    implements ISocketEvent {
  static const int _transferUiSpeedRefreshMs = 300;
  static const Duration _transferProgressAnimationDuration =
      Duration(milliseconds: 180);

  final db = LocalDatabase();
  final socketManager = WsSvrManager();
  final AudioShareCoordinator _audioCoordinator = AudioShareCoordinator.shared;
  final AudioGroupCoordinator _audioGroupCoordinator =
      AudioGroupCoordinator.shared;
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

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  Future<void> _syncAndroidKeepAliveService() async {
    if (!Platform.isAndroid || !mounted) {
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
    if (!mounted) {
      return;
    }
    final notification = _buildAndroidKeepAliveNotification();
    await startAndroidBackgroundKeepAlive(
      title: notification.title,
      description: notification.description,
      progress: notification.progress,
      indeterminateProgress: notification.indeterminateProgress,
    );
  }

  AndroidKeepAliveNotification _buildAndroidKeepAliveNotification() {
    final activeTransfer = _activeTransferId == null
        ? null
        : _transferSnapshots[_activeTransferId!];
    final title = l10n.androidBackgroundKeepAliveActiveTitle;
    if (activeTransfer != null && !_isTransferTerminal(activeTransfer.state)) {
      final progress = (activeTransfer.progress * 100).round().clamp(0, 100);
      final progressText = progress.toString();
      return AndroidKeepAliveNotification(
        title: title,
        description: activeTransfer.direction == FileTransferDirection.outgoing
            ? l10n.androidBackgroundKeepAliveTransferSending(progressText)
            : l10n.androidBackgroundKeepAliveTransferReceiving(progressText),
        progress: progress,
        indeterminateProgress:
            activeTransfer.state != FileTransferState.transferring,
      );
    }

    if (percent > 0 && percent < 1) {
      final progress = (percent * 100).round().clamp(0, 100);
      return AndroidKeepAliveNotification(
        title: title,
        description:
            l10n.androidBackgroundKeepAliveTransferSending(progress.toString()),
        progress: progress,
      );
    }

    final audioState = _audioCoordinator.state;
    if (audioState.isForPeer(device.uid) &&
        audioState.status != AudioShareRuntimeStatus.idle &&
        audioState.status != AudioShareRuntimeStatus.failed) {
      if (audioState.isBusy) {
        return AndroidKeepAliveNotification(
          title: title,
          description: l10n.androidBackgroundKeepAliveAudioPreparing,
          indeterminateProgress: true,
        );
      }
      return AndroidKeepAliveNotification(
        title: title,
        description: audioState.role == AudioShareRuntimeRole.source
            ? l10n.androidBackgroundKeepAliveAudioSharing
            : l10n.androidBackgroundKeepAliveAudioPlaying,
      );
    }

    return AndroidKeepAliveNotification(
      title: title,
      description: l10n.androidBackgroundKeepAliveActiveDesc,
    );
  }

  _SendMessageScreen(this.device, this.embedded);

  void _traceRemoteInput(String message) {
    logger.i(message);
    if (!kReleaseMode ||
        Platform.environment['WHISPER_REMOTE_INPUT_TRACE'] == '1') {
      debugPrint(message);
    }
  }

  @override
  void initState() {
    logger.i("init conv: ${socketManager.receiver}-${device.uid}");
    WidgetsBinding.instance.addObserver(this);
    socketManager.registerEvent(this);
    _audioCoordinator.addListener(_handleAudioShareChanged);
    _audioGroupCoordinator.addListener(_handleAudioGroupChanged);
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
    _audioGroupCoordinator.removeListener(_handleAudioGroupChanged);
    _remoteInputCoordinator.removeListener(_handleRemoteInputChanged);
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    _composerFocusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _handleAudioShareChanged() {
    unawaited(_syncAndroidKeepAliveService());
    if (mounted) {
      setState(() {});
    }
  }

  void _handleAudioGroupChanged() {
    unawaited(_syncAndroidKeepAliveService());
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
    unawaited(_syncAndroidKeepAliveService());
  }

  Widget _buildAnimatedTransferProgress({
    required double value,
    required Widget Function(BuildContext context, double value) builder,
  }) {
    final target = value.clamp(0, 1).toDouble();
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: target),
      duration: _transferProgressAnimationDuration,
      curve: Curves.easeOutCubic,
      builder: (context, animatedValue, child) {
        return builder(context, animatedValue.clamp(0, 1).toDouble());
      },
    );
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
    final me = await LocalSetting().instance();
    final storedDevice =
        me.uid == device.uid ? null : await db.fetchDevice(device.uid);
    final currentDevice = resolveConversationDeviceSnapshot(
      localDevice: me,
      selectedDevice: device,
      storedDevice: storedDevice,
    );
    final isLocal = me.uid == currentDevice.uid;
    final arr = await db.fetchMessageList(
      isLocal ? "" : currentDevice.uid,
      limit: 20,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      self = me;
      device = currentDevice;
      _isLocalhost = isLocal;
      // messageList = arr;
    });

    _insertItems(0, arr);
    unawaited(_loadTransferSnapshotsForMessages(arr));

    _scrollController.addListener(_scrollListener);

    // 开启通知监听
    if (Platform.isAndroid &&
        !isLocal &&
        socketManager.isConnectedTo(currentDevice.uid) &&
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
    final existingIndex = item.uuid.isEmpty
        ? -1
        : messageList.indexWhere((message) => message.uuid == item.uuid);
    if (existingIndex >= 0) {
      setState(() {
        messageList[existingIndex] = item;
      });
      return;
    }
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

  bool _canDragFileMessage(
    MessageData message,
    TransferSnapshot? transfer,
  ) {
    if (!isDesktop() ||
        message.path.isEmpty ||
        !File(message.path).existsSync()) {
      return false;
    }
    return transfer == null || transfer.state == FileTransferState.completed;
  }

  String _fileStatusText(
    MessageData message,
    TransferSnapshot? transfer, {
    double? progressOverride,
  }) {
    if (transfer == null) {
      if (_isConnectedSession &&
          !socketManager.supportsResumableTransfer &&
          !message.acked) {
        return l10n.fileTransferLegacyInProgress;
      }
      return formatSize(message.size);
    }
    final progress = progressOverride ?? transfer.progress;
    switch (transfer.state) {
      case FileTransferState.queued:
        return l10n.fileTransferQueued;
      case FileTransferState.negotiating:
        return transfer.committedBytes > 0
            ? l10n.fileTransferPreparingResume(
                (progress * 100).toStringAsFixed(0),
              )
            : l10n.fileTransferNegotiating;
      case FileTransferState.transferring:
        return '${formatSize(message.size)}  ${(progress * 100).toStringAsFixed(0)}%';
      case FileTransferState.waitingReconnect:
        return l10n.fileTransferWaitingReconnect(
          (progress * 100).toStringAsFixed(0),
        );
      case FileTransferState.paused:
        return l10n.fileTransferPaused;
      case FileTransferState.verifying:
        return l10n.fileTransferVerifying;
      case FileTransferState.completed:
        return formatSize(message.size);
      case FileTransferState.failed:
        return transfer.lastError.isEmpty
            ? l10n.fileTransferFailedRetryable
            : transfer.lastError;
      case FileTransferState.canceled:
        return l10n.fileTransferCanceled;
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

  Future<void> _deleteMessageFileIfExists(MessageData message) async {
    final path = message.path;
    if (path.isEmpty) {
      return;
    }
    final file = File(path);
    if (!await file.exists()) {
      logger.i("skip delete missing file $path");
      return;
    }
    try {
      logger.i("delete $path");
      await file.delete();
    } on FileSystemException catch (error) {
      if (!await file.exists()) {
        logger.i("skip delete missing file $path after delete error: $error");
        return;
      }
      rethrow;
    }
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
          _buildAnimatedTransferProgress(
            value: percent,
            builder: (context, value) => LinearProgressIndicator(
              value: value,
              color: Colors.lightGreen,
            ),
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
              if (deleteFile) {
                await _deleteMessageFileIfExists(message);
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
          await socketManager.sendFileTo(device.uid, item.path);
        }
      },
      onDragEntered: (detail) {},
      onDragExited: (detail) {},
      child: base,
    );
  }

  bool get _canSendCurrentDevice {
    return _isLocalhost || socketManager.isConnectedTo(device.uid);
  }

  bool get _isConnectedSession {
    return socketManager.isConnectedTo(device.uid);
  }

  bool get _canToggleConnection {
    return _isLocalhost ||
        _isConnectedSession ||
        device.around == true ||
        device.host.isNotEmpty;
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
          child: _buildAnimatedTransferProgress(
            value: percent,
            builder: (context, value) => Column(
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
                  "${(100 * value).toStringAsFixed(2)}%",
                  style: TextStyle(
                    fontSize: 12,
                    color: palette.textMuted,
                  ),
                ),
              ],
            ),
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
          tooltip: l10n.peerDoesNotSupportResumableTransfer,
          icon: Icon(
            Icons.history_toggle_off_rounded,
            color: palette.textMuted,
          ),
          onPressed: () {
            showAppToast(l10n.connectedPeerDoesNotSupportResumableTransfer);
          },
        ),
      );
    }
    if (_shouldShowAudioShareAction) {
      final audioState = _audioCoordinator.state;
      final audioGroupSession = _audioGroupCoordinator.session;
      final isCurrentAudioSession = audioState.isForPeer(device.uid);
      final isCurrentAudioGroup =
          _audioGroupCoordinator.isForPeer(device.uid) &&
              audioGroupSession?.isLive == true;
      final isActive =
          (isCurrentAudioSession && audioState.isActive) || isCurrentAudioGroup;
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
          tooltip: isCurrentAudioGroup
              ? l10n.audioShareCaptureActiveStop
              : _audioShareTooltip(
                  role,
                  isActive: isActive,
                  isBusy: isBusy,
                ),
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
    final audioGroupSession = _audioGroupCoordinator.session;
    final isCurrentAudioGroup = _audioGroupCoordinator.isForPeer(device.uid) &&
        audioGroupSession?.isLive == true;
    return !_isLocalhost &&
        _isConnectedSession &&
        !isDesktop() &&
        (audioState.isForPeer(device.uid) || isCurrentAudioGroup);
  }

  bool get _shouldShowRemoteInputAction {
    return !_isLocalhost &&
        _isConnectedSession &&
        !widget.embedded &&
        isDesktop() &&
        supportsNativeRemoteInput() &&
        socketManager.supportsRemoteInputFor(device.uid);
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
          ? l10n.audioShareCaptureConnecting
          : l10n.audioSharePlaybackPreparing;
    }
    if (isActive) {
      return role == AudioShareRuntimeRole.source
          ? l10n.audioShareCaptureActiveStop
          : l10n.audioSharePlaybackActiveStop;
    }
    return l10n.audioShareStart;
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
          ? l10n.remoteInputSourceConnecting
          : l10n.remoteInputSinkConnecting;
    }
    if (isArmed) {
      return l10n.remoteInputEdgeActiveStop;
    }
    if (isActive) {
      return role == RemoteInputRuntimeRole.source
          ? l10n.remoteInputSourceActiveStop
          : l10n.remoteInputSinkActiveStop;
    }
    return l10n.remoteInputStart;
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
      final result = await WhisperFilePicker.pickFiles(allowMultiple: true);
      if (result.isEmpty) {
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
      for (final item in result) {
        await socketManager.sendPickedFileTo(device.uid, item);
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
        onConfirm: () async {
          await socketManager.disconnectPeer(device.uid);
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
        if (message == WsSvrManager.duplicateAuthRequestMessage) {
          if (mounted) {
            showAppToast(message.toString());
          }
          return;
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
    }, peerId: device.uid);
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
      if (_isConnectedSession || socketManager.isConnectedTo(device.uid)) {
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
    final l10n = this.l10n;
    final audioState = _audioCoordinator.state;
    final isCurrentAudioSession = audioState.isForPeer(device.uid);
    final audioGroupSession = _audioGroupCoordinator.session;
    final isCurrentAudioGroup = _audioGroupCoordinator.isForPeer(device.uid) &&
        audioGroupSession?.isLive == true;
    try {
      if (isCurrentAudioGroup) {
        await _audioGroupCoordinator.stopGroup(
          sendControl: socketManager.sendAudioGroupControlTo,
        );
        if (mounted) {
          showAppToast(l10n.audioShareCaptureStopped);
        }
        return;
      }
      if (isCurrentAudioSession) {
        final role = audioState.role;
        await _audioCoordinator.stopSharing(
          sendControl: socketManager.sendAudioControl,
        );
        if (mounted) {
          showAppToast(
            role == AudioShareRuntimeRole.sink
                ? l10n.audioSharePlaybackStopped
                : l10n.audioShareCaptureStopped,
          );
        }
        return;
      }
      if (!supportsNativeSystemAudio()) {
        showAppToast(l10n.audioShareUnsupportedCapture);
        return;
      }
      final self = this.self ?? await LocalSetting().instance();
      final groupCandidates = socketManager.connectedAudioGroupSinkDevices(
        preferredPeerId: device.uid,
      );
      if (socketManager.supportsAudioGroupSinkFor(device.uid) &&
          groupCandidates.isNotEmpty) {
        final Map<String, AudioChannelRole> sinks;
        if (groupCandidates.length == 1) {
          sinks = <String, AudioChannelRole>{
            device.uid: AudioChannelRole.stereo,
          };
        } else {
          final selectedSinks =
              await _showAudioGroupSetupSheet(groupCandidates);
          if (selectedSinks == null) {
            return;
          }
          if (selectedSinks.isEmpty) {
            showAppToast(l10n.audioGroupSelectAtLeastOne);
            return;
          }
          sinks = selectedSinks;
        }
        _audioGroupCoordinator.startGroup(
          sourcePeerId: self.uid,
          sinks: sinks,
          format: AudioShareCoordinator.defaultFormat,
          sendControl: socketManager.sendAudioGroupControlTo,
        );
        if (mounted) {
          showAppToast(l10n.audioGroupRequestingPlayback);
        }
        return;
      }
      await _audioCoordinator.startSharingToConnectedPeer(
        sourcePeerId: self.uid,
        sinkPeerId: device.uid,
        sinkHost: device.host,
        sinkPort: device.port,
        sendControl: socketManager.sendAudioControl,
      );
      if (mounted) {
        showAppToast(l10n.audioShareRequestingPlayback);
      }
    } catch (error, stackTrace) {
      logger.e('audio share toggle failed',
          error: error, stackTrace: stackTrace);
      if (mounted) {
        showAppToast(l10n.audioShareFailed(error.toString()));
      }
    }
  }

  Future<Map<String, AudioChannelRole>?> _showAudioGroupSetupSheet(
    List<DeviceData> candidates,
  ) {
    final selected = <String, bool>{
      for (final candidate in candidates)
        candidate.uid: candidate.uid == device.uid,
    };
    final roles = <String, AudioChannelRole>{
      for (var index = 0; index < candidates.length; index++)
        candidates[index].uid: index == 0
            ? AudioChannelRole.left
            : (index == 1 ? AudioChannelRole.right : AudioChannelRole.stereo),
    };
    return showModalBottomSheet<Map<String, AudioChannelRole>>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final selectedCount =
                selected.values.where((value) => value).length;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.audioGroupSelectSinks,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: candidates.length,
                        itemBuilder: (context, index) {
                          final candidate = candidates[index];
                          final isSelected = selected[candidate.uid] ?? false;
                          return CheckboxListTile(
                            value: isSelected,
                            onChanged: (value) {
                              setSheetState(() {
                                selected[candidate.uid] = value ?? false;
                              });
                            },
                            title: Text(candidate.name),
                            subtitle: Text(candidate.platform),
                            secondary: DropdownButton<AudioChannelRole>(
                              value: roles[candidate.uid],
                              underline: const SizedBox.shrink(),
                              onChanged: isSelected
                                  ? (role) {
                                      if (role == null) {
                                        return;
                                      }
                                      setSheetState(() {
                                        roles[candidate.uid] = role;
                                      });
                                    }
                                  : null,
                              items: AudioChannelRole.values
                                  .map(
                                    (role) => DropdownMenuItem(
                                      value: role,
                                      child: Text(_audioGroupRoleLabel(role)),
                                    ),
                                  )
                                  .toList(growable: false),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: selectedCount == 0
                          ? null
                          : () {
                              Navigator.of(context).pop(
                                <String, AudioChannelRole>{
                                  for (final candidate in candidates)
                                    if (selected[candidate.uid] == true)
                                      candidate.uid: roles[candidate.uid] ??
                                          AudioChannelRole.stereo,
                                },
                              );
                            },
                      icon: const Icon(Icons.spatial_audio_off_rounded),
                      label: Text(
                        selectedCount > 1
                            ? l10n.audioGroupStart
                            : l10n.audioShareStart,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _audioGroupRoleLabel(AudioChannelRole role) {
    switch (role) {
      case AudioChannelRole.stereo:
        return l10n.audioGroupRoleStereo;
      case AudioChannelRole.mono:
        return l10n.audioGroupRoleMono;
      case AudioChannelRole.left:
        return l10n.audioGroupRoleLeft;
      case AudioChannelRole.right:
        return l10n.audioGroupRoleRight;
    }
  }

  Future<void> _toggleRemoteInput({bool showToast = true}) async {
    if (!_isConnectedSession || _isLocalhost) {
      _traceRemoteInput(
        'remote input toggle ignored connected=$_isConnectedSession '
        'localhost=$_isLocalhost peer=${device.uid}',
      );
      return;
    }
    final l10n = this.l10n;
    final inputState = _remoteInputCoordinator.state;
    final isCurrentInputSession = inputState.isForPeer(device.uid);
    _traceRemoteInput(
      'remote input toggle requested peer=${device.uid} '
      'showToast=$showToast '
      'state=${inputState.role.name}/${inputState.status.name} '
      'stateSession=${inputState.sessionId} '
      'isCurrent=$isCurrentInputSession '
      'supportsNative=${supportsNativeRemoteInput()} '
      'remoteSupports=${socketManager.supportsRemoteInputFor(device.uid)}',
    );
    try {
      if (isCurrentInputSession) {
        _traceRemoteInput(
            'remote input toggle stopping current session peer=${device.uid}');
        await _remoteInputCoordinator.stopSharing(
          sendControl: socketManager.sendRemoteInputControl,
        );
        if (mounted && showToast) {
          showAppToast(l10n.remoteInputStopped);
        }
        return;
      }
      if (inputState.status != RemoteInputRuntimeStatus.idle &&
          inputState.status != RemoteInputRuntimeStatus.failed) {
        _traceRemoteInput(
          'remote input toggle blocked: another session is active '
          'peer=${inputState.peerId} session=${inputState.sessionId}',
        );
        if (showToast) {
          showAppToast(l10n.remoteInputStopCurrentFirst);
        }
        return;
      }
      if (!isDesktop()) {
        _traceRemoteInput(
            'remote input toggle blocked: local platform is not desktop');
        if (showToast) {
          showAppToast(l10n.remoteInputLocalUnsupported);
        }
        return;
      }
      final self = this.self ?? await LocalSetting().instance();
      final storedDevice = await LocalDatabase().fetchDevice(device.uid);
      final localTrustsRemote = storedDevice?.auth == true;
      final remoteTrustsLocal =
          socketManager.remotePeerTrustsPeer(device.uid, self.uid);
      final isMutuallyTrusted = localTrustsRemote && remoteTrustsLocal;
      if (!localTrustsRemote) {
        _traceRemoteInput(
          'remote input toggle blocked: stored auth missing peer=${device.uid}',
        );
        if (showToast) {
          showAppToast(l10n.remoteInputRequiresMutualTrust);
        }
        return;
      }
      if (!remoteTrustsLocal) {
        _traceRemoteInput(
          'remote input toggle blocked: remote peer does not trust local '
          'peer=${device.uid} self=${self.uid}',
        );
        if (showToast) {
          showAppToast(l10n.remoteInputPeerMustTrustThisDevice);
        }
        return;
      }
      if (!socketManager.supportsRemoteInputFor(device.uid)) {
        _traceRemoteInput(
            'remote input toggle blocked: remote peer lacks capability');
        if (showToast) {
          showAppToast(l10n.remoteInputPeerUnsupported);
        }
        return;
      }
      final layout = await _remoteInputLayoutForCurrentPeer();
      final topologyLayout = layout.savedLayout;
      RemoteInputResolvedLayout? resolvedTopologyLayout;
      if (topologyLayout != null &&
          socketManager.supportsRemoteInputTopologyFor(device.uid)) {
        final remoteTopology = socketManager.remoteDisplayTopologyFor(
          device.uid,
        );
        if (remoteTopology != null) {
          final localTopology =
              await RemoteInputCoordinator.shared.displayTopology();
          resolvedTopologyLayout = RemoteInputLayoutGeometry.resolveSavedLayout(
            savedLayout: topologyLayout,
            sourceTopology: localTopology,
            sinkTopology: remoteTopology,
            edgeTolerance: layout.edgeThresholdPx,
          );
        }
      }
      final legacyEdge = RemoteInputLayoutGeometry.adjacentEdge(
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
      final edge =
          resolvedTopologyLayout?.sharedSegment.sourceEdge ?? legacyEdge;
      if (edge == null) {
        _traceRemoteInput(
          'remote input toggle blocked: no adjacent edge peer=${device.uid} '
          'layout=${layout.x},${layout.y},${layout.width},${layout.height}',
        );
        if (showToast) {
          showAppToast(l10n.remoteInputLayoutRequired);
        }
        return;
      }
      final topologyMappings = resolvedTopologyLayout?.edgeMappings ??
          const <RemoteInputEdgeMapping>[];
      final sourceSegmentStart = topologyMappings.isEmpty
          ? resolvedTopologyLayout?.sharedSegment.start ?? 0
          : topologyMappings
              .map((mapping) => mapping.sourceSegmentStart)
              .reduce(min);
      final sourceSegmentEnd = topologyMappings.isEmpty
          ? resolvedTopologyLayout?.sharedSegment.end ?? 0
          : topologyMappings
              .map((mapping) => mapping.sourceSegmentEnd)
              .reduce(max);
      _traceRemoteInput(
        'remote input toggle starting peer=${device.uid} '
        'self=${self.uid} edge=${edge.name} '
        'mappings=${topologyMappings.length} '
        'host=${device.host}:${device.port}',
      );
      await _remoteInputCoordinator.startSharingToConnectedPeer(
        sourcePeerId: self.uid,
        sinkPeerId: device.uid,
        sinkHost: device.host,
        sinkPort: device.port,
        layoutEdge: resolvedTopologyLayout?.sharedSegment.sourceEdge ?? edge,
        releaseHotkey: layout.releaseHotkey,
        isMutuallyTrusted: isMutuallyTrusted,
        remoteCanInject: socketManager.supportsRemoteInputFor(device.uid),
        sendControl: socketManager.sendRemoteInputControl,
        sourceDisplayId: resolvedTopologyLayout?.sourceDisplay.displayId ?? '',
        sourceEdge: resolvedTopologyLayout?.sharedSegment.sourceEdge,
        sourceSegmentStart: sourceSegmentStart,
        sourceSegmentEnd: sourceSegmentEnd,
        sinkDisplayId: resolvedTopologyLayout?.sinkDisplay.displayId ?? '',
        sinkEdge: resolvedTopologyLayout?.sharedSegment.sinkEdge,
        sinkSegmentStart: resolvedTopologyLayout?.sinkSegmentStart ?? 0,
        sinkSegmentEnd: resolvedTopologyLayout?.sinkSegmentEnd ?? 0,
        edgeMappings: topologyMappings,
      );
      if (mounted && showToast) {
        showAppToast(l10n.remoteInputEnabledMoveToEdge);
      }
    } catch (error, stackTrace) {
      logger.e('remote input toggle failed',
          error: error, stackTrace: stackTrace);
      if (mounted && showToast) {
        showAppToast(l10n.remoteInputFailed(error.toString()));
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
    final inputState = _remoteInputCoordinator.state;
    if (inputState.status != RemoteInputRuntimeStatus.idle &&
        inputState.status != RemoteInputRuntimeStatus.failed) {
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
      layoutVersion: 1,
      layoutJson: '',
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
    } else if (socketManager.isConnectedTo(device.uid)) {
      await socketManager.sendMessageTo(
        device.uid,
        content,
        clipboard: isClipboard,
      );
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
              fontSize: isDesktop() ? 16.5 : 16,
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
    final fileStatusStyle = TextStyle(
      color: colorScheme.onSurfaceVariant,
      fontSize: 12,
    );

    return DesktopFileDragSource(
      path: message.path,
      name: message.name,
      enabled: _canDragFileMessage(message, transfer),
      child: Container(
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
                  child: _buildAnimatedTransferProgress(
                    value: transfer.progress,
                    builder: (context, value) => CircularProgressIndicator(
                      value: value,
                      strokeWidth: 2.4,
                      color: colorScheme.primary,
                      backgroundColor:
                          colorScheme.primary.withValues(alpha: 0.18),
                    ),
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
                    if (isActiveTransfer)
                      _buildAnimatedTransferProgress(
                        value: transfer.progress,
                        builder: (context, value) => Text(
                          _fileStatusText(
                            message,
                            transfer,
                            progressOverride: value,
                          ),
                          style: fileStatusStyle,
                        ),
                      )
                    else
                      Text(
                        _fileStatusText(message, transfer),
                        style: fileStatusStyle,
                      ),
                  ],
                ),
              ),
              if (showRetry)
                IconButton(
                  tooltip: l10n.retry,
                  onPressed: () => _retryTransfer(message.uuid),
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              if (showCancel)
                IconButton(
                  tooltip: l10n.cancel,
                  onPressed: () => _cancelTransfer(message.uuid),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
            ],
          ),
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
        messageData.sender == device.uid ||
        messageData.receiver == device.uid) {
      _insertItem(0, messageData);
      unawaited(_loadTransferSnapshotsForMessages(<MessageData>[messageData]));
    }
  }

  @override
  void onProgress(int size, length) {
    if (!socketManager.isConnectedTo(device.uid)) {
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
    unawaited(_syncAndroidKeepAliveService());
  }
}
