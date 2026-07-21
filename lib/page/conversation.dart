import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/audio/audio_failure_reason.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/helper/android_background.dart';
import 'package:whisper/helper/android_document_picker.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/helper/desktop_window_attention.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/helper/whisper_file_picker.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/page/deviceList.dart';
import 'package:whisper/page/settings.dart' as app_settings;
import 'package:whisper/page/transfer_assistant.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_failure_reason.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/desktop_quick_send_inbox.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/chat_composer.dart';
import 'package:whisper/widget/chat_message_list.dart';
import 'package:whisper/widget/desktop_file_drag_source.dart';
import 'package:whisper/widget/media_message_preview.dart';
import 'package:whisper/widget/pairing_dialog.dart';

import '../helper/file.dart';
import '../helper/helper.dart';

import '../helper/notification.dart';

import 'dart:io' show Platform;

import '../l10n/app_localizations.dart';

enum ConversationOperationKind {
  deleteFile,
  sendDroppedFiles,
  readClipboard,
  sendClipboardFiles,
  sendClipboardImage,
  pickFiles,
  audioToggle,
  remoteInputToggle,
  sendText,
}

enum ConversationRemoteInputDiagnostic { toggleStarted }

void _logConversationFailure(ConversationOperationKind kind, Object error) {
  privacyLog.event(PrivacyEvent.localOperation, <PrivacyField, Object>{
    PrivacyField.kind: kind,
    PrivacyField.success: false,
    PrivacyField.errorType: privacyLog.errorType(error),
  });
}

class SendMessageScreen extends StatefulWidget {
  final DeviceData device;
  final bool embedded;
  final Future<void> Function(String uid)? onDeviceDeleted;

  const SendMessageScreen({
    super.key,
    required this.device,
    this.embedded = false,
    this.onDeviceDeleted,
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
  static const Duration _transferProgressAnimationDuration = Duration(
    milliseconds: 180,
  );

  final db = LocalDatabase();
  final socketManager = WsSvrManager();
  final AudioShareCoordinator _audioCoordinator = AudioShareCoordinator.shared;
  final AudioGroupCoordinator _audioGroupCoordinator =
      AudioGroupCoordinator.shared;
  final RemoteInputCoordinator _remoteInputCoordinator =
      RemoteInputCoordinator.shared;
  final DesktopClipboardImageReader _clipboardImageReader =
      const DesktopClipboardImageReader();
  final DesktopClipboardFileReader _clipboardFileReader =
      const DesktopClipboardFileReader();
  final ConnectionAttemptTracker _connectionAttempts =
      ConnectionAttemptTracker();
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
  bool _composerSendInFlight = false;
  bool _messageSelectionActive = false;
  int _clipboardPasteGeneration = 0;
  List<ClipboardFileDraft> _pendingClipboardFiles =
      const <ClipboardFileDraft>[];
  List<ClipboardImageDraft> _pendingClipboardImages =
      const <ClipboardImageDraft>[];

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
    final coordinator = AndroidBackgroundKeepAliveCoordinator.shared;
    await coordinator.setEnabled(enabled);
    if (!mounted) {
      return;
    }
    final notification = _buildAndroidKeepAliveNotification();
    await coordinator.setReason(
      AndroidKeepAliveReason.activeSession,
      enabled && _isConnectedSession,
      notification: notification,
    );
  }

  AndroidKeepAliveNotification _buildAndroidKeepAliveNotification() {
    return AndroidKeepAliveNotification(
      title: l10n.androidBackgroundKeepAliveActiveTitle,
      description: l10n.androidBackgroundKeepAliveActiveDesc,
    );
  }

  _SendMessageScreen(this.device, this.embedded);

  void _traceRemoteInputStart({
    required bool trusted,
    required int mappingCount,
  }) {
    if (kReleaseMode &&
        Platform.environment['WHISPER_REMOTE_INPUT_TRACE'] != '1') {
      return;
    }
    privacyLog.event(PrivacyEvent.remoteInputDiagnostic, <PrivacyField, Object>{
      PrivacyField.kind: ConversationRemoteInputDiagnostic.toggleStarted,
      PrivacyField.allowed: trusted,
      PrivacyField.count: mappingCount,
    });
  }

  @override
  void initState() {
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
    WidgetsBinding.instance.removeObserver(this);
    _connectionAttempts.cancelAll();
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
        final snapshot = db.snapshotForTransfer(entry.value);
        final current = _transferSnapshots[entry.key];
        if (current != null && current.updatedAt > snapshot.updatedAt) {
          continue;
        }
        _transferSnapshots[entry.key] = snapshot;
        if (snapshot.state == FileTransferState.completed &&
            snapshot.finalPath.isNotEmpty) {
          final messageIndex = messageList.indexWhere(
            (message) => message.uuid == snapshot.messageUuid,
          );
          if (messageIndex >= 0 &&
              messageList[messageIndex].path != snapshot.finalPath) {
            messageList[messageIndex] = messageList[messageIndex].copyWith(
              path: snapshot.finalPath,
            );
          }
        }
      }
    });
  }

  void _loadMessages() async {
    final me = await LocalSetting().instance();
    final storedDevice = me.uid == device.uid
        ? null
        : await db.fetchDevice(device.uid);
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
    final latestDevice = isLocal
        ? me
        : await LocalDatabase().fetchDevice(device.uid);
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
      var arr = await LocalDatabase().fetchMessageList(
        device.uid,
        beforeId: messageList.last.id,
        limit: 12,
      );
      if (arr.isEmpty) {
        return;
      }

      _insertItems(messageList.length, arr);
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
    key.currentState?.insertItem(
      index,
      duration: const Duration(milliseconds: 500),
    );
  }

  _insertItems(index, items) {
    messageList.insertAll(index, items);
    key.currentState?.insertAllItems(
      index,
      items.length,
      duration: const Duration(milliseconds: 500),
    );
  }

  TransferSnapshot? _transferForMessage(MessageData message) {
    return _transferSnapshots[message.uuid];
  }

  String _effectiveMessagePath(
    MessageData message, [
    TransferSnapshot? transfer,
  ]) {
    final snapshot = transfer ?? _transferForMessage(message);
    if (snapshot?.state == FileTransferState.completed &&
        snapshot?.finalPath.isNotEmpty == true) {
      return snapshot!.finalPath;
    }
    return message.path;
  }

  bool _isTransferTerminal(FileTransferState state) {
    return state == FileTransferState.completed ||
        state == FileTransferState.failed ||
        state == FileTransferState.canceled;
  }

  TransferSnapshot? get _activeTransferSnapshot {
    final transferId = _activeTransferId;
    return transferId == null ? null : _transferSnapshots[transferId];
  }

  bool _canDragFileMessage(MessageData message, TransferSnapshot? transfer) {
    final path = _effectiveMessagePath(message, transfer);
    if (!isDesktop() || path.isEmpty || !File(path).existsSync()) {
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
        return l10n.fileTransferFailedRetryable;
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
      return FadeTransition(opacity: animation, child: null);
    }, duration: const Duration(milliseconds: 100));
  }

  Future<void> _deleteMessageFileIfExists(MessageData message) async {
    final path = _effectiveMessagePath(message);
    if (path.isEmpty) {
      return;
    }
    final file = File(path);
    if (!await file.exists()) {
      return;
    }
    try {
      await file.delete();
    } on FileSystemException catch (error) {
      if (!await file.exists()) {
        return;
      }
      _logConversationFailure(ConversationOperationKind.deleteFile, error);
      rethrow;
    }
  }

  Future<void> _deleteItems(Iterable<int> messageIds) async {
    final ids = messageIds.toSet();
    if (ids.isEmpty) {
      return;
    }

    await db.deleteMessages(ids);
    if (!mounted) {
      return;
    }

    final indexes = <int>[
      for (var i = 0; i < messageList.length; i++)
        if (ids.contains(messageList[i].id)) i,
    ]..sort((a, b) => b.compareTo(a));
    if (indexes.isEmpty) {
      return;
    }

    setState(() {
      for (final index in indexes) {
        messageList.removeAt(index);
        key.currentState?.removeItem(
          index,
          (context, animation) => SizeTransition(
            sizeFactor: animation,
            child: const SizedBox.shrink(),
          ),
          duration: const Duration(milliseconds: 220),
        );
      }
    });
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
    final activeTransfer = _activeTransferSnapshot;
    final content = Column(
      children: [
        if (embedded) _buildEmbeddedHeader(isDark),
        if (activeTransfer?.state == FileTransferState.verifying)
          LinearProgressIndicator(
            minHeight: 3,
            color: colorScheme.primary,
            backgroundColor: colorScheme.primary.withValues(alpha: 0.14),
          )
        else if (percent > 0 && percent < 1)
          _buildAnimatedTransferProgress(
            value: percent,
            builder: (context, value) =>
                LinearProgressIndicator(value: value, color: Colors.lightGreen),
          ),
        Expanded(
          child: ChatMessageList(
            buildFileMessage: _buildFileMessage,
            buildTextMessage: _buildTextMessage,
            controller: _scrollController,
            listKey: key,
            messages: messageList,
            onOpenContainingFolder: (path) => openDir(path, parent: true),
            onOpenFile: _openMessageFile,
            onCopyText: copyToClipboard,
            onDeleteMessage: (message, {deleteFile = false}) async {
              if (deleteFile) {
                await _deleteMessageFileIfExists(message);
              }
              await _deleteItems(<int>[message.id]);
            },
            onDeleteMessages: (messages) =>
                _deleteItems(messages.map((message) => message.id)),
            onSelectionModeChanged: (active) {
              if (_messageSelectionActive == active) {
                return;
              }
              setState(() => _messageSelectionActive = active);
            },
            selfUid: self?.uid,
          ),
        ),
        if (!_messageSelectionActive && _canSendCurrentDevice)
          _buildComposer(isDark),
        if (!embedded && !_messageSelectionActive && _canSendCurrentDevice)
          const SizedBox(height: 6),
      ],
    );

    Widget base = embedded
        ? Material(color: colorScheme.surface, child: content)
        : Scaffold(appBar: _buildStandaloneAppBar(isDark), body: content);

    if (isMobile()) {
      return base;
    }

    return DropTarget(
      onDragDone: (detail) => unawaited(_handleFileDrop(detail.files)),
      onDragEntered: (detail) {},
      onDragExited: (detail) {},
      child: base,
    );
  }

  Future<void> _handleFileDrop(List<DropItem> files) async {
    if (files.isEmpty || _isLocalhost || !_canSendCurrentDevice) {
      return;
    }
    try {
      for (final item in files) {
        if (await FileSystemEntity.type(item.path, followLinks: false) !=
            FileSystemEntityType.file) {
          if (mounted) {
            showAppToast(l10n.fileDropRejected);
          }
          return;
        }
        final sent = await socketManager.sendFileTo(device.uid, item.path);
        if (!sent && mounted) {
          showAppToast(l10n.fileDropRejected);
          return;
        }
      }
    } catch (error) {
      _logConversationFailure(
        ConversationOperationKind.sendDroppedFiles,
        error,
      );
      if (mounted) {
        showAppToast(l10n.fileDropRejected);
      }
    }
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
        border: Border(bottom: BorderSide(color: palette.borderSubtle)),
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
            if (_isConnectedSession)
              Icon(Icons.lock_rounded, size: 14, color: palette.trusted)
            else
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: device.around == true ? Colors.green : Colors.grey,
                ),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _connectionDetailText(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: palette.textMuted),
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
    final activeTransfer = _activeTransferSnapshot;
    if (activeTransfer?.state == FileTransferState.verifying &&
        _isConnectedSession) {
      actions.add(
        Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  value: null,
                  strokeWidth: 2,
                  color: palette.textMuted,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                l10n.fileTransferVerifying,
                style: TextStyle(fontSize: 12, color: palette.textMuted),
              ),
            ],
          ),
        ),
      );
    } else if (percent > 0 && percent < 1 && _isConnectedSession) {
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
                  style: TextStyle(fontSize: 12, color: palette.textMuted),
                ),
                Text(
                  "${(100 * value).toStringAsFixed(2)}%",
                  style: TextStyle(fontSize: 12, color: palette.textMuted),
                ),
              ],
            ),
          ),
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
              : _audioShareTooltip(role, isActive: isActive, isBusy: isBusy),
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
            isArmed:
                isCurrentInputSession &&
                inputState.status == RemoteInputRuntimeStatus.armed,
          ),
          icon: const Icon(Icons.keyboard_option_key_rounded),
          color: _remoteInputIconColor(
            isActive: isActive,
            isBusy: isBusy,
            isArmed:
                isCurrentInputSession &&
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
        tooltip: l10n.transferAssistantTitle,
        icon: const Icon(Icons.manage_search_rounded),
        color: palette.textMuted,
        onPressed: _openTransferAssistant,
      ),
    );
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
        icon: Icon(Icons.settings_outlined, color: palette.textMuted),
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => app_settings.ClientSettingsScreen(
                device: device,
                deleteDevice: widget.onDeviceDeleted,
              ),
            ),
          );
          await _refreshCurrentDeviceState();
        },
      ),
    );
    return actions;
  }

  Future<void> _openTransferAssistant() {
    return Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (context) =>
            TransferAssistantScreen(peerId: device.uid, peerName: device.name),
      ),
    );
  }

  bool get _shouldShowAudioShareAction {
    final audioState = _audioCoordinator.state;
    final audioGroupSession = _audioGroupCoordinator.session;
    final isCurrentAudioGroup =
        _audioGroupCoordinator.isForPeer(device.uid) &&
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

  String _connectionDetailText() {
    if (_isConnectedSession) {
      return device.auth && device.identityPublicKey.isNotEmpty
          ? l10n.e2eeTrustedConnection
          : l10n.e2eeEncryptedConnection;
    }
    return '${_connectionStatusText()} · ${device.host}:${device.port}';
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
      pendingClipboardFiles: _pendingClipboardFiles,
      pendingClipboardImages: _pendingClipboardImages,
      onPickFiles: _pickFilesAndSend,
      onSendClipboard: () async {
        await _sendText("", isClipboard: true);
      },
      onSendText: _sendComposerText,
      onPasteClipboard: _pasteClipboard,
      onSendClipboardFiles: _sendPendingClipboardFiles,
      onClearClipboardFiles: _clearPendingClipboardFiles,
      onSendClipboardImages: _sendPendingClipboardImages,
      onRemoveClipboardImage: _removePendingClipboardImage,
    );
  }

  Future<bool> _sendComposerText(String text) async {
    if (_composerSendInFlight) {
      return false;
    }
    _composerSendInFlight = true;
    try {
      return await _sendText(text);
    } finally {
      _composerSendInFlight = false;
    }
  }

  Future<String?> _pasteClipboard() async {
    if (!isDesktop() || !_canSendCurrentDevice || _isLocalhost) {
      return null;
    }
    final generation = ++_clipboardPasteGeneration;
    try {
      final drafts = await _clipboardFileReader.readFileDrafts();
      if (!mounted || generation != _clipboardPasteGeneration) {
        return null;
      }
      if (drafts.isNotEmpty) {
        final imageDrafts = drafts
            .where(
              (draft) =>
                  mediaFileKindFor(name: draft.fileName, path: draft.path) ==
                  MediaFileKind.image,
            )
            .map(
              (draft) => ClipboardImageDraft(
                path: draft.path,
                fileName: draft.fileName,
                size: draft.size,
                bytes: Uint8List(0),
              ),
            )
            .toList(growable: false);
        if (imageDrafts.length == drafts.length) {
          setState(() {
            _pendingClipboardFiles = const <ClipboardFileDraft>[];
            _pendingClipboardImages = <ClipboardImageDraft>[
              ..._pendingClipboardImages,
              ...imageDrafts,
            ];
          });
          return null;
        }
        setState(() {
          _pendingClipboardFiles = drafts;
          _pendingClipboardImages = const <ClipboardImageDraft>[];
        });
        return null;
      }

      final draft = await _clipboardImageReader.readImageDraft();
      if (!mounted || generation != _clipboardPasteGeneration) {
        return null;
      }
      if (draft != null) {
        setState(() {
          _pendingClipboardFiles = const <ClipboardFileDraft>[];
          _pendingClipboardImages = <ClipboardImageDraft>[
            ..._pendingClipboardImages,
            draft,
          ];
        });
        return null;
      }

      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (!mounted || generation != _clipboardPasteGeneration) {
        return null;
      }
      return text;
    } catch (error) {
      _logConversationFailure(ConversationOperationKind.readClipboard, error);
      return null;
    }
  }

  void _clearPendingClipboardFiles() {
    _clipboardPasteGeneration += 1;
    if (_pendingClipboardFiles.isEmpty) {
      return;
    }
    setState(() {
      _pendingClipboardFiles = const <ClipboardFileDraft>[];
    });
  }

  void _removePendingClipboardImage(int index) {
    _clipboardPasteGeneration += 1;
    if (index < 0 || index >= _pendingClipboardImages.length) {
      return;
    }
    setState(() {
      _pendingClipboardImages = List<ClipboardImageDraft>.of(
        _pendingClipboardImages,
      )..removeAt(index);
    });
  }

  Future<void> _sendPendingClipboardFiles() async {
    final drafts = List<ClipboardFileDraft>.of(_pendingClipboardFiles);
    if (drafts.isEmpty || !_canSendCurrentDevice || _isLocalhost) {
      return;
    }
    setState(() {
      _isLoading = true;
    });
    final remaining = <ClipboardFileDraft>[];
    var currentIndex = 0;
    try {
      for (; currentIndex < drafts.length; currentIndex++) {
        final draft = drafts[currentIndex];
        final sent = await socketManager.sendFileTo(device.uid, draft.path);
        if (!sent) {
          remaining.addAll(drafts.skip(currentIndex));
          break;
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _pendingClipboardFiles = remaining;
      });
      if (remaining.isNotEmpty) {
        showAppToast(l10n.clipboardFilesSendFailed);
      }
    } catch (error) {
      _logConversationFailure(
        ConversationOperationKind.sendClipboardFiles,
        error,
      );
      if (mounted) {
        setState(() {
          _pendingClipboardFiles = drafts.skip(currentIndex).toList();
        });
        showAppToast(l10n.clipboardFilesSendFailed);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _sendPendingClipboardImages() async {
    final drafts = List<ClipboardImageDraft>.of(_pendingClipboardImages);
    if (drafts.isEmpty || !_canSendCurrentDevice || _isLocalhost) {
      return;
    }
    setState(() {
      _isLoading = true;
    });
    final sentPaths = <String>{};
    try {
      var failed = false;
      for (final draft in drafts) {
        final sent = await socketManager.sendFileTo(device.uid, draft.path);
        if (!sent) {
          failed = true;
          break;
        }
        sentPaths.add(draft.path);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _pendingClipboardImages = _pendingClipboardImages
            .where((draft) => !sentPaths.contains(draft.path))
            .toList(growable: false);
      });
      if (failed) {
        showAppToast(l10n.clipboardImageSendFailed);
      }
    } catch (error) {
      _logConversationFailure(
        ConversationOperationKind.sendClipboardImage,
        error,
      );
      if (mounted) {
        setState(() {
          _pendingClipboardImages = _pendingClipboardImages
              .where((draft) => !sentPaths.contains(draft.path))
              .toList(growable: false);
        });
        showAppToast(l10n.clipboardImageSendFailed);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
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
    } catch (error) {
      _logConversationFailure(ConversationOperationKind.pickFiles, error);
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
          _connectionAttempts.cancel('peer:${device.uid}');
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
    final targetKey = 'peer:${device.uid}';
    final attemptGeneration = _connectionAttempts.begin(targetKey);
    try {
      if (await isLocalhost(host)) {
        if (!_connectionAttempts.isCurrent(targetKey, attemptGeneration)) {
          return false;
        }
        afterAuth(true, device);
        return true;
      }
      late final ConnectionAttemptResult result;
      try {
        result = await socketManager.connectToServer(
          ConnectionAttemptRequest(
            requestId: '$targetKey:$attemptGeneration',
            endpoint: PeerEndpoint(host: host, port: port),
            expectedPeerId: device.uid,
            mode: ConnectionAttemptMode.interactive,
          ),
        );
      } on ArgumentError {
        return false;
      }
      if (!mounted ||
          !_isCurrentRoute ||
          !_connectionAttempts.isCurrent(targetKey, attemptGeneration)) {
        return false;
      }
      if (result.isAuthenticated &&
          result.peerId == device.uid &&
          socketManager.isCurrentConnectionGeneration(
            result.peerId,
            result.generation,
          )) {
        final stored = await db.fetchDevice(result.peerId);
        if (!mounted ||
            !_isCurrentRoute ||
            !_connectionAttempts.isCurrent(targetKey, attemptGeneration) ||
            stored == null ||
            !socketManager.isCurrentConnectionGeneration(
              result.peerId,
              result.generation,
            )) {
          return false;
        }
        socketManager.selectPeer(result.peerId);
        ConnectionCoordinator().markConnected(stored);
        setState(() {
          device = stored;
        });
        _refreshCurrentDeviceState();
        return true;
      }
      if (result.status != ConnectionAttemptStatus.cancelled) {
        if (result.reason == ConnectionAttemptReason.duplicateRequest) {
          // 同 peer 已有连接尝试在途:轻提示即可,不弹失败对话框。
          showAppToast(l10n.connectAlreadyInProgress);
          return false;
        }
        final displayMessage = switch (result.reason) {
          ConnectionAttemptReason.protocolMismatch =>
            l10n.pairingUpgradeRequired,
          ConnectionAttemptReason.pairingExpired => l10n.pairingExpired,
          ConnectionAttemptReason.peerRejected => l10n.pairingRejectedByPeer,
          _ => l10n.connectFailed,
        };
        showLoadingDialog(
          context,
          title:
              AppLocalizations.of(context)?.connectFailed ??
              'Connection Failed',
          description: displayMessage,
          isLoading: true,
          icon: const Icon(Icons.warning_rounded, color: Colors.red),
          cancelButtonText: AppLocalizations.of(context)?.cancel ?? 'Cancel',
          onCancel: () {
            Navigator.of(context).pop();
          },
          task: (VoidCallback onCancel) async {},
        );
      }
      return false;
    } finally {
      _connectionAttempts.complete(targetKey, attemptGeneration);
    }
  }

  Future<bool> _restoreConnectionIfNeeded() async {
    if (_isConnectedSession) {
      return true;
    }
    if (!_canToggleConnection) {
      return false;
    }
    return _connectServer(device.host, device.port);
  }

  Future<void> _toggleAudioShare() async {
    if (!_isConnectedSession || _isLocalhost) {
      return;
    }
    final l10n = this.l10n;
    final audioState = _audioCoordinator.state;
    final isCurrentAudioSession = audioState.isForPeer(device.uid);
    final audioGroupSession = _audioGroupCoordinator.session;
    final isCurrentAudioGroup =
        _audioGroupCoordinator.isForPeer(device.uid) &&
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
          final selectedSinks = await _showAudioGroupSetupSheet(
            groupCandidates,
          );
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
    } catch (error) {
      final reason = audioFailureReasonFor(
        error,
        context: AudioFailureContext.protocol,
      );
      _logConversationFailure(ConversationOperationKind.audioToggle, error);
      if (mounted) {
        showAppToast(l10n.audioShareFailed(_audioFailureDetail(reason)));
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
            final selectedCount = selected.values
                .where((value) => value)
                .length;
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
                              Navigator.of(
                                context,
                              ).pop(<String, AudioChannelRole>{
                                for (final candidate in candidates)
                                  if (selected[candidate.uid] == true)
                                    candidate.uid:
                                        roles[candidate.uid] ??
                                        AudioChannelRole.stereo,
                              });
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

  String _audioFailureDetail(AudioFailureReason reason) {
    return switch (reason) {
      AudioFailureReason.unsupported => l10n.audioShareUnsupportedCapture,
      _ => l10n.connectFailed,
    };
  }

  String _remoteInputFailureDetail(RemoteInputFailureReason reason) {
    return switch (reason) {
      RemoteInputFailureReason.trustRequired =>
        l10n.remoteInputRequiresMutualTrust,
      RemoteInputFailureReason.unsupported => l10n.remoteInputLocalUnsupported,
      RemoteInputFailureReason.busy => l10n.remoteInputStopCurrentFirst,
      _ => l10n.connectFailed,
    };
  }

  Future<void> _toggleRemoteInput({bool showToast = true}) async {
    if (!_isConnectedSession || _isLocalhost) {
      return;
    }
    final l10n = this.l10n;
    final inputState = _remoteInputCoordinator.state;
    final isCurrentInputSession = inputState.isForPeer(device.uid);
    try {
      if (isCurrentInputSession) {
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
        if (showToast) {
          showAppToast(l10n.remoteInputStopCurrentFirst);
        }
        return;
      }
      if (!isDesktop()) {
        if (showToast) {
          showAppToast(l10n.remoteInputLocalUnsupported);
        }
        return;
      }
      final self = this.self ?? await LocalSetting().instance();
      final storedDevice = await LocalDatabase().fetchDevice(device.uid);
      final localTrustsRemote = storedDevice?.auth == true;
      final remoteTrustsLocal = socketManager.remotePeerTrustsPeer(
        device.uid,
        self.uid,
      );
      final isMutuallyTrusted = localTrustsRemote && remoteTrustsLocal;
      if (!localTrustsRemote) {
        if (showToast) {
          showAppToast(l10n.remoteInputRequiresMutualTrust);
        }
        return;
      }
      if (!remoteTrustsLocal) {
        if (showToast) {
          showAppToast(l10n.remoteInputPeerMustTrustThisDevice);
        }
        return;
      }
      if (!socketManager.supportsRemoteInputFor(device.uid)) {
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
          final localTopology = await RemoteInputCoordinator.shared
              .displayTopology();
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
        if (showToast) {
          showAppToast(l10n.remoteInputLayoutRequired);
        }
        return;
      }
      final topologyMappings =
          resolvedTopologyLayout?.edgeMappings ??
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
      _traceRemoteInputStart(
        trusted: isMutuallyTrusted,
        mappingCount: topologyMappings.length,
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
    } catch (error) {
      final reason = remoteInputFailureReasonFor(
        error,
        context: RemoteInputFailureContext.protocol,
      );
      _logConversationFailure(
        ConversationOperationKind.remoteInputToggle,
        error,
      );
      if (mounted && showToast) {
        showAppToast(l10n.remoteInputFailed(_remoteInputFailureDetail(reason)));
      }
    }
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

  Future<bool> _sendText(String content, {isClipboard = false}) async {
    try {
      if (isClipboard && content.trim().isEmpty) {
        final clipboardText = await getClipboardText() ?? "";
        content = clipboardText;
      }
      content = content.trim();
      if (content.isEmpty) {
        return false;
      }
      if (_isLocalhost) {
        if (isClipboard) {
          return true;
        }
        final message = MessageData(
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
          md5: "",
        );
        await LocalDatabase().insertMessage(message);
        if (mounted) {
          onMessage(message);
        }
        return true;
      }
      if (!socketManager.isConnectedTo(device.uid)) {
        if (mounted) {
          showAppToast(l10n.messageSendFailed);
        }
        return false;
      }
      final sent = await socketManager.sendMessageTo(
        device.uid,
        content,
        clipboard: isClipboard,
      );
      if (!sent && mounted) {
        showAppToast(l10n.messageSendFailed);
      }
      return sent;
    } catch (error) {
      _logConversationFailure(ConversationOperationKind.sendText, error);
      if (mounted) {
        showAppToast(l10n.messageSendFailed);
      }
      return false;
    }
  }

  // 获取设备横向宽度
  double _screenWidth({physically = false}) {
    if (!physically) {
      return MediaQuery.of(context).size.width;
    }
    return min(
      MediaQuery.of(context).size.width,
      MediaQuery.of(context).size.height,
    );
  }

  Widget _buildTextMessage(
    MessageData messageData,
    bool isOpponent,
    Widget? trailingAction,
  ) {
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
      padding: EdgeInsets.fromLTRB(
        isOpponent ? 2 : 18,
        2,
        isOpponent ? 18 : 2,
        2,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isOpponent ? receivedBubbleColor : sentBubbleColor,
          borderRadius: BorderRadius.circular(18),
          border: isOpponent ? Border.all(color: receivedBorderColor) : null,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
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
              if (trailingAction != null) ...[
                const SizedBox(width: 8),
                trailingAction,
              ],
            ],
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
    final messagePath = _effectiveMessagePath(message, transfer);
    final isActiveTransfer =
        transfer != null &&
        !_isTransferTerminal(transfer.state) &&
        transfer.state != FileTransferState.queued;
    final missingLocalFile =
        isOpponent &&
        messagePath.isNotEmpty &&
        (transfer == null || transfer.state == FileTransferState.completed) &&
        !File(messagePath).existsSync();
    var failed =
        !isOpponent &&
        !_isConnectedSession &&
        transfer == null &&
        !message.acked &&
        message.timestamp < device.lastTime;
    failed =
        failed ||
        missingLocalFile ||
        (transfer != null &&
            (transfer.state == FileTransferState.failed ||
                transfer.state == FileTransferState.canceled));
    final showRetry =
        transfer != null &&
        (transfer.state == FileTransferState.failed ||
            transfer.state == FileTransferState.paused ||
            transfer.state == FileTransferState.waitingReconnect);
    final showCancel = transfer != null && !_isTransferTerminal(transfer.state);
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final cardColor = isOpponent
        ? palette.messageIncoming
        : palette.messageOutgoing;
    final cardBorderColor = palette.borderSubtle;
    final fileStatusStyle = TextStyle(
      color: colorScheme.onSurfaceVariant,
      fontSize: 12,
    );
    final mediaKind = mediaFileKindFor(name: message.name, path: message.path);
    if (mediaKind != MediaFileKind.other) {
      final hasLocalFile =
          messagePath.isNotEmpty &&
          (messagePath.startsWith('content://') ||
              File(messagePath).existsSync());
      final contentAvailable =
          hasLocalFile &&
          (transfer == null ||
              transfer.direction == FileTransferDirection.outgoing ||
              transfer.state == FileTransferState.completed);
      return _buildMediaMessage(
        message: message,
        transfer: transfer,
        kind: mediaKind,
        path: messagePath,
        width: screenWidth,
        cardColor: cardColor,
        contentAvailable: contentAvailable,
        failed: failed || showRetry,
        showRetry: showRetry,
        showCancel: showCancel,
      );
    }

    return DesktopFileDragSource(
      path: messagePath,
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
                  child: transfer.state == FileTransferState.verifying
                      ? CircularProgressIndicator(
                          value: null,
                          strokeWidth: 2.4,
                          color: colorScheme.primary,
                          backgroundColor: colorScheme.primary.withValues(
                            alpha: 0.18,
                          ),
                        )
                      : _buildAnimatedTransferProgress(
                          value: transfer.progress,
                          builder: (context, value) =>
                              CircularProgressIndicator(
                                value: value,
                                strokeWidth: 2.4,
                                color: colorScheme.primary,
                                backgroundColor: colorScheme.primary.withValues(
                                  alpha: 0.18,
                                ),
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

  Widget _buildMediaMessage({
    required MessageData message,
    required TransferSnapshot? transfer,
    required MediaFileKind kind,
    required String path,
    required double width,
    required Color cardColor,
    required bool contentAvailable,
    required bool failed,
    required bool showRetry,
    required bool showCancel,
  }) {
    final showProgress =
        transfer != null && !_isTransferTerminal(transfer.state);
    Widget buildPreview(double? progress) => MediaMessagePreview(
      kind: kind,
      path: path,
      name: message.name,
      status: _fileStatusText(message, transfer, progressOverride: progress),
      contentAvailable: contentAvailable,
      progress: showProgress ? progress ?? transfer.progress : null,
      verifying: transfer?.state == FileTransferState.verifying,
      failed: failed,
      onRetry: showRetry ? () => _retryTransfer(message.uuid) : null,
      onCancel: showCancel ? () => _cancelTransfer(message.uuid) : null,
    );

    return DesktopFileDragSource(
      path: path,
      name: message.name,
      enabled: _canDragFileMessage(message, transfer),
      child: Container(
        constraints: BoxConstraints(maxWidth: width),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(14),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: showProgress && transfer.state != FileTransferState.verifying
              ? _buildAnimatedTransferProgress(
                  value: transfer.progress,
                  builder: (context, value) => buildPreview(value),
                )
              : buildPreview(null),
        ),
      ),
    );
  }

  void _openMessageFile(MessageData message) {
    final path = _effectiveMessagePath(message);
    final kind = mediaFileKindFor(name: message.name, path: path);
    final isAndroidContentUri = path.startsWith('content://');
    if (kind == MediaFileKind.other ||
        kind == MediaFileKind.video ||
        (!isAndroidContentUri && !File(path).existsSync())) {
      if (isAndroidContentUri) {
        unawaited(AndroidDocumentPicker.shared.openDocument(path));
      } else {
        openFile(path);
      }
      return;
    }
    unawaited(
      showMediaViewer(
        context,
        kind: kind,
        path: path,
        name: message.name,
        onOpenExternally: () {
          if (isAndroidContentUri) {
            unawaited(AndroidDocumentPicker.shared.openDocument(path));
          } else {
            openFile(path);
          }
        },
      ),
    );
  }

  @override
  void onPairing(PairingRequest request, void Function(bool) resolve) {
    if (!mounted || !_isCurrentRoute) {
      resolve(false);
      return;
    }
    unawaited(_presentPairingRequest(request, resolve));
  }

  Future<void> _presentPairingRequest(
    PairingRequest request,
    void Function(bool) resolve,
  ) async {
    await revealDesktopWindowForAttention();
    if (request.presentation?.isDismissed == true) {
      return;
    }
    if (!mounted || !_isCurrentRoute) {
      resolve(false);
      return;
    }
    await showPairingDialog(context, request: request, resolve: resolve);
  }

  @override
  void onClose() {
    percent = 0;
    _speed = "";
    unawaited(
      AndroidBackgroundKeepAliveCoordinator.shared.setReason(
        AndroidKeepAliveReason.activeSession,
        false,
      ),
    );
    _refreshCurrentDeviceState();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void onConnect() {
    _refreshCurrentDeviceState();
    _syncAndroidKeepAliveService();
  }

  var _isAlert = false;

  @override
  void onError(String message) {
    if (_isAlert || !_isCurrentRoute) {
      return;
    }
    _isAlert = true;
    showConfirmationDialog(
      context,
      title: AppLocalizations.of(context)?.timeoutTitle ?? "是否释放连接",
      description: l10n.connectFailed,
      confirmButtonText: AppLocalizations.of(context)?.disconnect ?? "断开",
      cancelButtonText: AppLocalizations.of(context)?.cancel ?? "取消",
      onConfirm: () {
        WsSvrManager().close();
        _isAlert = false;
      },
      onCancel: () {
        _isAlert = false;
      },
    );
  }

  @override
  void onNotice(String message) {
    if (!_isCurrentRoute) {
      return;
    }
    showAppToast(l10n.fileTransferFailedRetryable);
  }

  @override
  void afterAuth(bool allow, DeviceData? deviceData) {
    if (!mounted || !_isCurrentRoute || !allow || deviceData == null) {
      return;
    }
    if (deviceData.uid != device.uid) {
      if (!embedded) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => SendMessageScreen(
              device: deviceData,
              onDeviceDeleted: widget.onDeviceDeleted,
            ),
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
    privacyLog.event(PrivacyEvent.messageReceived, <PrivacyField, Object>{
      PrivacyField.kind: messageData.type,
      PrivacyField.bytes: utf8.encode(messageData.content ?? '').length,
      PrivacyField.clipboard: messageData.clipboard,
    });
    if (_isLocalhost && messageData.receiver.isEmpty ||
        messageData.sender == device.uid ||
        messageData.receiver == device.uid) {
      _insertItem(0, messageData);
      unawaited(_loadTransferSnapshotsForMessages(<MessageData>[messageData]));
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
        if (snapshot.state == FileTransferState.completed &&
            snapshot.finalPath.isNotEmpty) {
          final messageIndex = messageList.indexWhere(
            (message) => message.uuid == snapshot.messageUuid,
          );
          if (messageIndex >= 0 &&
              messageList[messageIndex].path != snapshot.finalPath) {
            messageList[messageIndex] = messageList[messageIndex].copyWith(
              path: snapshot.finalPath,
            );
          }
        }
      });
    }
    unawaited(_syncAndroidKeepAliveService());
  }
}
