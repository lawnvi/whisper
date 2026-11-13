import 'dart:math' as math;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:whisper/audio/audio_failure_reason.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/helper/transfer_failure_message.dart';
import 'package:whisper/new_ui/capture/capture_flow.dart';
import 'package:whisper/state/self_notes.dart';
import 'package:whisper/state/conversation_history_pager.dart';
import 'package:whisper/state/message_deletion.dart';
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
import 'package:whisper/page/conversation_drafts.dart';
import 'package:whisper/page/conversation_peer.dart';
import 'package:whisper/widget/app_dialogs.dart' as app_dialogs;
import 'package:whisper/page/remote_files/remote_files_page.dart';
import 'package:whisper/remote_files/fs_placement.dart';
import 'package:whisper/page/settings.dart' as app_settings;
import 'package:whisper/page/window_stream/flow_space_page.dart';
import 'package:whisper/page/transfer_assistant.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_failure_reason.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/file_transfer_engine.dart'
    show FolderSendOutcome;
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/folder_message.dart';
import 'package:whisper/state/transfer_speed_meter.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/new_ui/shell/shell_device_drop.dart';
import 'package:whisper/new_ui/shell/shell_device_card.dart';
import 'package:whisper/new_ui/shell/shell_drop_frame.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_phone_device.dart';
import 'package:whisper/remote_input/mobile_control_route.dart';
import 'package:whisper/widget/island/island_home.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/widget/chat_composer.dart';
import 'package:whisper/widget/measure_size.dart';
import 'package:whisper/widget/chat_message_list.dart';
import 'package:whisper/widget/desktop_file_drag_source.dart';
import 'package:whisper/widget/file_message_card.dart';
import 'package:whisper/widget/folder_skipped_dialog.dart';
import 'package:whisper/widget/glass_bottom_sheet.dart';
import 'package:whisper/widget/media_message_preview.dart';
import 'package:whisper/widget/message_link_text.dart';
import 'package:whisper/widget/pairing_dialog.dart';
import 'package:whisper/web_transfer/web_transfer_coordinator.dart';
import 'package:whisper/web_transfer/web_transfer_visitor.dart';

import '../helper/file.dart';
import '../helper/helper.dart';

import '../helper/notification.dart';


import '../l10n/app_localizations.dart';
import 'package:whisper/widget/subtle_motion.dart';

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
  openLink,
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

  /// In the redesigned shell, whose toolbar replaces this page's own header.
  final bool chromeless;
  final VoidCallback? onBack;
  final Future<void> Function(String uid)? onDeviceDeleted;

  /// Messages were deleted here: the list's last line may be gone with them.
  final VoidCallback? onMessagesChanged;

  const SendMessageScreen({
    super.key,
    required this.device,
    this.embedded = false,
    this.chromeless = false,
    this.onBack,
    this.onDeviceDeleted,
    this.onMessagesChanged,
  });

  @override
  _SendMessageScreen createState() => _SendMessageScreen(device);
}

class _SendMessageScreen extends State<SendMessageScreen>
    with WidgetsBindingObserver
    implements ISocketEvent {
  static const int _transferUiSpeedRefreshMs = 500;
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
  final DesktopClipboardFileWriter _clipboardFileWriter =
      const DesktopClipboardFileWriter();
  final ConnectionAttemptTracker _connectionAttempts =
      ConnectionAttemptTracker();
  DeviceData device;
  DeviceData? self;
  List<MessageData> messageList = [];
  late final _history = ConversationHistoryPager(
    (beforeId, limit) => db.fetchMessageList(
      _isLocalhost ? '' : device.uid,
      beforeId: beforeId,
      limit: limit,
    ),
  );
  bool _historyReady = false;
  bool _isConnecting = false;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _textController = TextEditingController();
  final FocusNode _composerFocusNode = FocusNode();
  bool isInputEmpty = true;
  double percent = 0;
  String _speed = "";
  final TransferSpeedMeter _speedMeter = TransferSpeedMeter();
  int _speedShownAt = 0;
  final Map<String, TransferSnapshot> _transferSnapshots =
      <String, TransferSnapshot>{};
  String? _activeTransferId;
  final Map<String, bool> keyPressedMap = <String, bool>{};
  final key = GlobalKey<SliverAnimatedListState>();
  bool _isLocalhost = false;
  final _web = WebTransferCoordinator.shared;

  /// A browser (web transfer): texts and files, nothing else.
  bool get _isWeb => isWebVisitorUid(device.uid);
  bool _isLoading = false; // loading file
  bool get embedded => widget.embedded;

  /// Files are being dragged over the conversation.
  /// How many things are dragged over the conversation; null when none.
  int? _dropItems;
  bool _resumeReconnectPending = false;
  bool _pickerReconnectPending = false;
  bool _composerSendInFlight = false;

  /// The floating composer, measured: a long draft pushes the messages up.
  final _composerHeight = ValueNotifier<double?>(null);
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

  _SendMessageScreen(this.device);

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
    _web.addListener(_historyChanged);
    // Before the listener: the first build has not happened yet.
    if (ComposerDrafts.shared.of(device.uid) case final draft?) {
      _textController.text = draft.text;
      isInputEmpty = draft.text.isEmpty;
      _pendingClipboardFiles = draft.files;
      _pendingClipboardImages = draft.images;
    }
    _textController.addListener(() {
      setState(() {
        isInputEmpty = _textController.text.isEmpty;
      });
    });
    _history.addListener(_historyChanged);
    _scrollController.addListener(_scrollListener);
    _loadMessages();
    super.initState();
  }

  @override
  void dispose() {
    ComposerDrafts.shared.keep(
      device.uid,
      ComposerDraft(
        text: _textController.text,
        files: _pendingClipboardFiles,
        images: _pendingClipboardImages,
      ),
    );
    WidgetsBinding.instance.removeObserver(this);
    _connectionAttempts.cancelAll();
    socketManager.unregisterEvent(this);
    _audioCoordinator.removeListener(_handleAudioShareChanged);
    _audioGroupCoordinator.removeListener(_handleAudioGroupChanged);
    _remoteInputCoordinator.removeListener(_handleRemoteInputChanged);
    _web.removeListener(_historyChanged);
    _history.removeListener(_historyChanged);
    _history.dispose();
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    _composerFocusNode.dispose();
    _textController.dispose();
    _composerHeight.dispose();
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
    if (state == AppLifecycleState.resumed) _knownOnDisk.clear();
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

  Widget _buildAnimatedTransferProgress({
    required double value,
    required Widget Function(BuildContext context, double value) builder,
  }) {
    final target = value.clamp(0, 1).toDouble();
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: target),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : _transferProgressAnimationDuration,
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
    if (!mounted) return;
    setState(() {
      self = me;
      device = currentDevice;
      _isLocalhost = isLocal;
      _historyReady = true;
    });
    await _loadMoreMessages();
    if (!mounted) return;

    // 开启通知监听
    if (Platform.isAndroid &&
        !isLocal &&
        socketManager.isConnectedTo(currentDevice.uid) &&
        (await LocalSetting().isListenAndroid())) {
      unawaited(startAndroidListening());
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

  void _historyChanged() {
    if (mounted) setState(() {});
  }

  void _scrollListener() {
    if (_historyReady &&
        !_history.failed &&
        _scrollController.position.extentAfter < 120) {
      unawaited(_loadMoreMessages());
    }
  }

  Future<void> _loadMoreMessages() async {
    if (!_historyReady) return;
    final generation = _history.generation;
    final page = await _history.load(
      beforeId: messageList.isEmpty ? 0 : messageList.last.id,
    );
    if (!mounted || generation != _history.generation || page.isEmpty) return;
    _insertItems(messageList.length, page);
    await _loadTransferSnapshotsForMessages(page);
  }

  void _insertItem(int index, MessageData item) {
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

  void _insertItems(int index, List<MessageData> page) {
    final items = unseenHistoryMessages(messageList, page)
        .where((message) => !TransferPlacements.shared.isQuiet(message.uuid))
        .toList();
    if (items.isEmpty) return;
    messageList.insertAll(index, items);
    // What was already there just shows. Animating a whole page of history means
    // laying all of it out again on every frame, right as the page opens.
    key.currentState?.insertAllItems(
      index,
      items.length,
      duration: Duration.zero,
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
    if (!isDesktop() || !_localEntityExists(path)) {
      return false;
    }
    return transfer == null || transfer.state == FileTransferState.completed;
  }

  /// Whether [path] is still there, as a file or as a received folder.
  /// Asking the disk on the UI thread is slow on Android, where shared storage
  /// goes through FUSE, and this is asked for every file message on every build.
  /// Remembered until a transfer moves, the app comes back, or a file is opened.
  final Map<String, bool> _knownOnDisk = {};

  bool _localEntityExists(String path) {
    if (path.isEmpty) return false;
    return _knownOnDisk.putIfAbsent(
      path,
      () => FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound,
    );
  }

  /// A file's size, or for a folder how many files it holds and their size.
  String _messageSizeLabel(MessageData message) {
    final folder = folderOfferOf(message);
    if (folder == null) {
      return formatSize(message.size);
    }
    if (folder.fileCount == 0) {
      return l10n.folderFileCount(0);
    }
    return '${l10n.folderFileCount(folder.fileCount)} · '
        '${formatSize(folder.totalBytes)}';
  }

  /// While a folder is under way its file count reads as progress, such as
  /// "3,214/14,797 files", once the transfer knows how far it has got.
  String _transferringSizeLabel(
    MessageData message,
    TransferSnapshot transfer,
  ) {
    final folder = folderOfferOf(message);
    final filesDone = transfer.filesDone;
    if (folder == null || filesDone == null || folder.fileCount == 0) {
      return _messageSizeLabel(message);
    }
    return '${l10n.folderFileProgress(filesDone.clamp(0, folder.fileCount), folder.fileCount)} · '
        '${formatSize(folder.totalBytes)}';
  }

  /// Entries of a folder that were left out, by either device.
  int _folderSkippedCount(MessageData message, TransferSnapshot? transfer) {
    final folder = folderOfferOf(message);
    if (folder == null ||
        (transfer != null && transfer.state != FileTransferState.completed)) {
      return 0;
    }
    return folder.skippedAtSource + (transfer?.skippedEntries ?? 0);
  }

  String _fileStatusText(
    MessageData message,
    TransferSnapshot? transfer, {
    double? progressOverride,
  }) {
    if (transfer == null) {
      // Offered to a browser, which has not fetched it yet.
      return _isWeb && message.receiver == device.uid
          ? l10n.webTransferAwaitingDownload
          : _messageSizeLabel(message);
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
        return '${_transferringSizeLabel(message, transfer)}  '
            '${(progress * 100).toStringAsFixed(0)}%';
      case FileTransferState.waitingReconnect:
        return l10n.fileTransferWaitingReconnect(
          (progress * 100).toStringAsFixed(0),
        );
      case FileTransferState.paused:
        return l10n.fileTransferPaused;
      case FileTransferState.verifying:
        return transfer.direction == FileTransferDirection.outgoing
            ? l10n.fileTransferWaitingPeerVerification
            : l10n.fileTransferVerifying;
      case FileTransferState.completed:
        return _messageSizeLabel(message);
      case FileTransferState.failed:
        return transferFailureMessage(l10n, transfer.lastError);
      case FileTransferState.canceled:
        return l10n.fileTransferCanceled;
    }
  }

  Future<void> _retryTransfer(String transferId) async {
    if (_isWeb) return;
    await socketManager.retryTransfer(transferId);
  }

  Future<void> _copyMessageFile(MessageData message) async {
    final transfer = _transferForMessage(message);
    final path = _effectiveMessagePath(message, transfer);
    if (!_canDragFileMessage(message, transfer)) {
      showAppToast(l10n.fileCopyFailed, tone: AppToastTone.error);
      return;
    }
    final kind = folderOfferOf(message) != null
        ? MediaFileKind.other
        : mediaFileKindFor(name: message.name, path: path);
    final copied = await _clipboardFileWriter.writeFilePaths(<String>[
      path,
    ], asImage: kind == MediaFileKind.image);
    showAppToast(
      copied ? l10n.fileCopied : l10n.fileCopyFailed,
      tone: copied ? AppToastTone.success : AppToastTone.error,
    );
  }

  Future<void> _cancelTransfer(String transferId) async {
    if (_isWeb) return _web.cancel(transferId);
    await socketManager.cancelTransfer(transferId);
  }

  Future<void> _deleteMessages(
    List<MessageData> messages, {
    bool deleteFiles = false,
  }) async {
    if (deleteFiles) {
      for (final message in messages) {
        if (!canDeleteReceivedMessageFile(message, self?.uid)) continue;
        final transfer = _transferForMessage(message);
        if (transfer != null && !_isTransferTerminal(transfer.state)) {
          await _cancelTransfer(transfer.transferId);
        }
        try {
          await deleteReceivedMessageFile(
            message,
            selfUid: self?.uid,
            path: _effectiveMessagePath(message),
          );
          unawaited(
            notifyFileRemovedFromAndroidPickers(_effectiveMessagePath(message)),
          );
        } on FileSystemException catch (error) {
          _logConversationFailure(ConversationOperationKind.deleteFile, error);
          rethrow;
        }
      }
    }
    _knownOnDisk.clear();
    await _deleteItems(messages.map((message) => message.id));
  }

  Future<void> _deleteItems(Iterable<int> messageIds) async {
    final ids = messageIds.toSet();
    if (ids.isEmpty) {
      return;
    }

    await db.deleteMessages(ids);
    widget.onMessagesChanged?.call();
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final content = Column(
      children: [
        if (embedded && !widget.chromeless) _buildEmbeddedHeader(isDark),
        if (_history.loading)
          const SizedBox(
            height: 28,
            child: Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        if (_history.failed)
          TextButton.icon(
            onPressed: _loadMoreMessages,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(l10n.historyLoadFailed),
          ),
        // Progress is on the file card and the island, not across
        // the top of the page.
        const SizedBox.shrink(),
        Expanded(
          child: ValueListenableBuilder<double?>(
            valueListenable: _composerHeight,
            builder: (context, composerHeight, _) => ChatMessageList(
              composerHeight: composerHeight,
              hasComposer: _canSendCurrentDevice,
              // A card in the list says how far it is: no need for the island.
              buildFileMessage: (message, isOpponent) => IslandHome(
                home: IslandHomes.message(message.uuid),
                child: _buildFileMessage(message, isOpponent),
              ),
              buildTextMessage: _buildTextMessage,
              controller: _scrollController,
              listKey: key,
              messages: messageList,
              onOpenContainingFolder: (path) => openDir(path, parent: true),
              onOpenFile: _openMessageFile,
              onCopyText: copyToClipboard,
              onCopyFile: _copyMessageFile,
              onDeleteMessage: (message, {deleteFile = false}) =>
                  _deleteMessages([message], deleteFiles: deleteFile),
              onDeleteMessages: _deleteMessages,
              onSelectionModeChanged: (active) {
                if (_messageSelectionActive != active) {
                  setState(() => _messageSelectionActive = active);
                }
              },
              selfUid: self?.uid,
              transferStateOf: (message) => _transferForMessage(message)?.state,
              mediaPathOf: _effectiveMessagePath,
            ),
          ),
        ),
      ],
    );

    final body = LayoutBuilder(
      builder: (context, box) {
        // A phone's width, not a phone: beside a sidebar it floats in the
        // middle, as on a desktop.
        final touch = WhisperLayout.of(context).compact && !isDesktop();
        return Stack(
          children: [
            Positioned.fill(child: content),
            // Nothing to write to: not a box that says so.
            if (!_messageSelectionActive && _canSendCurrentDevice)
              Positioned(
                left: 0,
                right: 0,
                bottom: touch ? 24 : 16,
                child: MeasureSize(
                  onChange: (size) => _composerHeight.value = size.height,
                  child: SafeArea(
                    top: false,
                    child: Center(
                      child: SizedBox(
                        width: touch
                            ? box.maxWidth - 36
                            : math.min(860, box.maxWidth - 48),
                        child: _buildComposer(isDark),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
    Widget base = embedded
        ? Material(color: Colors.transparent, child: body)
        : Scaffold(
            backgroundColor: context.wc.content,
            appBar: _buildNewStandaloneBar(),
            body: body,
          );

    if (isMobile()) {
      return base;
    }

    return DropRegion(
      formats: const [Formats.fileUri],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropEnter: (event) {
        setState(
          () => _dropItems = isChatMessageDrag(event.session)
              ? null
              : event.session.items.length,
        );
      },
      onDropLeave: (_) {
        setState(() => _dropItems = null);
      },
      onDropOver: (event) {
        // A message dragged and let go in the conversation is a change of mind.
        if (isChatMessageDrag(event.session)) return DropOperation.none;
        final canCopy = event.session.allowedOperations.contains(
          DropOperation.copy,
        );
        final hasOnlyFiles =
            event.session.items.isNotEmpty &&
            event.session.items.every(
              (item) => item.canProvide(Formats.fileUri),
            );
        return _canSendCurrentDevice && canCopy && hasOnlyFiles
            ? DropOperation.copy
            : DropOperation.none;
      },
      onPerformDrop: (event) async {
        if (mounted) setState(() => _dropItems = null);
        final paths = await Future.wait(
          event.session.items.map(readDroppedFilePath),
        );
        if (paths.any((path) => path == null)) {
          if (mounted) {
            showAppToast(l10n.fileDropRejected, tone: AppToastTone.error);
          }
          return;
        }
        unawaited(_handleFileDrop(paths.cast<String>()));
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          base,
          if (_dropItems case final count?)
            ShellDropFrame(
              device: device,
              canSend: _canSendCurrentDevice,
              count: count,
            ),
        ],
      ),
    );
  }

  Future<void> _handleFileDrop(List<String> paths) async {
    if (paths.isEmpty || !_canSendCurrentDevice) {
      return;
    }
    try {
      for (final path in paths) {
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.directory && !_isLocalhost) {
          if (!await _sendFolder(path)) {
            return;
          }
          continue;
        }
        if (type != FileSystemEntityType.file) {
          if (mounted) {
            showAppToast(l10n.fileDropRejected, tone: AppToastTone.error);
          }
          return;
        }
        final sent = await _sendFile(path);
        if (!sent && mounted) {
          showAppToast(l10n.fileDropRejected, tone: AppToastTone.error);
          return;
        }
      }
    } catch (error) {
      _logConversationFailure(
        ConversationOperationKind.sendDroppedFiles,
        error,
      );
      if (mounted) {
        showAppToast(l10n.fileDropRejected, tone: AppToastTone.error);
      }
    }
  }

  /// Sends a folder as one transfer. Scanning a large tree takes a moment,
  /// during which the composer shows that it is busy.
  Future<bool> _sendFolder(String path) async {
    if (_isWeb) {
      showAppToast(l10n.webTransferNoFolders, tone: AppToastTone.error);
      return false;
    }
    if (mounted) {
      setState(() => _isLoading = true);
    }
    final FolderSendOutcome outcome;
    try {
      outcome = await socketManager.sendFolderTo(device.uid, path);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
    if (outcome == FolderSendOutcome.sent) {
      return true;
    }
    if (mounted) {
      showAppToast(
        folderSendFailureText(l10n, outcome),
        tone: AppToastTone.error,
      );
    }
    return false;
  }

  Future<void> _pickFolderAndSend() async {
    if (!_canSendCurrentDevice || _isLocalhost) {
      return;
    }
    try {
      final path = await WhisperFilePicker.pickFolder();
      if (path == null || !mounted) {
        return;
      }
      await _sendFolder(path);
    } catch (error) {
      _logConversationFailure(ConversationOperationKind.pickFiles, error);
      if (mounted) {
        showAppToast(l10n.filePickerOpenFailed, tone: AppToastTone.error);
      }
    }
  }

  bool get _canSendCurrentDevice {
    return _isLocalhost ||
        socketManager.isConnectedTo(device.uid) ||
        _web.canSend(device.uid);
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

  /// surfaces.md「手机」: back, the name (which opens the device's page, so a long
  /// one has the room), control where it applies, and ⋯ to the device's page.
  PreferredSizeWidget _buildNewStandaloneBar() {
    final c = context.wc;
    const type = WhisperType(touch: true);
    void openDevice() => unawaited(_openDevicePage());
    Widget button(
      WhisperGlyph glyph,
      String label,
      VoidCallback onTap, {
      double size = 21,
      double weight = 1.6,
    }) => ShellIconButton(
      glyph: glyph,
      iconSize: size,
      weight: weight,
      touch: true,
      color: c.accent,
      label: label,
      onTap: onTap,
    );
    final canControl =
        supportsManualRemoteInputSource() &&
        !_isLocalhost &&
        _isConnectedSession &&
        socketManager.supportsManualInputFor(device.uid);
    return PreferredSize(
      preferredSize: const Size.fromHeight(50),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 50,
          child: Row(
            children: [
              button(
                WhisperGlyph.back,
                l10n.back,
                () {
                  if (widget.onBack != null) {
                    widget.onBack!();
                    return;
                  }
                  Navigator.of(context).maybePop();
                },
                size: 20,
                weight: 2,
              ),
              Expanded(
                child: Pressable(
                  onTap: openDevice,
                  radius: WhisperRadius.xs,
                  scale: 1,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        device.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: type.head,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          color: c.ink,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (canControl)
                button(
                  WhisperGlyph.keyboard,
                  l10n.mobileControlTitle,
                  () => unawaited(_openMobileControl()),
                ),
              button(
                WhisperGlyph.more,
                l10n.deviceDetailsTitle,
                openDevice,
                size: 22,
                weight: 2.6,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Control (when it is a computer), files and apps: the phone's way into what
  /// a desktop shows as tabs. They stay in place while disconnected, dimmed.
  List<ShellDeviceEntry> _phoneEntries() {
    if (_isWeb) return const [];
    final on = _isConnectedSession;
    void push(WidgetBuilder builder) => unawaited(
      Navigator.push<void>(context, WhisperPageRoute<void>(builder: builder)),
    );
    return [
      if (supportsManualRemoteInputSource() &&
          !_isLocalhost &&
          (!on || socketManager.supportsManualInputFor(device.uid)))
        ShellDeviceEntry(
          glyph: WhisperGlyph.keyboard,
          title: l10n.shellPhoneControl,
          onTap: on ? () => unawaited(_openMobileControl()) : null,
        ),
      ShellDeviceEntry(
        glyph: WhisperGlyph.folder,
        title: l10n.shellTabFiles,
        onTap: on
            ? () => push(
                (_) => RemoteFilesPage(
                  peerId: device.uid,
                  deviceName: device.label,
                ),
              )
            : null,
      ),
      ShellDeviceEntry(
        glyph: WhisperGlyph.apps,
        title: l10n.shellTabApps,
        onTap: on
            ? () => push((_) => FlowSpacePage(focusPeerId: device.uid))
            : null,
      ),
    ];
  }

  Future<void> _openDevicePage() async {
    await Navigator.push(
      context,
      WhisperPageRoute<void>(
        builder: (context) => ShellPhoneDevicePage(
          device: device,
          connected: _isConnectedSession,
          entries: _phoneEntries(),
          onSearchHistory: _openTransferAssistant,
          onDiagnostics: () => showAppToast(
            _isConnectedSession
                ? l10n.connectedNow
                : l10n.deviceFeatureNeedsConnection,
          ),
          onRemove: (uid) async {
            final delete = widget.onDeviceDeleted;
            if (delete == null) {
              await socketManager.deletePeer(uid);
            } else {
              await delete(uid);
            }
            if (context.mounted) {
              Navigator.popUntil(context, (route) => route.isFirst);
            }
          },
        ),
      ),
    );
    await _refreshCurrentDeviceState();
  }

  Widget _buildEmbeddedHeader(bool isDark) {
    final palette = context.wc;
    return Container(
      height: 72,
      padding: const EdgeInsets.fromLTRB(18, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(bottom: BorderSide(color: palette.sep)),
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
    final palette = context.wc;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          device.label,
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
            SizedBox.square(
              dimension: 14,
              child: WhisperAnimatedSwitcher(
                value: (_isConnectedSession, device.around),
                child: _isConnectedSession
                    ? Icon(Icons.lock_rounded, size: 14, color: palette.ok)
                    : Center(
                        child: ConnectionStatusDot(
                          color: device.around == true
                              ? context.wc.ok
                              : context.wc.ink3,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: WhisperAnimatedSwitcher(
                value: _connectionDetailText(),
                alignment: Alignment.centerLeft,
                child: Text(
                  _connectionDetailText(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: palette.ink2),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _buildHeaderActions(bool isDark) {
    final palette = context.wc;
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
                  color: palette.ink2,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                l10n.fileTransferVerifying,
                style: TextStyle(fontSize: 12, color: palette.ink2),
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
                  style: TextStyle(fontSize: 12, color: palette.ink2),
                ),
                Text(
                  "${(100 * value).toStringAsFixed(2)}%",
                  style: TextStyle(fontSize: 12, color: palette.ink2),
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
          : isCurrentAudioGroup && _audioGroupCoordinator.isPlaybackActive
          ? AudioShareRuntimeRole.sink
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
        onPressed: _canToggleConnection && !_isConnecting
            ? _toggleConnection
            : null,
        tooltip: _isConnecting
            ? l10n.connectAlreadyInProgress
            : _isConnectedSession
            ? (AppLocalizations.of(context)?.disconnect ?? '断开')
            : (AppLocalizations.of(context)?.connect ?? '连接'),
        icon: WhisperAnimatedSwitcher(
          value: (_isConnectedSession, _canToggleConnection, _isConnecting),
          child: _isConnecting
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  _isConnectedSession
                      ? Icons.wifi_rounded
                      : (_canToggleConnection
                            ? Icons.wifi_find_rounded
                            : Icons.wifi_off_rounded),
                  color: _isConnectedSession
                      ? context.wc.accentText
                      : (_canToggleConnection ? palette.ink2 : context.wc.ink3),
                ),
        ),
      ),
    );
    actions.add(
      IconButton(
        padding: actionPadding,
        constraints: actionConstraints,
        visualDensity: actionVisualDensity,
        // This device's page: what it can do (流转, 文件, 设备控制, 搜索)
        // and how it is shared with.
        tooltip: l10n.deviceDetailsTitle,
        icon: Icon(CupertinoIcons.ellipsis_circle, color: palette.ink2),
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => app_settings.ClientSettingsScreen(
                device: device,
                deleteDevice: widget.onDeviceDeleted,
                onSearchHistory: _openTransferAssistant,
                features: _deviceFeatures(),
              ),
            ),
          );
          await _refreshCurrentDeviceState();
        },
      ),
    );
    return actions;
  }

  /// What this device can do from here, for its page. Rows show while it
  /// is offline too, dimmed, so where to find them stays the same.
  List<app_settings.DeviceFeature> _deviceFeatures() {
    if (_isWeb) return const [];
    final capabilities = socketManager
        .remoteProfileFor(device.uid)
        ?.capabilities;
    final connected = _isConnectedSession;
    final offline = connected ? null : l10n.deviceFeatureNeedsConnection;
    bool offers(bool? capability) => !connected || capability == true;
    return [
      if (!_isLocalhost &&
          offers(
            capabilities == null
                ? null
                : capabilities.windowStreamSourceV1 ||
                      capabilities.windowStreamSinkV1,
          ))
        app_settings.DeviceFeature(
          icon: CupertinoIcons.rectangle_stack,
          title: l10n.windowStreamSpaceTitle,
          unavailable: offline,
          onOpen: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => FlowSpacePage(focusPeerId: device.uid),
            ),
          ),
        ),
      if (!_isLocalhost &&
          canOfferRemoteFiles() &&
          offers(capabilities?.remoteFilesV1))
        app_settings.DeviceFeature(
          icon: CupertinoIcons.folder,
          title: l10n.remoteFilesTitle,
          unavailable: offline,
          onOpen: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) =>
                  RemoteFilesPage(peerId: device.uid, deviceName: device.label),
            ),
          ),
        ),
      if (supportsManualRemoteInputSource() &&
          !_isLocalhost &&
          (!connected || socketManager.supportsManualInputFor(device.uid)))
        app_settings.DeviceFeature(
          icon: CupertinoIcons.device_laptop,
          title: l10n.mobileControlTitle,
          unavailable: offline,
          onOpen: () => unawaited(_openMobileControl()),
        ),
    ];
  }

  Future<void> _openMobileControl() => Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => mobileControlPage(device: device, self: self, l10n: l10n),
    ),
  );

  Future<void> _openTransferAssistant() {
    return Navigator.push<void>(
      context,
      WhisperPageRoute<void>(
        builder: (context) =>
            TransferAssistantScreen(peerId: device.uid),
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
      return context.wc.ink2;
    }
    return context.wc.accentText;
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
      return context.wc.ink2;
    }
    return context.wc.accentText;
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

  String _connectionDetailText() {
    if (_isConnectedSession) {
      return device.auth && device.identityPublicKey.isNotEmpty
          ? l10n.e2eeTrustedConnection
          : l10n.e2eeEncryptedConnection;
    }
    return '${device.host}:${device.port}';
  }

  Widget _buildComposer(bool isDark) {
    return ChatComposer(
      clipboardEnabled: self?.clipboard == true,
      canSend: _canSendCurrentDevice,
      isInputEmpty: isInputEmpty,
      isLoading: _isLoading,
      isDesktopStyle: isDesktop(),
      keyPressedMap: keyPressedMap,
      controller: _textController,
      focusNode: _composerFocusNode,
      pendingClipboardFiles: _pendingClipboardFiles,
      pendingClipboardImages: _pendingClipboardImages,
      onPickFiles: _pickFilesAndSend,
      onPickFolder: isDesktop() && !_isLocalhost && !_isWeb
          ? _pickFolderAndSend
          : null,
      onSendClipboard: () async {
        await _sendText("", isClipboard: true);
      },
      onSyncClipboard: _syncClipboard,
      onSendText: _sendComposerText,
      onPasteClipboard: _pasteClipboard,
      onSendClipboardFiles: _sendPendingClipboardFiles,
      onClearClipboardFiles: _clearPendingClipboardFiles,
      onSendClipboardImages: _sendPendingClipboardImages,
      onRemoveClipboardImage: _removePendingClipboardImage,
      onEditClipboardImage: _markUpPendingClipboardImage,
      composerHint: l10n.shellComposerHint(device.label),
      disabledHint: _isWeb
          ? l10n.webTransferEnded(device.label)
          : l10n.shellComposerOffline(device.label),
    );
  }

  /// The button says when it worked. Nothing to send has to be said in words.
  Future<bool> _syncClipboard() async {
    final text = (await getClipboardText() ?? '').trim();
    if (text.isEmpty) {
      if (mounted) showAppToast(l10n.shellTrayClipboardEmpty);
      return false;
    }
    return _sendText(text, isClipboard: true);
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
    if (!isDesktop() || !_canSendCurrentDevice) {
      return null;
    }
    final generation = ++_clipboardPasteGeneration;
    try {
      final drafts = await _clipboardFileReader.readFileDrafts(
        retainRemoteFiles: true,
      );
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

      final text = await getClipboardText();
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
    if (drafts.isEmpty || !_canSendCurrentDevice) {
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
        final sent = await _sendFile(draft.path);
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
        showAppToast(l10n.clipboardFilesSendFailed, tone: AppToastTone.error);
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
        showAppToast(l10n.clipboardFilesSendFailed, tone: AppToastTone.error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// The picture on its way out, marked up: the marked-up one goes instead.
  Future<void> _markUpPendingClipboardImage(int index) async {
    final draft = _pendingClipboardImages[index];
    final marked = await markUpDraftImage(
      Navigator.of(context),
      bytes: draft.bytes.isEmpty ? null : draft.bytes,
      path: draft.path,
      doneLabel: l10n.confirm,
    );
    if (marked == null || !mounted) return;
    setState(() {
      _pendingClipboardImages = [
        for (final item in _pendingClipboardImages)
          identical(item, draft) ? marked : item,
      ];
    });
  }

  Future<void> _sendPendingClipboardImages() async {
    final drafts = List<ClipboardImageDraft>.of(_pendingClipboardImages);
    if (drafts.isEmpty || !_canSendCurrentDevice) {
      return;
    }
    setState(() {
      _isLoading = true;
    });
    final sentPaths = <String>{};
    try {
      var failed = false;
      for (final draft in drafts) {
        final sent = await _sendFile(draft.path, draft: true);
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
        showAppToast(l10n.clipboardImageSendFailed, tone: AppToastTone.error);
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
        showAppToast(l10n.clipboardImageSendFailed, tone: AppToastTone.error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// What sending means in 本机: it goes in the list, and nowhere else.
  Future<bool> _sendFile(String path, {bool draft = false}) async {
    if (_isWeb) return _web.sendFile(device.uid, path, draft: draft);
    if (!_isLocalhost) return socketManager.sendFileTo(device.uid, path);
    _noteAdded(await SelfNotes(db).addFile(device.uid, path, draft: draft));
    return true;
  }

  void _noteAdded(MessageData note) {
    if (mounted) onMessage(note);
    widget.onMessagesChanged?.call();
  }

  Future<void> _pickFilesAndSend() async {
    if (!_canSendCurrentDevice) {
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
              tone: AppToastTone.error,
            );
          }
          return;
        }
      }
      for (final item in result) {
        if (_isLocalhost) {
          _noteAdded(
            await SelfNotes(db).addFile(
              device.uid,
              item.path ?? item.androidContentUri ?? '',
              name: item.name,
              size: item.size,
            ),
          );
        } else if (_isWeb) {
          await _web.sendFile(
            device.uid,
            item.path ?? item.androidContentUri ?? '',
            name: item.name,
            size: item.size,
          );
        } else {
          await socketManager.sendPickedFileTo(device.uid, item);
        }
      }
    } catch (error) {
      _logConversationFailure(ConversationOperationKind.pickFiles, error);
      if (mounted) {
        showAppToast(
          AppLocalizations.of(context)?.filePickerOpenFailed ??
              'Unable to open the file picker',
          tone: AppToastTone.error,
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
      _connectionAttempts.cancel('peer:${device.uid}');
      unawaited(socketManager.disconnectPeer(device.uid));
      return;
    }
    if (_canToggleConnection) {
      _connectServer(device.host, device.port);
    }
  }

  Future<bool> _connectServer(String host, int port) async {
    if (!mounted || _isConnecting) return false;
    setState(() => _isConnecting = true);
    final targetKey = 'peer:${device.uid}';
    final attemptGeneration = _connectionAttempts.begin(targetKey);
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted ||
          !_connectionAttempts.isCurrent(targetKey, attemptGeneration)) {
        return false;
      }
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
        unawaited(_refreshCurrentDeviceState());
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
          ConnectionAttemptReason.pairingNeedsUpdate => l10n.pairingNeedsUpdate,
          ConnectionAttemptReason.pairingExpired => l10n.pairingExpired,
          ConnectionAttemptReason.peerRejected => l10n.pairingRejectedByPeer,
          _ => l10n.connectFailed,
        };
        unawaited(
          app_dialogs.showLoadingDialog(
            context,
            title: l10n.connectFailed,
            // The title says it already when there is nothing more to say.
            description: displayMessage == l10n.connectFailed
                ? ''
                : displayMessage,
            isLoading: true,
            icon: Icon(Icons.warning_rounded, color: context.wc.bad),
            cancelButtonText: AppLocalizations.of(context)?.cancel ?? 'Cancel',
            onCancel: () {},
            task: (VoidCallback onCancel) async {},
          ),
        );
      }
      return false;
    } finally {
      _connectionAttempts.complete(targetKey, attemptGeneration);
      if (mounted) setState(() => _isConnecting = false);
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
        return;
      }
      if (isCurrentAudioSession) {
        await _audioCoordinator.stopSharing(
          sendControl: socketManager.sendAudioControl,
        );
        return;
      }
      if (!supportsNativeSystemAudio()) {
        showAppToast(
          l10n.audioShareUnsupportedCapture,
          tone: AppToastTone.warning,
        );
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
        return;
      }
      await _audioCoordinator.startSharingToConnectedPeer(
        sourcePeerId: self.uid,
        sinkPeerId: device.uid,
        sinkHost: device.host,
        sinkPort: device.port,
        sendControl: socketManager.sendAudioControl,
      );
    } catch (error) {
      final reason = audioFailureReasonFor(
        error,
        context: AudioFailureContext.protocol,
      );
      _logConversationFailure(ConversationOperationKind.audioToggle, error);
      if (mounted) {
        showAppToast(
          l10n.audioShareFailed(_audioFailureDetail(reason)),
          tone: AppToastTone.error,
        );
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
    return showWhisperModalBottomSheet<Map<String, AudioChannelRole>>(
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
                            title: Text(candidate.label),
                            subtitle: Text(candidate.platform),
                            secondary: WhisperGlassMenuButton<AudioChannelRole>(
                              value:
                                  roles[candidate.uid] ??
                                  AudioChannelRole.stereo,
                              enabled: isSelected,
                              options:
                                  <WhisperGlassMenuOption<AudioChannelRole>>[
                                    for (final role in AudioChannelRole.values)
                                      WhisperGlassMenuOption<AudioChannelRole>(
                                        value: role,
                                        label: _audioGroupRoleLabel(role),
                                      ),
                                  ],
                              onChanged: (role) {
                                setSheetState(() {
                                  roles[candidate.uid] = role;
                                });
                              },
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
          showAppToast(
            l10n.remoteInputLocalUnsupported,
            tone: AppToastTone.warning,
          );
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
          showAppToast(
            l10n.remoteInputPeerUnsupported,
            tone: AppToastTone.warning,
          );
        }
        return;
      }
      final layout = await remoteInputLayoutFor(device);
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
        showAppToast(
          l10n.remoteInputEnabledMoveToEdge,
          tone: AppToastTone.success,
        );
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
        showAppToast(
          l10n.remoteInputFailed(_remoteInputFailureDetail(reason)),
          tone: AppToastTone.error,
        );
      }
    }
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
        _noteAdded(await SelfNotes(db).addText(device.uid, content));
        return true;
      }
      if (_isWeb) return _web.sendText(device.uid, content);
      if (!socketManager.isConnectedTo(device.uid)) {
        if (mounted) {
          showAppToast(l10n.messageSendFailed, tone: AppToastTone.error);
        }
        return false;
      }
      final sent = await socketManager.sendMessageTo(
        device.uid,
        content,
        clipboard: isClipboard,
      );
      if (!sent && mounted) {
        showAppToast(l10n.messageSendFailed, tone: AppToastTone.error);
      }
      return sent;
    } catch (error) {
      _logConversationFailure(ConversationOperationKind.sendText, error);
      if (mounted) {
        showAppToast(l10n.messageSendFailed, tone: AppToastTone.error);
      }
      return false;
    }
  }

  Widget _buildTextMessage(
    MessageData messageData,
    bool isOpponent,
    Widget? trailingAction,
  ) {
    var content = messageData.content ?? "";
    if (messageData.type == MessageEnum.Notification) {
      final decoded = jsonDecode(messageData.content ?? "{}");
      final data = decoded is Map ? decoded : const <String, Object?>{};
      content = "【${data['app']}】${data['title']}\n${data['text']}";
    }
    final c = context.wc;
    final mine = !isOpponent;
    final body = WhisperType(touch: !isDesktop()).body;
    final style = TextStyle(
      fontSize: body,
      height: 1.45,
      color: mine ? c.onTint : c.ink,
    );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: MessageHoverCopy(
        text: content,
        mine: mine,
        enabled: isDesktop() && !_messageSelectionActive,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: mine ? c.tintHover : c.bubble,
            borderRadius: BorderRadius.circular(WhisperRadius.bubble),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            child: MessageSelectionColors(
              mine: mine,
              child: MessageLinkText(
                text: content,
                style: style,
                linkStyle: style.copyWith(
                  color: mine ? c.onTint : c.accentText,
                  decoration: TextDecoration.underline,
                  decorationColor: mine ? c.onTint : c.accentText,
                ),
                linksEnabled: !_messageSelectionActive,
                onOpen: _openMessageLink,
                textAlign: TextAlign.left,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openMessageLink(Uri uri) async {
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        showAppToast(
          AppLocalizations.of(context)!.messageLinkOpenFailed,
          tone: AppToastTone.error,
        );
      }
    } catch (error) {
      _logConversationFailure(ConversationOperationKind.openLink, error);
      if (mounted) {
        showAppToast(
          AppLocalizations.of(context)!.messageLinkOpenFailed,
          tone: AppToastTone.error,
        );
      }
    }
  }

  Widget _buildFileMessage(MessageData message, bool isOpponent) {
    final transfer = _transferForMessage(message);
    final messagePath = _effectiveMessagePath(message, transfer);
    final isActiveTransfer =
        transfer != null &&
        !_isTransferTerminal(transfer.state) &&
        transfer.state != FileTransferState.queued;
    final isFolder = folderOfferOf(message) != null;
    final skippedCount = _folderSkippedCount(message, transfer);
    final missingLocalFile =
        isOpponent &&
        messagePath.isNotEmpty &&
        (transfer == null || transfer.state == FileTransferState.completed) &&
        !_localEntityExists(messagePath);
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
        transfer.direction == FileTransferDirection.outgoing &&
        (transfer.state == FileTransferState.failed ||
            transfer.state == FileTransferState.paused ||
            transfer.state == FileTransferState.waitingReconnect);
    final showCancel =
        transfer != null &&
        !_isTransferTerminal(transfer.state) &&
        (transfer.direction == FileTransferDirection.outgoing ||
            (transfer.state != FileTransferState.paused &&
                transfer.state != FileTransferState.waitingReconnect));
    final palette = context.wc;
    final cardColor = isOpponent ? palette.bubble : palette.tintHover;
    final cardBorderColor = palette.sep;
    // A folder is never previewed as media, whatever its name ends in.
    final mediaKind = isFolder
        ? MediaFileKind.other
        : mediaFileKindFor(name: message.name, path: message.path);
    if (mediaKind != MediaFileKind.other) {
      final contentAvailable = _isMediaContentAvailable(messagePath, transfer);
      return _buildMediaMessage(
        message: message,
        transfer: transfer,
        kind: mediaKind,
        path: messagePath,
        cardColor: cardColor,
        contentAvailable: contentAvailable,
        failed: failed || showRetry,
        showRetry: showRetry,
        showCancel: showCancel,
      );
    }

    return DesktopFileDragSource(
      peerId: device.uid,
      path: messagePath,
      name: message.name,
      enabled: _canDragFileMessage(message, transfer),
      child: FileMessageCard(
        name: message.name,
        isFolder: isFolder,
        // Cancelled on purpose: it says so, without the warning.
        problem: missingLocalFile
            ? l10n.fileMissingHere
            : failed && transfer?.state != FileTransferState.canceled
            ? (isOpponent ? l10n.fileReceiveFailed : l10n.fileSendFailed)
            : null,
        active: isActiveTransfer,
        verifying: transfer?.state == FileTransferState.verifying,
        progress: transfer?.progress ?? 0,
        statusKey: (failed, transfer?.state),
        statusText: (progress) {
          final status =
              _fileStatusText(message, transfer, progressOverride: progress);
          final speed = _speed.trim();
          return isActiveTransfer &&
                  transfer.transferId == _activeTransferId &&
                  speed.isNotEmpty
              ? '$status · $speed'
              : status;
        },
        cardColor: cardColor,
        borderColor: cardBorderColor,
        animationDuration: _transferProgressAnimationDuration,
        skippedLabel: skippedCount > 0
            ? l10n.folderSkippedCount(skippedCount)
            : null,
        onShowSkipped: () => unawaited(
          showFolderSkippedDialog(
            context,
            transferId: message.uuid,
            skippedCount: skippedCount,
          ),
        ),
        retryTooltip: l10n.retry,
        cancelTooltip: l10n.cancel,
        onRetry: showRetry ? () => _retryTransfer(message.uuid) : null,
        onCancel: showCancel ? () => _cancelTransfer(message.uuid) : null,
      ),
    );
  }

  Widget _buildMediaMessage({
    required MessageData message,
    required TransferSnapshot? transfer,
    required MediaFileKind kind,
    required String path,
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
      peerId: device.uid,
      path: path,
      name: message.name,
      enabled: _canDragFileMessage(message, transfer),
      // No bubble behind a picture: it stands on its own.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(WhisperRadius.m),
        child: showProgress && transfer.state != FileTransferState.verifying
            ? _buildAnimatedTransferProgress(
                value: transfer.progress,
                builder: (context, value) => buildPreview(value),
              )
            : buildPreview(null),
      ),
    );
  }

  /// See [ChatMessageList.isMediaSettled].
  void _openMessageFile(MessageData message) {
    _knownOnDisk.clear();
    final transfer = _transferForMessage(message);
    final path = _effectiveMessagePath(message, transfer);
    if (folderOfferOf(message) != null) {
      if (_localEntityExists(path)) {
        unawaited(openDir(path));
      }
      return;
    }
    final kind = mediaFileKindFor(name: message.name, path: path);
    if (kind == MediaFileKind.video &&
        !_isMediaContentAvailable(path, transfer)) {
      return;
    }
    final isAndroidContentUri = path.startsWith('content://');
    if (kind == MediaFileKind.other ||
        (!isAndroidContentUri && !File(path).existsSync())) {
      if (isAndroidContentUri) {
        unawaited(AndroidDocumentPicker.shared.openDocument(path));
      } else {
        openFile(path);
      }
      return;
    }
    final gallery = kind == MediaFileKind.image
        ? _imageGalleryFor(message)
        : null;
    unawaited(
      showMediaViewer(
        context,
        kind: kind,
        path: path,
        name: message.name,
        imageGallery: gallery?.images,
        initialImageIndex: gallery?.initialIndex ?? 0,
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

  ({List<MediaViewerImage> images, int initialIndex}) _imageGalleryFor(
    MessageData selectedMessage,
  ) {
    final images = <MediaViewerImage>[];
    var initialIndex = -1;
    for (final message in messageList.reversed) {
      if (message.type != MessageEnum.File) {
        continue;
      }
      final transfer = _transferForMessage(message);
      final path = _effectiveMessagePath(message, transfer);
      if (mediaFileKindFor(name: message.name, path: path) !=
              MediaFileKind.image ||
          !_isMediaContentAvailable(path, transfer)) {
        continue;
      }
      final isSelectedMessage =
          identical(message, selectedMessage) ||
          (selectedMessage.uuid.isNotEmpty &&
              message.uuid == selectedMessage.uuid) ||
          (selectedMessage.id > 0 && message.id == selectedMessage.id);
      if (isSelectedMessage) {
        initialIndex = images.length;
      }
      images.add(MediaViewerImage(path: path, name: message.name));
    }

    if (initialIndex < 0) {
      initialIndex = images.length;
      images.add(
        MediaViewerImage(
          path: _effectiveMessagePath(selectedMessage),
          name: selectedMessage.name,
        ),
      );
    }
    return (images: images, initialIndex: initialIndex);
  }

  bool _isMediaContentAvailable(String path, TransferSnapshot? transfer) {
    final hasLocalFile =
        path.isNotEmpty &&
        (path.startsWith('content://') || _localEntityExists(path));
    return hasLocalFile &&
        (transfer == null ||
            transfer.direction == FileTransferDirection.outgoing ||
            transfer.state == FileTransferState.completed);
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
    unawaited(() async {
      final confirmed = await app_dialogs.confirmAction(
        context,
        title: AppLocalizations.of(context)?.timeoutTitle ?? "是否释放连接",
        description: l10n.connectFailed,
        confirmButtonText: AppLocalizations.of(context)?.disconnect ?? "断开",
        cancelButtonText: AppLocalizations.of(context)?.cancel ?? "取消",
      );
      if (confirmed) unawaited(WsSvrManager().close());
      _isAlert = false;
    }());
  }

  @override
  void onNotice(String message) {
    if (!_isCurrentRoute) {
      return;
    }
    showAppToast(
      transferFailureNotice(l10n, message),
      tone: AppToastTone.error,
    );
  }

  @override
  void afterAuth(bool allow, DeviceData? deviceData) {
    if (!mounted || !_isCurrentRoute || !allow || deviceData == null) {
      return;
    }
    if (deviceData.uid != device.uid) {
      if (!embedded && widget.onBack == null) {
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
    // Copies made in the file manager are not part of the conversation.
    if (TransferPlacements.shared.isQuiet(messageData.uuid)) {
      return;
    }
    // Everything sent from here has this device as its sender: only the notes
    // belong in 本机.
    if (_isLocalhost
        ? messageData.receiver.isEmpty
        : messageData.sender == device.uid ||
              messageData.receiver == device.uid) {
      _insertItem(0, messageData);
      unawaited(_loadTransferSnapshotsForMessages(<MessageData>[messageData]));
    }
  }

  @override
  void onTransferUpdated(TransferSnapshot snapshot) {
    if (snapshot.peerUid != device.uid ||
        TransferPlacements.shared.isQuiet(snapshot.transferId)) {
      return;
    }
    if (_isTransferTerminal(snapshot.state)) _knownOnDisk.clear();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_activeTransferId != snapshot.transferId) {
      _speedMeter.reset();
    }
    if (snapshot.state == FileTransferState.transferring) {
      _speedMeter.add(now, snapshot.committedBytes);
      final bytesPerSecond = _speedMeter.bytesPerSecond;
      if (bytesPerSecond != null &&
          now - _speedShownAt >= _transferUiSpeedRefreshMs) {
        _speed = '${formatSize(bytesPerSecond)}/s ';
        _speedShownAt = now;
      }
    }

    if (_isTransferTerminal(snapshot.state)) {
      if (_activeTransferId == snapshot.transferId) {
        _activeTransferId = null;
        percent = 0;
        _speed = '';
        _speedMeter.reset();
        _speedShownAt = 0;
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
