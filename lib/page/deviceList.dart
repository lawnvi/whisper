import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';
import 'package:bonsoir/bonsoir.dart';
import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:dbus/dbus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_group_session.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/cast_receiver/cast_receiver_manager.dart';
import 'package:whisper/cast_receiver/playback_window.dart';
import 'package:whisper/share_links/share_link_store.dart';
import 'package:whisper/new_ui/shell/device_row_status.dart';
import 'package:whisper/new_ui/shell/shell_data.dart';
import 'package:whisper/new_ui/shell/shell_device_card.dart';
import 'package:whisper/new_ui/shell/shell_island_sources.dart';
import 'package:whisper/new_ui/shell/shell_palette.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_phone_device.dart';
import 'package:whisper/new_ui/shell/shell_touch.dart';
import 'package:whisper/page/transfer_assistant.dart';
import 'package:whisper/remote_input/mobile_control_route.dart';
import 'package:whisper/widget/island/island_home.dart';
import 'package:whisper/new_ui/shell/shell_requests.dart';
import 'package:whisper/new_ui/shell/shell_self_panel.dart';
import 'package:whisper/new_ui/shell/shell_share_links.dart';
import 'package:whisper/helper/desktop_screenshot.dart';
import 'package:whisper/new_ui/input/input_controller.dart';
import 'package:whisper/new_ui/input/shell_input_page.dart';
import 'package:whisper/new_ui/settings/whisper_settings.dart';
import 'package:whisper/new_ui/sound/shell_sound_page.dart';
import 'package:whisper/new_ui/sound/sound_controller.dart';
import 'package:whisper/new_ui/shell/whisper_shell.dart';
import 'package:whisper/new_ui/tray/clipboard_history.dart';
import 'package:whisper/new_ui/tray/tray_host.dart';
import 'package:whisper/new_ui/tray/tray_model.dart';
import 'package:whisper/new_ui/shell/shell_connection_check.dart';
import 'package:whisper/page/conversation_drafts.dart';
import 'package:whisper/new_ui/tray/tray_panel.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart'
    show whisperNewUi, WhisperPageRoute, WhisperTheme;
import 'package:whisper/window_stream/remote/remote_peer_source.dart';
import 'package:whisper/helper/android_background.dart';
import 'package:whisper/helper/android_document_picker.dart';
import 'package:whisper/helper/android_system_share.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/helper/windows_system_theme.dart';
import 'package:whisper/helper/transfer_failure_message.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_notification_listener_plus/flutter_notification_listener_plus.dart';
import 'package:flutter_swipe_action_cell/core/cell.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:whisper/audio/audio_failure_reason.dart';
import 'package:whisper/helper/clipboard_sync.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/helper/desktop_quick_send_hotkey.dart';
import 'package:whisper/helper/desktop_window_attention.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/device_form_factor.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local_network_permission.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/helper/whisper_file_picker.dart';
import 'package:whisper/main.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/remote_input/remote_clipboard_transfer.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_peer_activity.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_screen.dart';
import 'package:whisper/state/app_shutdown.dart';
import 'package:whisper/state/android_system_share_inbox.dart';
import 'package:whisper/state/android_system_share_router.dart';
import 'package:whisper/state/chat_session_list.dart';
import 'package:whisper/state/device_list_rules.dart';
import 'package:whisper/state/connection_diagnostic.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/discovery_endpoint_resolver.dart';
import 'package:whisper/state/discovery_resolve_limiter.dart';
import 'package:whisper/state/discovery_service_presence.dart';
import 'package:whisper/state/desktop_quick_send_inbox.dart';
import 'package:whisper/state/notification_app_registry.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/state/connection_models.dart';
import 'package:whisper/state/pairing_invite.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_dialogs.dart' as app_dialogs;
import 'package:whisper/widget/context_menu_region.dart';
import 'package:whisper/widget/desktop_quick_send_dialog.dart';
import 'package:whisper/widget/device_connection_widgets.dart';
import 'package:whisper/widget/device_sidebar_toolbar.dart';
import 'package:whisper/remote_files/fs_placement.dart';
import 'package:whisper/remote_files/mount/remote_mounts.dart';
import 'package:whisper/widget/device_workspace_layout.dart';
import 'package:whisper/widget/server_start_failure_dialog.dart';
import 'package:whisper/widget/glass_bottom_sheet.dart';
import 'package:whisper/widget/quick_send_chooser.dart';
import 'package:whisper/widget/glass_dialog.dart';
import 'package:whisper/widget/pairing_dialog.dart';
import 'package:window_manager/window_manager.dart';
import '../helper/local.dart';
import '../helper/notification.dart';
import '../l10n/app_localizations.dart';
import '../socket/svrmanager.dart';
import 'appList.dart';
import 'conversation.dart';
import 'pairing_qr.dart';
import 'settings.dart' as app_settings;
import '../window_stream/android/phone_identity.dart';
import '../window_stream/window_stream_coordinator.dart';
import 'remote_files/remote_files_page.dart';
import 'window_stream/flow_space_page.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;
import 'package:whisper/widget/subtle_motion.dart';

enum DeviceListOperationKind {
  temporaryFileCleanup,
  androidSystemShareCleanup,
  audioToggle,
  desktopShutdown,
  socketDialog,
  serverStart,
  clipboardWatcher,
}

enum DiscoveryDiagnosticKind {
  broadcastEvent,
  discoveryEvent,
  serviceFound,
  discoveryStarted,
  serviceSkipped,
  serviceResolved,
  serviceLost,
}

/// What a discovery or broadcast event was, for the diagnostic log.
enum DiscoveryEventState {
  started,
  serviceFound,
  serviceResolved,
  serviceUpdated,
  serviceResolveFailed,
  serviceLost,
  nameAlreadyExists,
  stopped,
  unknown;

  static DiscoveryEventState ofDiscovery(BonsoirDiscoveryEvent event) {
    return switch (event) {
      BonsoirDiscoveryStartedEvent() => started,
      BonsoirDiscoveryServiceFoundEvent() => serviceFound,
      BonsoirDiscoveryServiceResolvedEvent() => serviceResolved,
      BonsoirDiscoveryServiceUpdatedEvent() => serviceUpdated,
      BonsoirDiscoveryServiceResolveFailedEvent() => serviceResolveFailed,
      BonsoirDiscoveryServiceLostEvent() => serviceLost,
      BonsoirDiscoveryStoppedEvent() => stopped,
      BonsoirDiscoveryUnknownEvent() => unknown,
    };
  }

  static DiscoveryEventState ofBroadcast(BonsoirBroadcastEvent event) {
    return switch (event) {
      BonsoirBroadcastStartedEvent() => started,
      BonsoirBroadcastNameAlreadyExistsEvent() => nameAlreadyExists,
      BonsoirBroadcastStoppedEvent() => stopped,
      _ => unknown,
    };
  }
}

const String _androidNotificationPortName =
    'whisper.android.notification.forwarding';
ReceivePort? _androidNotificationReceivePort;
StreamSubscription<dynamic>? _androidNotificationSubscription;

@pragma('vm:entry-point')
void androidNotificationListenerCallback(NotificationEvent event) {
  IsolateNameServer.lookupPortByName(_androidNotificationPortName)?.send(event);
}

Future<void> _forwardAndroidNotification(NotificationEvent event) async {
  final forwardingEnabled = await LocalSetting().isListenAndroid();
  if (!forwardingEnabled) {
    privacyLog.event(PrivacyEvent.notificationForwarded, <PrivacyField, Object>{
      PrivacyField.allowed: false,
    });
    return;
  }
  final socketManager = WsSvrManager();
  final allowed =
      socketManager.isConnected &&
      filterNotification(event) &&
      NotificationAppRegistry.instance.containsPackage(event.packageName);
  privacyLog.event(PrivacyEvent.notificationForwarded, <PrivacyField, Object>{
    PrivacyField.allowed: allowed,
  });
  if (allowed) {
    await socketManager.sendNotification(
      event.packageName,
      event.title,
      event.text,
    );
  }
}

void _logDeviceListFailure(DeviceListOperationKind kind, Object error) {
  privacyLog.event(PrivacyEvent.localOperation, <PrivacyField, Object>{
    PrivacyField.kind: kind,
    PrivacyField.success: false,
    PrivacyField.errorType: privacyLog.errorType(error),
  });
}

void _logDiscovery(DiscoveryDiagnosticKind kind, {Enum? state}) {
  privacyLog.event(PrivacyEvent.discoveryState, <PrivacyField, Object>{
    PrivacyField.kind: kind,
    if (state != null) PrivacyField.state: state,
  });
}

String buildWhisperServiceName(String baseName, String uid) {
  final normalizedUid = uid.trim();
  if (normalizedUid.isEmpty) {
    return baseName;
  }
  return "$baseName-$normalizedUid";
}

class _AudioGroupSetupResult {
  const _AudioGroupSetupResult.apply(this.sinks) : shouldStop = false;

  const _AudioGroupSetupResult.stop()
    : shouldStop = true,
      sinks = const <String, AudioChannelRole>{};

  final bool shouldStop;
  final Map<String, AudioChannelRole> sinks;
}

/// What a golden test shows in [DeviceListScreen] instead of starting the
/// server, discovery, the tray and the rest of the app's services.
@visibleForTesting
class DeviceListPreview {
  const DeviceListPreview({
    required this.device,
    required this.sessions,
    this.selectedPeerId,
  });

  final DeviceData device;
  final List<ChatSessionItem> sessions;
  final String? selectedPeerId;
}

class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key, this.debugPreview});

  final DeviceListPreview? debugPreview;

  @override
  _DeviceListScreen createState() => _DeviceListScreen();
}

class _DeviceListScreen extends State<DeviceListScreen>
    with WidgetsBindingObserver
    implements ISocketEvent, TrayListener, WindowListener, ClipboardListener {
  static const double _desktopToolbarPillHeight = 38;

  final db = LocalDatabase();
  final socketManager = WsSvrManager();
  final AudioShareCoordinator _audioCoordinator = AudioShareCoordinator.shared;
  final AudioGroupCoordinator _audioGroupCoordinator =
      AudioGroupCoordinator.shared;
  final RemoteInputCoordinator _remoteInputCoordinator =
      RemoteInputCoordinator.shared;
  final RemoteInputWorkspaceCoordinator _remoteInputWorkspaceCoordinator =
      RemoteInputWorkspaceCoordinator.shared;
  final AndroidSystemShareInbox _androidSystemShareInbox =
      AndroidSystemShareInbox.shared;
  final DesktopQuickSendInbox _desktopQuickSendInbox =
      DesktopQuickSendInbox.shared;
  late final AndroidSystemShareRouter _androidSystemShareRouter;
  late final DesktopQuickSendHotKeyController _desktopQuickSendHotKey;
  DeviceData? device;

  final DeviceListServerStart _serverStart = DeviceListServerStart();
  List<DeviceData> devices = [];
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirBroadcastEvent>? _broadcastSubscription;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySubscription;
  final serviceName = "whisper";
  final serviceType = "_whisper._tcp";
  bool _isBroadcasting = false;
  bool _isDiscovering = false;
  bool _didBootstrapDiscovery = false;
  Timer? _broadcastRestartTimer;
  final DiscoveryResolveLimiter _resolveLimiter = DiscoveryResolveLimiter(
    minimumInterval: const Duration(seconds: 5),
  );
  final DiscoveryServicePresenceTracker _discoveryPresence =
      DiscoveryServicePresenceTracker();
  late final Future<void> _localNetworkPermissionBootstrap;
  var _clipboardText = "";
  var _clipboardSyncGeneration = 0;
  final DesktopClipboardFileReader _clipboardFileReader =
      const DesktopClipboardFileReader();
  final DesktopClipboardImageReader _clipboardImageReader =
      const DesktopClipboardImageReader();
  final TextEditingController _desktopSearchController =
      TextEditingController();
  final FocusNode _desktopSearchFocusNode = FocusNode();

  final WindowsTrayIconWatch _windowsTrayIcon = WindowsTrayIconWatch(
    apply: (asset) => trayManager.setIcon(asset, iconSize: 18),
  );
  final AppShutdownCoordinator _shutdownCoordinator = AppShutdownCoordinator();
  final ConnectionAttemptTracker _connectionAttempts =
      ConnectionAttemptTracker();
  List<ChatSessionItem> _sessionItems = const [];
  String _desktopSearchQuery = "";
  bool _isDesktopSearchExpanded = false;

  /// The toolbar beside the search shows every tool, not just the everyday
  /// ones (and whatever is running).
  bool _toolsExpanded = false;
  String? _selectedDesktopPeerId;
  String? _pendingAutoConnectPeerId;
  Future<void>? _desktopShutdownFuture;
  bool _isDestroyingWindow = false;
  bool _androidSystemShareTargetsLoaded = false;
  bool _androidSystemShareSheetVisible = false;
  bool _androidSystemSharePresentationScheduled = false;
  bool _androidSystemShareRetrying = false;
  final Set<String> _deferredAndroidSystemShareEventIds = <String>{};
  bool _desktopQuickSendTargetsLoaded = false;
  // Connected, trusted devices; open quick send pickers follow it live.
  final ValueNotifier<List<QuickSendTarget>> _quickSendTargets =
      ValueNotifier<List<QuickSendTarget>>(const <QuickSendTarget>[]);
  bool _desktopQuickSendDialogVisible = false;
  bool _desktopQuickSendPresentationScheduled = false;
  String? _lastPresentedDesktopQuickSendDraftId;
  PairingQrDialogController? _activePairingQrController;

  BorderRadius get _desktopToolbarPillRadius => BorderRadius.circular(14);

  Color get _desktopToolbarPillColor => context.whisperPalette.surfaceMuted;

  @override
  void initState() {
    // if (!kIsWeb &&
    //     (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
    //   initSystemTray();
    // }
    final preview = widget.debugPreview;
    if (preview != null) {
      device = preview.device;
      _sessionItems = preview.sessions;
      devices = [for (final session in preview.sessions) session.device];
      _selectedDesktopPeerId = preview.selectedPeerId;
      super.initState();
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    // A file-manager copy's message went away: previews follow.
    TransferPlacements.shared.addListener(_onCopiesChanged);
    _setDesktopWindow();
    _localNetworkPermissionBootstrap = _requestLocalNetworkPermission();
    unawaited(PhoneStreamIdentity.publish());
    unawaited(_requestPermission());
    _desktopSearchFocusNode.addListener(_handleDesktopSearchFocusChanged);
    _audioCoordinator.addListener(_handleDesktopAudioChanged);
    _audioGroupCoordinator.addListener(_handleDesktopAudioChanged);
    if (whisperNewUi) {
      ShellSoundController.shared.onMemberStopped = _noteSoundMemberStopped;
    }
    _remoteInputCoordinator.addListener(
      _handleDesktopRemoteInputWorkspaceChanged,
    );
    _remoteInputWorkspaceCoordinator.addListener(
      _handleDesktopRemoteInputWorkspaceChanged,
    );
    if (Platform.isAndroid) {
      _androidSystemShareRouter = AndroidSystemShareRouter(
        inbox: _androidSystemShareInbox,
        isConnected: socketManager.isConnectedTo,
        trustedIdentityHashFor: _trustedDeviceIdentityHash,
        sendText: _sendAndroidSystemShareText,
        sendItem: _sendAndroidSystemShareItem,
      );
      _androidSystemShareInbox.addListener(_handleAndroidSystemShareChanged);
      unawaited(_initializeAndroidSystemShare());
    }
    if (isDesktop()) {
      _remoteInputCoordinator.configureRemoteClipboard(
        preparePaste: ({required peerId, required sessionId}) => socketManager
            .prepareRemoteClipboardPaste(peerId: peerId, sessionId: sessionId),
        clearSession: ({required peerId, required sessionId}) => socketManager
            .clearRemoteClipboardSession(peerId: peerId, sessionId: sessionId),
      );
      _remoteInputCoordinator.platform.configureLocalPasteHandler(
        _prepareLocalWorkspaceClipboardPaste,
      );
      _desktopQuickSendHotKey = DesktopQuickSendHotKeyController(
        inbox: _desktopQuickSendInbox,
      );
      unawaited(
        _desktopQuickSendInbox.setClipboardCaptureHandler((nativeEntryId) {
          return _desktopQuickSendHotKey.captureClipboard(
            revealWindow: _revealDesktopQuickSendWindow,
            nativeEntryId: nativeEntryId,
          );
        }),
      );
      _desktopQuickSendInbox.addListener(_handleDesktopQuickSendChanged);
      unawaited(_initializeDesktopQuickSend());
    }
    clipboardWatcher.addListener(this);
    unawaited(_syncClipboardWatcher());
    super.initState();
  }

  int _clipboardWatcherGeneration = 0;
  bool? _iosClipboardWatching;

  Future<void> _syncClipboardWatcher() async {
    try {
      if (!Platform.isIOS) {
        await clipboardWatcher.start();
        return;
      }
      final generation = ++_clipboardWatcherGeneration;
      final enabled = await LocalSetting().clipboardAutoSync();
      if (!mounted ||
          generation != _clipboardWatcherGeneration ||
          enabled == _iosClipboardWatching) {
        return;
      }
      _iosClipboardWatching = enabled;
      // The iOS plugin reads the pasteboard as soon as watching starts.
      // Only do that when the user has enabled automatic clipboard sync.
      if (enabled) {
        await clipboardWatcher.start();
      } else {
        await clipboardWatcher.stop();
      }
    } catch (error) {
      _iosClipboardWatching = null;
      _logDeviceListFailure(DeviceListOperationKind.clipboardWatcher, error);
    }
  }

  Future<void> _initializeAndroidSystemShare() async {
    try {
      await db.discardRecoverableOutgoingTransfersWithPathPrefix(
        'content://$androidSystemShareFileProviderAuthority/'
        'android_system_shares/',
      );
    } on Object catch (error) {
      _logDeviceListFailure(
        DeviceListOperationKind.androidSystemShareCleanup,
        error,
      );
    }
    await _androidSystemShareInbox.initialize();
  }

  Future<bool> _prepareLocalWorkspaceClipboardPaste() async {
    final result = await socketManager.prepareLatestWorkspaceClipboardPaste();
    return result != RemoteClipboardPasteResult.failed;
  }

  @override
  void didChangeDependencies() async {
    if (widget.debugPreview != null) {
      super.didChangeDependencies();
      return;
    }
    final isFirst = !_didBootstrapDiscovery;
    _didBootstrapDiscovery = true;
    _refreshDevice(isFirst: isFirst);
    socketManager.registerEvent(this, uid: device?.uid ?? "", primary: true);
    super.didChangeDependencies();
  }

  Future<void> _requestPermission() async {
    if (!isMobile()) {
      return;
    }

    if (Platform.isAndroid) {
      // Pairing alerts, transfer progress, and background-service status all
      // use Android notifications while Whisper is not visible.
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }

      final sdkInt = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      final storagePermission = sdkInt >= 30
          ? Permission.manageExternalStorage
          : Permission.storage;
      if (await storagePermission.isDenied) {
        await storagePermission.request();
      }
      await initPlatformState();
      unawaited(notifyExistingDownloadsVisibleToAndroidPickers());
    }

    if (await LocalSetting().clipboardAutoSync()) {
      _clipboardText = await getClipboardText() ?? '';
    }
  }

  Future<void> _requestLocalNetworkPermission() async {
    if (Platform.isIOS) {
      // Native prompts can suspend rendering, so show the actual app first.
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
      if (!mounted) return;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      await LocalNetworkPermission().ensureGranted();
    }
    if (Platform.isIOS && mounted) {
      unawaited(
        NotificationHelper().requestIOSPermissions().catchError((Object _) {}),
      );
    }
  }

  Future<void> initPlatformState() async {
    await NotificationAppRegistry.instance.refresh();
    if (_androidNotificationReceivePort == null) {
      IsolateNameServer.removePortNameMapping(_androidNotificationPortName);
      final receivePort = ReceivePort();
      if (IsolateNameServer.registerPortWithName(
        receivePort.sendPort,
        _androidNotificationPortName,
      )) {
        _androidNotificationReceivePort = receivePort;
        _androidNotificationSubscription = receivePort.listen((event) {
          if (event is NotificationEvent) {
            unawaited(_forwardAndroidNotification(event));
          }
        });
      } else {
        receivePort.close();
      }
    }
    await NotificationsListener.initialize(
      callbackHandle: androidNotificationListenerCallback,
    );
    if (!await LocalSetting().isListenAndroid()) {
      return;
    }
    if (!await hasAndroidNotificationListenerPermission()) {
      await LocalSetting().setAndroidListen(false);
      return;
    }
    await startAndroidListening(requestPermission: false);
  }

  Future<void> _setDesktopWindow() async {
    if (isMobile()) {
      final cleared = await FilePicker.clearTemporaryFiles();
      privacyLog.event(PrivacyEvent.localOperation, <PrivacyField, Object>{
        PrivacyField.kind: DeviceListOperationKind.temporaryFileCleanup,
        PrivacyField.success: cleared ?? false,
      });
      return;
    }
    await windowManager.setPreventClose(true);
    await _showTrayIcon();

    Menu menu = Menu(
      items: [
        MenuItem(
          key: 'show_window',
          label: AppLocalizations.of(context)?.menuShow ?? "显示",
          onClick: (MenuItem item) {
            windowManager.show();
          },
        ),
        MenuItem(
          key: 'hide_window',
          label: AppLocalizations.of(context)?.menuHide ?? "隐藏",
          onClick: (MenuItem item) {
            windowManager.hide();
          },
        ),
        MenuItem(
          key: 'clipboard',
          label: AppLocalizations.of(context)?.menuClipboard ?? "发送剪切板",
          onClick: (MenuItem item) {
            unawaited(
              _desktopQuickSendHotKey.captureClipboard(
                revealWindow: _revealDesktopQuickSendWindow,
              ),
            );
          },
        ),
        MenuItem(
          key: 'pick_file',
          label: AppLocalizations.of(context)?.menuSendFile ?? "发送文件",
          onClick: (MenuItem item) async {
            FilePickerResult? result = await FilePicker.pickFiles(
              allowMultiple: true,
            );
            if (result != null) {
              await _desktopQuickSendInbox.addSystemShare(
                filePaths: result.files
                    .map((item) => item.path ?? '')
                    .where((path) => path.isNotEmpty),
              );
              await _revealDesktopQuickSendWindow();
            }
          },
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'exit_app',
          label: AppLocalizations.of(context)?.exit ?? '退出',
          onClick: (MenuItem menuItem) async {
            await _shutdownAndDestroyWindow();
          },
        ),
      ],
    );
    await trayManager.setContextMenu(menu);
    trayManager.addListener(this);
    windowManager.addListener(this);
    if (whisperNewUi && trayPanelSupported) {
      _trayPanel = TrayPanelHost(onAction: _onTrayAction);
      unawaited(_trayPanel!.start().then((_) => _pushTrayState()));
    }
  }

  // Future<void> initSystemTray() async {
  //   String path =
  //   Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png';
  //
  //   final AppWindow appWindow = AppWindow();
  //   final SystemTray systemTray = SystemTray();
  //
  //   // We first init the systray menu
  //   await systemTray.initSystemTray(
  //     // title: "whisper",
  //     iconPath: path,
  //   );
  //
  //   // create context menu
  //   final Menu menu = Menu();
  //   await menu.buildFrom([
  //     MenuItemLabel(label: 'Show', onClicked: (menuItem) => appWindow.show()),
  //     MenuItemLabel(label: 'Hide', onClicked: (menuItem) => appWindow.hide()),
  //     MenuItemLabel(label: 'Exit', onClicked: (menuItem) => appWindow.close()),
  //   ]);
  //
  //   // set context menu
  //   await systemTray.setContextMenu(menu);
  //
  //   // handle system tray event
  //   systemTray.registerSystemTrayEventHandler((eventName) {
  //     if (eventName == kSystemTrayEventClick) {
  //       Platform.isWindows ? appWindow.show() : systemTray.popUpContextMenu();
  //     } else if (eventName == kSystemTrayEventRightClick) {
  //       Platform.isWindows ? systemTray.popUpContextMenu() : appWindow.show();
  //     }
  //   });
  // }

  @override
  void dispose() {
    _lanWatch?.cancel();
    if (widget.debugPreview != null) {
      _desktopSearchController.dispose();
      _desktopSearchFocusNode.dispose();
      _quickSendTargets.dispose();
      super.dispose();
      return;
    }
    TransferPlacements.shared.removeListener(_onCopiesChanged);
    ++_clipboardWatcherGeneration;
    // 在这里执行一些清理操作，比如取消订阅、关闭流、释放资源等
    _broadcastRestartTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _connectionAttempts.cancelAll();
    unawaited(_stopDiscovery());
    unawaited(_stopBroadcast());
    _windowsTrayIcon.stop();
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    clipboardWatcher.removeListener(this);
    socketManager.unregisterEvent(this);
    _desktopSearchFocusNode.removeListener(_handleDesktopSearchFocusChanged);
    _audioCoordinator.removeListener(_handleDesktopAudioChanged);
    _audioGroupCoordinator.removeListener(_handleDesktopAudioChanged);
    if (whisperNewUi) ShellSoundController.shared.onMemberStopped = null;
    _remoteInputCoordinator.removeListener(
      _handleDesktopRemoteInputWorkspaceChanged,
    );
    _remoteInputWorkspaceCoordinator.removeListener(
      _handleDesktopRemoteInputWorkspaceChanged,
    );
    if (Platform.isAndroid) {
      _androidSystemShareInbox.removeListener(_handleAndroidSystemShareChanged);
    }
    if (isDesktop()) {
      _desktopQuickSendInbox.removeListener(_handleDesktopQuickSendChanged);
      unawaited(_desktopQuickSendInbox.setClipboardCaptureHandler(null));
      unawaited(_desktopQuickSendHotKey.unregister());
    }
    _desktopSearchController.dispose();
    _desktopSearchFocusNode.dispose();
    _quickSendTargets.dispose();
    // stop watch
    unawaited(clipboardWatcher.stop());
    super.dispose();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (isDesktop()) {
      try {
        // Windows sends the first close request through this callback before
        // window_manager receives the replayed close event. Handle
        // close-to-tray here so that the tray and desktop services are not
        // torn down before the window is hidden.
        if (Platform.isWindows &&
            await LocalSetting().isClose2Tray() &&
            await windowManager.isPreventClose()) {
          await windowManager.hide();
          return AppExitResponse.cancel;
        }
        await _shutdownDesktopResources();
      } catch (error) {
        privacyLog.event(PrivacyEvent.localOperation, <PrivacyField, Object>{
          PrivacyField.kind: DeviceListOperationKind.desktopShutdown,
          PrivacyField.success: false,
          PrivacyField.errorType: privacyLog.errorType(error),
        });
      }
      _endWindowsProcess();
    }
    return AppExitResponse.exit;
  }

  /// On Windows the process is ended here, once everything of ours is
  /// closed, instead of letting the engine take the plugins down.
  ///
  /// Left to the engine, every exit ends in an access violation inside
  /// flutter_windows.dll, and the couple of seconds Windows spends on a
  /// crash are what closing the app seemed to take. It is in the crash
  /// records of 0.0.53 to 0.0.56 and newer plugin versions have not changed
  /// it; which plugin is behind it is not known. Discovery is not stopped
  /// on the way out either, see [_shutdownDesktopResources].
  void _endWindowsProcess() {
    if (Platform.isWindows) {
      exit(0);
    }
  }

  Future<void> _stopClipboardWatcher() async {
    clipboardWatcher.removeListener(this);
    await clipboardWatcher.stop();
  }

  Future<void> _destroyTray() async {
    _windowsTrayIcon.stop();
    trayManager.removeListener(this);
    await trayManager.destroy();
  }

  /// The tray icon is white, which a light Windows taskbar swallows; there
  /// the icon follows the taskbar instead.
  Future<void> _showTrayIcon() async {
    if (Platform.isWindows) {
      await _windowsTrayIcon.start();
      return;
    }
    await trayManager.setIcon(
      'assets/tray_icon.png',
      isTemplate: Platform.isMacOS,
      iconSize: 18,
    );
  }

  void _handleDesktopSearchFocusChanged() {
    if (!_desktopSearchFocusNode.hasFocus) {
      _collapseDesktopSearchIfIdle();
    }
  }

  void _handleDesktopAudioChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _handleDesktopRemoteInputWorkspaceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _initializeDesktopQuickSend() async {
    await _desktopQuickSendInbox.initialize();
    final shouldPresent = _desktopQuickSendInbox.takePresentationRequest();
    if (!shouldPresent && _desktopQuickSendInbox.hasPendingDrafts) {
      _lastPresentedDesktopQuickSendDraftId =
          _desktopQuickSendInbox.drafts.last.id;
    }
    _showPendingDesktopQuickSendRejection();
    final registered = await _desktopQuickSendHotKey.register(
      revealWindow: _revealDesktopQuickSendWindow,
    );
    if (mounted) {
      if (!registered) {
        showAppToast(
          AppLocalizations.of(context)!.desktopQuickSendShortcutUnavailable,
          tone: AppToastTone.warning,
        );
      }
      _scheduleDesktopQuickSendPresentation();
    }
  }

  Future<void> _revealDesktopQuickSendWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  void _handleDesktopQuickSendChanged() {
    if (!mounted) {
      return;
    }
    _showPendingDesktopQuickSendRejection();
    setState(() {});
    _scheduleDesktopQuickSendPresentation();
  }

  void _showPendingDesktopQuickSendRejection() {
    if (!mounted) {
      return;
    }
    final rejection = _desktopQuickSendInbox.takePendingRejection();
    if (rejection == null) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final message = switch (rejection.reason) {
      DesktopQuickSendRejectionReason.draftLimitExceeded =>
        l10n.desktopQuickSendDraftLimit,
      DesktopQuickSendRejectionReason.fileLimitExceeded =>
        l10n.desktopQuickSendFileLimit,
      DesktopQuickSendRejectionReason.textLimitExceeded =>
        l10n.desktopQuickSendTextLimit,
      DesktopQuickSendRejectionReason.pathLimitExceeded ||
      DesktopQuickSendRejectionReason.invalidPath =>
        l10n.desktopQuickSendInvalidPath,
      DesktopQuickSendRejectionReason.clipboardSnapshotUnavailable =>
        l10n.desktopQuickSendClipboardSnapshotUnavailable,
    };
    showAppToast(message, tone: AppToastTone.warning);
    unawaited(_desktopQuickSendInbox.acknowledgePresentedRejection());
  }

  void _scheduleDesktopQuickSendPresentation({bool force = false}) {
    // Sending from the tray panel: the device is chosen already.
    if (_traySending) return;
    if (!isDesktop() ||
        !mounted ||
        !_desktopQuickSendTargetsLoaded ||
        _desktopQuickSendPresentationScheduled ||
        _desktopQuickSendDialogVisible ||
        _desktopQuickSendInbox.isSending ||
        !_desktopQuickSendInbox.hasPendingDrafts) {
      return;
    }
    final latestId = _desktopQuickSendInbox.drafts.last.id;
    if (!force && latestId == _lastPresentedDesktopQuickSendDraftId) {
      return;
    }
    _desktopQuickSendPresentationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _desktopQuickSendPresentationScheduled = false;
      if (mounted) {
        unawaited(_presentDesktopQuickSend(force: force));
      }
    });
  }

  bool _isTrustedDevice(DeviceData candidate) {
    return ConnectionCoordinator().peer(candidate.uid)?.locallyTrusted ??
        (candidate.auth && candidate.identityPublicKey.isNotEmpty);
  }

  String? _trustedDeviceIdentityHash(String peerId) =>
      trustedDeviceIdentityHash(
        devices: devices,
        peerId: peerId,
        isLocallyTrusted: _isTrustedDevice,
      );

  List<QuickSendTarget> _connectedQuickSendTargets() =>
      connectedQuickSendTargets(
        devices: devices,
        isConnected: socketManager.isConnectedTo,
        trustedIdentityHashFor: _trustedDeviceIdentityHash,
      );

  Future<void> _presentDesktopQuickSend({bool force = false}) async {
    if (!mounted ||
        _desktopQuickSendDialogVisible ||
        _desktopQuickSendInbox.isSending ||
        !_desktopQuickSendInbox.hasPendingDrafts) {
      return;
    }
    final latestId = _desktopQuickSendInbox.drafts.last.id;
    if (!force && latestId == _lastPresentedDesktopQuickSendDraftId) {
      return;
    }
    _lastPresentedDesktopQuickSendDraftId = latestId;
    _desktopQuickSendDialogVisible = true;
    String? peerId;
    try {
      _quickSendTargets.value = _connectedQuickSendTargets();
      peerId = await showDesktopQuickSendDialog(
        context,
        drafts: _desktopQuickSendInbox.drafts,
        targets: _quickSendTargets,
        initialPeerId:
            _desktopQuickSendInbox.drafts.first.preferredTargetPeerId ??
            _selectedDesktopPeerId,
      );
    } finally {
      _desktopQuickSendDialogVisible = false;
    }
    if (!mounted || peerId == null) {
      _scheduleDesktopQuickSendPresentation();
      return;
    }
    await _sendDesktopQuickSend(peerId);
    _scheduleDesktopQuickSendPresentation();
  }

  Future<void> _sendDesktopQuickSend(String peerId) async {
    final l10n = AppLocalizations.of(context)!;
    if (!_connectedQuickSendTargets().any(
      (candidate) => candidate.id == peerId,
    )) {
      showAppToast(
        l10n.desktopQuickSendFailedRetained,
        tone: AppToastTone.error,
      );
      return;
    }
    try {
      final result = await _desktopQuickSendInbox.sendPendingTo(
        peerId: peerId,
        trustedIdentityHashFor: _trustedDeviceIdentityHash,
        sendText: (targetPeerId, draftId, pinnedHash, text) =>
            socketManager.sendQuickTextToAcknowledged(
              targetPeerId,
              text,
              source: 'desktop-quick-send',
              intentId: jsonEncode(<String>[draftId, pinnedHash]),
              expectedPublicKeyHash: pinnedHash,
            ),
        sendFile: _sendDesktopQuickSendFile,
      );
      if (!mounted) {
        return;
      }
      final (message, tone) = switch (result.outcome) {
        DesktopQuickSendOutcome.completed => (
          l10n.desktopQuickSendSent,
          AppToastTone.success,
        ),
        DesktopQuickSendOutcome.targetConflict => (
          l10n.desktopQuickSendTargetConflict,
          AppToastTone.warning,
        ),
        DesktopQuickSendOutcome.targetIdentityInvalid => (
          l10n.desktopQuickSendTargetNeedsReselection,
          AppToastTone.warning,
        ),
        DesktopQuickSendOutcome.retained => (
          l10n.desktopQuickSendFailedRetained,
          AppToastTone.error,
        ),
      };
      showAppToast(message, tone: tone);
    } on Object {
      if (mounted) {
        showAppToast(
          l10n.desktopQuickSendFailedRetained,
          tone: AppToastTone.error,
        );
      }
    }
  }

  Future<bool> _sendDesktopQuickSendFile(
    String peerId,
    String fileIntentId,
    String pinnedPublicKeyHash,
    String path,
  ) => socketManager.sendQuickFileToDurably(
    peerId,
    path,
    source: 'desktop-quick-send-file',
    intentId: fileIntentId,
    expectedPublicKeyHash: pinnedPublicKeyHash,
  );

  void _handleAndroidSystemShareChanged() {
    if (mounted) {
      AndroidSystemShareFailure? latestFailure;
      while (true) {
        final failure = _androidSystemShareInbox.takeFailure();
        if (failure == null) {
          break;
        }
        latestFailure = failure;
      }
      if (latestFailure != null) {
        final failure = latestFailure;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          final l10n = AppLocalizations.of(context)!;
          _showAndroidSystemShareToast(
            failure.reason == AndroidSystemShareFailureReason.queueFull
                ? l10n.androidSystemShareQueueFull
                : l10n.androidSystemShareRejected,
            tone: AppToastTone.error,
          );
        });
      }
      final pendingIds = _androidSystemShareInbox.pendingEvents
          .map((event) => event.id)
          .toSet();
      _deferredAndroidSystemShareEventIds.retainAll(pendingIds);
      setState(() {});
      _scheduleAndroidSystemSharePresentation();
    }
  }

  Future<bool> _sendAndroidSystemShareItem(
    String peerId,
    AndroidSystemShareEvent event,
    AndroidSystemShareItem item,
  ) async {
    final pinnedHash = _androidSystemShareInbox
        .event(event.id)
        ?.targetPublicKeyHash;
    if (pinnedHash == null ||
        pinnedHash.isEmpty ||
        _trustedDeviceIdentityHash(peerId) != pinnedHash) {
      return false;
    }
    var size = item.size;
    var name = item.displayName;
    var lastModified = event.receivedAt;
    if (size == null) {
      final metadata = await AndroidDocumentPicker.shared.metadata(item.uri);
      if (metadata == null || metadata.size < 0) {
        return false;
      }
      size = metadata.size;
      if (name.isEmpty) {
        name = metadata.name;
      }
      if (metadata.lastModified > 0) {
        lastModified = metadata.lastModified;
      }
    }
    return socketManager.sendQuickPickedFileToDurably(
      peerId,
      PickedTransferFile(
        name: name,
        size: size,
        lastModified: lastModified,
        androidContentUri: item.uri,
      ),
      source: 'android-system-share-file',
      intentId: jsonEncode(<String>[event.id, item.uri, pinnedHash]),
      expectedPublicKeyHash: pinnedHash,
    );
  }

  Future<bool> _sendAndroidSystemShareText(
    String peerId,
    AndroidSystemShareEvent event,
  ) async {
    final pinnedHash = _androidSystemShareInbox
        .event(event.id)
        ?.targetPublicKeyHash;
    if (pinnedHash == null ||
        pinnedHash.isEmpty ||
        _trustedDeviceIdentityHash(peerId) != pinnedHash) {
      return false;
    }
    return socketManager.sendQuickTextToAcknowledged(
      peerId,
      event.text,
      source: 'android-system-share',
      intentId: jsonEncode(<String>[event.id, pinnedHash]),
      expectedPublicKeyHash: pinnedHash,
    );
  }

  void _scheduleAndroidSystemSharePresentation() {
    if (!Platform.isAndroid ||
        !mounted ||
        !_androidSystemShareTargetsLoaded ||
        _androidSystemSharePresentationScheduled) {
      return;
    }
    _androidSystemSharePresentationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _androidSystemSharePresentationScheduled = false;
      if (mounted) {
        unawaited(_presentNextAndroidSystemShare());
      }
    });
  }

  Future<void> _presentNextAndroidSystemShare() async {
    if (!mounted || _androidSystemShareSheetVisible) {
      return;
    }
    AndroidSystemShareEvent? event;
    for (final candidate in _androidSystemShareInbox.pendingEvents) {
      if (!_deferredAndroidSystemShareEventIds.contains(candidate.id) &&
          _androidSystemShareRouter.targetPeerIdFor(candidate.id) == null) {
        event = candidate;
        break;
      }
    }
    if (event == null) {
      return;
    }
    await _presentAndroidSystemShare(event);
  }

  Future<void> _presentAndroidSystemShare(AndroidSystemShareEvent event) async {
    if (!mounted ||
        _androidSystemShareSheetVisible ||
        _androidSystemShareInbox.event(event.id) == null) {
      return;
    }
    _androidSystemShareSheetVisible = true;
    String? targetPeerId;
    try {
      targetPeerId = await _showAndroidSystemShareTargetSheet(event);
    } finally {
      _androidSystemShareSheetVisible = false;
    }
    if (!mounted || _androidSystemShareInbox.event(event.id) == null) {
      return;
    }
    if (targetPeerId == null) {
      _deferredAndroidSystemShareEventIds.add(event.id);
      _showAndroidSystemShareToast(
        AppLocalizations.of(context)!.androidSystemShareStillPending,
        actionLabel: AppLocalizations.of(
          context,
        )!.androidSystemShareChooseAction,
        onAction: () {
          _deferredAndroidSystemShareEventIds.remove(event.id);
          unawaited(_presentAndroidSystemShare(event));
        },
      );
      _scheduleAndroidSystemSharePresentation();
      return;
    }
    _deferredAndroidSystemShareEventIds.remove(event.id);
    final targetName = _androidSystemShareTargetName(targetPeerId);
    if (socketManager.isConnectedTo(targetPeerId)) {
      _showAndroidSystemShareToast(
        AppLocalizations.of(context)!.androidSystemShareSendingTo(targetName),
      );
    }
    final result = await _androidSystemShareRouter.sendTo(
      event.id,
      targetPeerId,
    );
    if (mounted) {
      _handleAndroidSystemShareRouteResult(result, targetName: targetName);
      _scheduleAndroidSystemSharePresentation();
    }
  }

  Future<String?> _showAndroidSystemShareTargetSheet(
    AndroidSystemShareEvent event,
  ) {
    _quickSendTargets.value = _connectedQuickSendTargets();
    return showQuickSendSheet(
      context,
      items: <QuickSendItem>[
        if (event.text.trim().isNotEmpty) QuickSendItem.text(event.text),
        for (final item in event.items)
          QuickSendItem.file(
            name: item.displayName,
            source: item.uri,
            mimeType: item.mimeType,
            size: item.size,
          ),
      ],
      targets: _quickSendTargets,
    );
  }

  String _androidSystemShareTargetName(String peerId) {
    for (final candidate in devices) {
      if (candidate.uid == peerId) {
        return candidate.name;
      }
    }
    return peerId;
  }

  void _showAndroidSystemShareToast(
    String message, {
    AppToastTone tone = AppToastTone.info,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    showAppToast(
      message,
      tone: tone,
      action: actionLabel == null || onAction == null
          ? null
          : AppToastAction(label: actionLabel, onPressed: onAction),
    );
  }

  void _handleAndroidSystemShareRouteResult(
    AndroidSystemShareRouteResult result, {
    required String targetName,
  }) {
    final l10n = AppLocalizations.of(context)!;
    switch (result.outcome) {
      case AndroidSystemShareRouteOutcome.completed:
        _showAndroidSystemShareToast(
          l10n.androidSystemShareSentTo(targetName),
          tone: AppToastTone.success,
        );
        break;
      case AndroidSystemShareRouteOutcome.waitingForConnection:
        _showAndroidSystemShareToast(
          l10n.androidSystemShareWaitingForDevice(targetName),
        );
        break;
      case AndroidSystemShareRouteOutcome.failed ||
          AndroidSystemShareRouteOutcome.targetConflict:
        _showAndroidSystemShareToast(
          l10n.androidSystemShareFailedRetained,
          tone: AppToastTone.error,
          actionLabel: l10n.retry,
          onAction: () => unawaited(_retryAndroidSystemShare(result.eventId)),
        );
        break;
      case AndroidSystemShareRouteOutcome.targetIdentityInvalid:
        _deferredAndroidSystemShareEventIds.add(result.eventId);
        _showAndroidSystemShareToast(
          l10n.androidSystemShareTargetNeedsReselection,
          tone: AppToastTone.warning,
          actionLabel: l10n.androidSystemShareChooseAction,
          onAction: () {
            _deferredAndroidSystemShareEventIds.remove(result.eventId);
            final event = _androidSystemShareInbox.event(result.eventId);
            if (event != null) {
              unawaited(_presentAndroidSystemShare(event));
            }
          },
        );
        break;
      case AndroidSystemShareRouteOutcome.missingEvent:
        break;
    }
  }

  Future<void> _retryAndroidSystemShare(String eventId) async {
    if (!mounted || _androidSystemShareInbox.event(eventId) == null) {
      return;
    }
    final peerId = _androidSystemShareRouter.targetPeerIdFor(eventId);
    if (peerId == null) {
      _scheduleAndroidSystemSharePresentation();
      return;
    }
    final targetName = _androidSystemShareTargetName(peerId);
    if (socketManager.isConnectedTo(peerId)) {
      _showAndroidSystemShareToast(
        AppLocalizations.of(context)!.androidSystemShareSendingTo(targetName),
      );
    }
    final result = await _androidSystemShareRouter.retry(eventId);
    if (mounted) {
      _handleAndroidSystemShareRouteResult(result, targetName: targetName);
    }
  }

  Future<void> _retryConnectedAndroidSystemShares() async {
    if (!Platform.isAndroid || _androidSystemShareRetrying) {
      return;
    }
    _androidSystemShareRetrying = true;
    try {
      final results = await _androidSystemShareRouter.retryConnected();
      if (!mounted) {
        return;
      }
      for (final result in results) {
        _handleAndroidSystemShareRouteResult(
          result,
          targetName: _androidSystemShareTargetName(result.peerId),
        );
      }
    } finally {
      _androidSystemShareRetrying = false;
    }
  }

  void _expandDesktopSearch() {
    if (_isDesktopSearchExpanded) {
      _desktopSearchFocusNode.requestFocus();
      return;
    }
    setState(() {
      _isDesktopSearchExpanded = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _desktopSearchFocusNode.requestFocus();
      }
    });
  }

  void _collapseDesktopSearchIfIdle() {
    if (!_isDesktopSearchExpanded ||
        _desktopSearchFocusNode.hasFocus ||
        _desktopSearchController.text.isNotEmpty) {
      return;
    }
    setState(() {
      _isDesktopSearchExpanded = false;
    });
  }

  String _serviceResolveKey(BonsoirService service) {
    return '${service.name}|${service.type}';
  }

  bool _shouldResolveService(BonsoirService service) {
    return _resolveLimiter.shouldResolve(_serviceResolveKey(service));
  }

  Future<void> _stopSocketServer() async {
    await AndroidBackgroundKeepAliveCoordinator.shared.setReason(
      AndroidKeepAliveReason.lanServer,
      false,
    );
    await socketManager.closeGracefully(
      closeServer: true,
      forceServerClose: true,
    );
  }

  Future<void> _closeDatabase() async {
    await db.close();
  }

  Future<void> _shutdownDesktopResources() {
    return _desktopShutdownFuture ??= _shutdownCoordinator.run([
      CastReceiverManager.shared.stop,
      ShareLinkStore.shared.shutdown,
      PlaybackWindowBridge.videos.close,
      WindowStreamCoordinator.shared.shutdown,
      RemoteMounts.shared.unmountAll,
      // Left running on Windows: the process ends right after the rest,
      // and with older versions of the plugin the stop itself crashed. See
      // [_endWindowsProcess].
      if (!Platform.isWindows) _stopDiscovery,
      _stopBroadcast,
      _stopClipboardWatcher,
      _stopSocketServer,
      _closeDatabase,
      _destroyTray,
    ]);
  }

  Future<void> _shutdownAndDestroyWindow() async {
    if (_isDestroyingWindow) {
      return;
    }
    _isDestroyingWindow = true;
    try {
      await _shutdownDesktopResources();
    } finally {
      _endWindowsProcess();
    }
    await windowManager.destroy();
  }

  void _broadcastService({port}) async {
    final wifiIP = await getLocalIpAddress();
    if (!mounted) return;

    if (wifiIP == "127.0.0.1") {
      _isBroadcasting = false;
      return;
    }

    await _stopBroadcast(close: false);
    if (!mounted) return;
    final name = device?.name ?? await deviceName();
    if (!mounted) return;
    BonsoirService service = BonsoirService(
      name: buildWhisperServiceName(serviceName, device?.uid ?? ""),
      type: serviceType,
      port: 10004,
      attributes: {
        'host': wifiIP,
        'port': (port ?? device?.port ?? 10002).toString(),
        'name': name,
        'platform': device?.platform ?? "未知",
        'uid': device?.uid ?? "",
      },
    );

    // And now we can broadcast it :
    final broadcast = BonsoirBroadcast(service: service);
    _broadcast = broadcast;
    await broadcast.initialize();
    if (!mounted || !identical(_broadcast, broadcast)) {
      await broadcast.stop();
      return;
    }

    _broadcastSubscription?.cancel();
    _broadcastSubscription = broadcast.eventStream!.listen((event) {
      _logDiscovery(
        DiscoveryDiagnosticKind.broadcastEvent,
        state: DiscoveryEventState.ofBroadcast(event),
      );
    });

    await broadcast.start();
    if (mounted && identical(_broadcast, broadcast)) _isBroadcasting = true;
  }

  Future<void> _stopBroadcast({close = true}) async {
    _broadcastRestartTimer?.cancel();
    _broadcastRestartTimer = null;
    final subscription = _broadcastSubscription;
    final broadcast = _broadcast;
    _broadcastSubscription = null;
    _broadcast = null;
    _isBroadcasting = !close;
    await subscription?.cancel();
    await broadcast?.stop();
  }

  Future<void> _discoverService() async {
    await _stopDiscovery();
    if (!mounted) return;
    // This is the type of service we're looking for :

    // Once defined, we can start the discovery :
    final discovery = BonsoirDiscovery(type: serviceType, printLogs: false);
    _discovery = discovery;
    await discovery.initialize();
    if (!mounted || !identical(_discovery, discovery)) {
      await discovery.stop();
      return;
    }

    // If you want to listen to the discovery :
    _discoverySubscription?.cancel();
    _discoverySubscription = discovery.eventStream!.listen((event) async {
      if (!mounted || !identical(_discovery, discovery)) return;
      _logDiscovery(
        DiscoveryDiagnosticKind.discoveryEvent,
        state: DiscoveryEventState.ofDiscovery(event),
      );
      // `eventStream` is not null as the discovery instance is "ready" !
      final service = event.service;
      if (service != null) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent():
            _logDiscovery(DiscoveryDiagnosticKind.serviceFound);
            if (service.name.startsWith(serviceName) &&
                _shouldResolveService(service)) {
              unawaited(service.resolve(discovery.serviceResolver));
            }
            break;
          case BonsoirDiscoveryStartedEvent():
            _logDiscovery(DiscoveryDiagnosticKind.discoveryStarted);
            break;
          // An update carries what changed since the service was resolved,
          // its TXT record or its addresses, and is taken the same way.
          case BonsoirDiscoveryServiceResolvedEvent() ||
              BonsoirDiscoveryServiceUpdatedEvent() ||
              BonsoirDiscoveryServiceLostEvent():
            final svr = service;
            final isLost = event is BonsoirDiscoveryServiceLostEvent;
            final serviceKey = _serviceResolveKey(svr);
            final advertisedUid = svr.attributes['uid'];
            final String uid;
            if (isLost) {
              _resolveLimiter.clear(serviceKey);
              final loss = _discoveryPresence.lost(
                serviceKey: serviceKey,
                peerIdHint: advertisedUid,
              );
              if (loss == null) {
                _logDiscovery(DiscoveryDiagnosticKind.serviceSkipped);
                return;
              }
              if (loss.stillDiscovered) {
                return;
              }
              uid = loss.peerId;
            } else {
              if (advertisedUid == null || advertisedUid.isEmpty) {
                _logDiscovery(DiscoveryDiagnosticKind.serviceSkipped);
                return;
              }
              uid = advertisedUid;
              _discoveryPresence.resolved(serviceKey: serviceKey, peerId: uid);
            }
            var host = svr.attributes["host"];
            final port =
                int.tryParse(svr.attributes["port"] ?? "10002") ?? 10002;
            if (!isLost) {
              host = await resolveDiscoveryEndpointHost(
                resolvedHost: svr.hostname,
                resolvedAddresses: svr.hostAddresses,
                advertisedHost: host,
                port: port,
              );
              if (!mounted || !identical(_discovery, discovery)) return;
              if (host == null) {
                _logDiscovery(DiscoveryDiagnosticKind.serviceSkipped);
                return;
              }
            }
            final name = svr.attributes["name"];
            final platform = svr.attributes["platform"];
            _logDiscovery(
              isLost
                  ? DiscoveryDiagnosticKind.serviceLost
                  : DiscoveryDiagnosticKind.serviceResolved,
            );
            if (uid == device?.uid) {
              return;
            }
            if (socketManager.shouldSuppressDiscoveredPeer(uid)) {
              if (isLost) {
                socketManager.releaseDeletedPeerDiscoverySuppression(uid);
              }
              if (mounted) {
                setState(() {
                  devices.removeWhere((item) => item.uid == uid);
                  _sessionItems = _sessionItems
                      .where((item) => item.device.uid != uid)
                      .toList(growable: false);
                  if (_selectedDesktopPeerId == uid) {
                    _selectedDesktopPeerId = null;
                  }
                });
              }
              return;
            }
            final temp = await db.fetchDevice(uid);
            if (!mounted || !identical(_discovery, discovery)) return;
            if (isLost && temp == null) {
              return;
            }
            final resolvedDevice = buildDevice(
              uid: uid,
              name: temp?.name ?? name ?? '',
              port: port,
              host: host ?? temp?.host ?? '',
              platform: platform ?? temp?.platform ?? '',
              around: !isLost,
            );
            final visibleDevice = mergeStoredDeviceWithDiscovery(
              temp,
              resolvedDevice,
            );
            if (!isLost) {
              await db.upsertDevice(visibleDevice);
            }
            await db.setDeviceDiscoveryPresence(uid, !isLost);
            await ConnectionCoordinator().updateDiscovery(
              visibleDevice,
              discovered: !isLost,
            );
            if (!mounted || !identical(_discovery, discovery)) return;
            if (!isLost && host != null) {
              try {
                socketManager.updateReconnectEndpoint(uid, host, port);
              } on ArgumentError {
                // Invalid discovery endpoints are never promoted to retries.
              }
            }
            setState(() {
              devices.removeWhere((item) => item.uid == uid);
              if (!isLost) {
                devices.insert(0, visibleDevice);
              }
            });
            _refreshDevice();
            if (!isLost) {
              await _attemptAutoConnect();
            }
            break;
          case BonsoirDiscoveryServiceResolveFailedEvent():
          // TODO: Handle this case.
          case BonsoirDiscoveryStoppedEvent():
          // TODO: Handle this case.
          case BonsoirDiscoveryUnknownEvent():
          // TODO: Handle this case.
        }
      }
    });

    // Start discovery **after** having listened to discovery events :
    await discovery.start();
    if (mounted && identical(_discovery, discovery)) _isDiscovering = true;
  }

  Future<void> _stopDiscovery() async {
    final subscription = _discoverySubscription;
    final discovery = _discovery;
    _discoverySubscription = null;
    _discovery = null;
    _discoveryPresence.clear();
    _isDiscovering = false;
    await subscription?.cancel();
    await discovery?.stop();
  }

  DeviceData buildDevice({
    uid = "",
    name = "",
    host = "",
    port = 10002,
    platform = "",
    around = true,
  }) {
    return DeviceData(
      id: 0,
      uid: uid,
      name: name,
      host: host,
      port: port,
      platform: platform,
      isServer: false,
      lastTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      online: false,
      password: "",
      clipboard: false,
      auth: false,
      around: around,
    );
  }

  void _onCopiesChanged() => unawaited(_refreshDevice());

  Future<void> _refreshDevice({isFirst = false}) async {
    if (!mounted) return;
    if (Platform.isIOS) unawaited(_syncClipboardWatcher());
    if (isFirst) {
      await _localNetworkPermissionBootstrap;
      if (!mounted) {
        return;
      }
    }
    var temp = await LocalSetting().instance();
    if (isFirst) {
      await db.clearDeviceDiscoveryPresence();
    }
    var arr = (await db.fetchAllDevice())
        .where((item) => !socketManager.shouldSuppressDiscoveredPeer(item.uid))
        .toList(growable: false);
    final storedDevicesByUid = <String, DeviceData>{
      for (final item in arr) item.uid: item,
    };
    await ConnectionCoordinator().bootstrap(temp.uid);
    await ConnectionCoordinator().syncKnownDevices(arr);
    if (!mounted) return;
    var newArr = <DeviceData>[];
    var aroundIds = <String>{};
    for (var item in devices) {
      if (socketManager.shouldSuppressDiscoveredPeer(item.uid)) {
        continue;
      }
      if (aroundIds.contains(item.uid)) {
        continue;
      }
      if (socketManager.isConnectedTo(item.uid)) {
        newArr.insert(
          0,
          mergeStoredDeviceWithDiscovery(storedDevicesByUid[item.uid], item),
        );
        aroundIds.add(item.uid);
        continue;
      }
      if (item.around == true) {
        newArr.add(item);
        aroundIds.add(item.uid);
      }
    }

    for (var item in arr) {
      if (aroundIds.contains(item.uid)) {
        continue;
      }
      newArr.add(item);
    }

    socketManager.setSender(temp.uid);

    var serverPortUpdate = device != null && device!.port != temp.port;
    var localProfileUpdate = device != null && device!.name != temp.name;

    if (_serverStart.shouldStart(isFirst: isFirst, port: temp.port)) {
      await _startServer(port: temp.port);
    }

    final latestMessages = await db.fetchLatestMessagesByPeers(
      newArr.map((item) => item.uid).toList(),
    );
    if (!mounted) return;
    final sessions = ChatSessionListBuilder.build(
      devices: newArr,
      latestMessages: latestMessages,
      activePeerId: socketManager.receiver.isEmpty
          ? null
          : socketManager.receiver,
      connectedPeerIds: socketManager.connectedPeerIds,
      selectedPeerId: _selectedDesktopPeerId,
      strings: _sessionPreviewStrings(context),
    );
    final selectedPeerId =
        _selectedDesktopPeerId != null &&
            sessions.any((item) => item.device.uid == _selectedDesktopPeerId)
        ? _selectedDesktopPeerId
        : null;

    if (!mounted) {
      return;
    }
    setState(() {
      device = temp;
      devices = newArr;
      _sessionItems = sessions;
      _selectedDesktopPeerId = selectedPeerId;
      _androidSystemShareTargetsLoaded = true;
      _desktopQuickSendTargetsLoaded = true;
    });
    _quickSendTargets.value = _connectedQuickSendTargets();

    if (Platform.isAndroid) {
      _scheduleAndroidSystemSharePresentation();
      unawaited(_retryConnectedAndroidSystemShares());
    }
    if (isDesktop()) {
      _scheduleDesktopQuickSendPresentation();
    }

    if (localProfileUpdate) {
      unawaited(socketManager.broadcastLocalProfileUpdate());
    }
    if (!_isBroadcasting || serverPortUpdate || localProfileUpdate) {
      _isBroadcasting = true;
      _broadcastRestartTimer?.cancel();
      _broadcastRestartTimer = Timer(const Duration(milliseconds: 100), () {
        _broadcastRestartTimer = null;
        _broadcastService();
      });
    }
    if (isFirst && !_isDiscovering) {
      _discoverService();
    }
  }

  ChatSessionPreviewStrings _sessionPreviewStrings(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ChatSessionPreviewStrings(
      connectedNow: l10n?.connectedNow ?? '当前已连接',
      nearbyAvailable: l10n?.nearbyAvailable ?? '附近可连接',
      noMessagesYet: l10n?.noMessagesYet ?? '还没有消息',
      sharedFile: l10n?.sharedFile ?? '发送了一个文件',
    );
  }

  List<ChatSessionItem> _visibleSessions() {
    return ChatSessionListBuilder.filter(_sessionItems, _desktopSearchQuery);
  }

  ChatSessionItem? _selectedDesktopSession() {
    if (_selectedDesktopPeerId == null) {
      return null;
    }
    for (final item in _sessionItems) {
      if (item.device.uid == _selectedDesktopPeerId) {
        return item;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (whisperNewUi) {
      return ListenableBuilder(
        listenable: _shellInputs,
        builder: (context, _) {
          _watchLan();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _pushTrayState();
            unawaited(_refreshLinuxTrayMenu());
            if (mounted) _updateStatusMoments(context);
          });
          return WhisperShell(data: _shellData(), actions: _shellActions);
        },
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final split = usesSplitDeviceWorkspace(
          width: constraints.maxWidth,
          desktop: isDesktop(),
          ios: Platform.isIOS,
        );
        if (split ||
            (_usesTabletWorkspace && _selectedDesktopSession() != null)) {
          return _buildDesktopScaffold(isDark, compact: !split);
        }
        return _buildMobileScaffold(isDark);
      },
    );
  }

  // ---- The tray panel. Its own engine: all it knows crosses from here. ----

  TrayPanelHost? _trayPanel;
  bool _traySending = false;
  final ClipboardHistory _clipHistory = ClipboardHistory();
  String _lastTrayState = '';

  /// The platforms where the system's mark for passwords can be read. Elsewhere
  /// there is no history at all: a password must not end up in it.
  static const _windowTheme = MethodChannel('com.vireen.whisper/window_theme');

  Future<void> _recordClipboard() async {
    if (!trayPanelSupported) return;
    bool sensitive;
    try {
      sensitive =
          await _windowTheme.invokeMethod<bool>('clipboardIsSensitive') ?? true;
    } on Object {
      return;
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || !mounted) return;
    _clipHistory.add(
      ClipEntry(text: text, from: '', at: DateTime.now()),
      sensitive: sensitive,
    );
    _pushTrayState();
  }

  TrayDevice _trayDevice(DeviceData peer) => TrayDevice(
    id: peer.uid,
    name: peer.name,
    platform: peer.platform,
    order: peer.id,
  );

  void _pushTrayState() {
    final panel = _trayPanel;
    if (panel == null || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final group = _audioGroupCoordinator.session;
    String nameOf(String uid) {
      for (final session in _sessionItems) {
        if (session.device.uid == uid) return session.device.name;
      }
      return uid;
    }

    final soundMembers = group?.isLive == true
        ? [
            for (final sink in group!.sinks.values)
              if (!sink.isTerminal) nameOf(sink.sinkPeerId),
          ]
        : const <String>[];
    final playing = _audioGroupCoordinator.isPlaybackActive
        ? nameOf(_audioGroupCoordinator.playbackSourcePeerId)
        : null;
    final workspace = _remoteInputWorkspaceCoordinator.snapshot;
    final controlled = workspace.role == RemoteInputWorkspaceRole.controlled;
    final active = _remoteInputCoordinator.state.peerId;
    final inputLive = switch (workspace.status) {
      RemoteInputWorkspaceStatus.active ||
      RemoteInputWorkspaceStatus.armed => true,
      _ => false,
    };
    final moments = <TrayMoment>[
      for (final activity in RequestIslandSource.shared.activities)
        if (activity.presenter case final RequestPresenter ask)
          TrayMoment(
            id: activity.id,
            title: ask.title,
            detail: ask.detail,
            answers: [for (final a in ask.answers) a.label],
          ),
      for (final entry in _shellTransfers.entries)
        if (switch (entry.value.state) {
          FileTransferState.queued ||
          FileTransferState.negotiating ||
          FileTransferState.transferring ||
          FileTransferState.verifying => true,
          _ => false,
        })
          TrayMoment(
            id: entry.value.transferId,
            title: entry.value.finalPath.split(RegExp(r'[/\\]')).last,
            detail:
                '${nameOf(entry.key)} · '
                '${entry.value.size > 0 ? (entry.value.committedBytes * 100 ~/ entry.value.size).clamp(0, 100) : 0}%',
            progress: entry.value.size > 0
                ? (entry.value.committedBytes / entry.value.size).clamp(0, 1)
                : 0,
            cancelable: true,
          ),
    ];
    final clips = _clipHistory.entries;
    final state = TrayState(
      dark: Theme.of(context).brightness == Brightness.dark,
      locale: Localizations.localeOf(context).languageCode,
      current: _clipHistory.current,
      targets: [
        for (final session in _sessionItems)
          if (session.isConnected) _trayDevice(session.device),
      ],
      nearby: [
        for (final session in _sessionItems)
          if (!session.isConnected && session.isNearby)
            _trayDevice(session.device),
      ],
      moments: moments,
      soundOn: soundMembers.isNotEmpty || playing != null,
      soundStatus: playing != null
          ? l10n.shellTrayPlaying(playing)
          : soundMembers.isEmpty
          ? l10n.shellTraySoundOff
          : soundMembers.join('、'),
      inputOn: inputLive || controlled,
      inputStatus: controlled
          ? l10n.shellTrayControlled(nameOf(active))
          : inputLive
          ? l10n.shellTrayInputOn
          : l10n.shellTraySoundOff,
      flows: [
        for (final session in WindowStreamCoordinator.shared.sessions)
          if (!session.state.isTerminal)
            TrayFlow(
              id: session.id,
              title: session.handle.title,
              detail: session.handle.source.info.name,
              action: l10n.shellAppsEnd,
            ),
      ],
      clips: [
        for (final clip in clips)
          TrayClip(
            text: clip.text,
            line: clip.from.isEmpty
                ? l10n.shellTrayFrom(
                    l10n.shellTrayThisDevice,
                    _formatClipTime(clip.at),
                  )
                : l10n.shellTrayFrom(clip.from, _formatClipTime(clip.at)),
            image: clip.image,
          ),
      ],
    );
    final encoded = jsonEncode(state.toMap());
    if (encoded == _lastTrayState) return;
    _lastTrayState = encoded;
    panel.update(state);
  }

  /// surfaces.md「Linux 只有菜单」: AppIndicator gets no left click and Wayland
  /// cannot place a window beside the icon, so what the panel holds goes into the
  /// menu, in the same order. Set again whenever it changes.
  String _lastLinuxMenu = '';

  Future<void> _refreshLinuxTrayMenu() async {
    if (!whisperNewUi || !Platform.isLinux || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final connected = [
      for (final session in _sessionItems)
        if (session.isConnected) session.device,
    ];
    final sound = ShellSoundController.shared;
    final sink = sound.sinkView;
    final input = ShellInputController.shared;
    final asks = [
      for (final activity in RequestIslandSource.shared.activities)
        if (activity.presenter is RequestPresenter)
          activity.presenter as RequestPresenter,
    ];
    final moving = [
      for (final transfer in _shellTransfers.values)
        if (switch (transfer.state) {
          FileTransferState.queued ||
          FileTransferState.negotiating ||
          FileTransferState.transferring ||
          FileTransferState.verifying => true,
          _ => false,
        })
          transfer,
    ];
    final flows = [
      for (final session in WindowStreamCoordinator.shared.sessions)
        if (!session.state.isTerminal) session,
    ];
    final signature = jsonEncode([
      connected.map((d) => '${d.uid}${d.name}').toList(),
      asks.map((a) => a.title).toList(),
      moving
          .map(
            (t) =>
                '${t.transferId}:${t.size > 0 ? t.committedBytes * 20 ~/ t.size : 0}',
          )
          .toList(),
      sound.selection.keys.toList(),
      sink != null,
      input.on,
      input.controlledBy,
      flows.map((f) => f.id).toList(),
      Localizations.localeOf(context).toLanguageTag(),
    ]);
    if (signature == _lastLinuxMenu) return;
    _lastLinuxMenu = signature;
    String percent(TransferSnapshot t) => t.size > 0
        ? '${(t.committedBytes * 100 ~/ t.size).clamp(0, 100)}%'
        : '';
    String nameOf(String uid) {
      for (final session in _sessionItems) {
        if (session.device.uid == uid) return session.device.name;
      }
      return uid;
    }

    Future<void> pickAndSend(String peerId) async {
      final picked = await FilePicker.pickFiles(allowMultiple: true);
      if (picked == null) return;
      for (final file in picked.files) {
        final path = file.path;
        if (path != null) await socketManager.sendFileTo(peerId, path);
      }
    }

    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            label: l10n.shellTrayOpen,
            onClick: (_) => unawaited(_showMainWindow()),
          ),
          MenuItem.separator(),
          for (final ask in asks)
            MenuItem(
              label: ask.title,
              onClick: (_) => unawaited(_showMainWindow()),
            ),
          for (final transfer in moving)
            MenuItem(
              label:
                  '${transfer.finalPath.split(RegExp(r'[/\\]')).last} · '
                  '${nameOf(transfer.peerUid)} · ${percent(transfer)}',
              disabled: true,
            ),
          if (asks.isNotEmpty || moving.isNotEmpty) MenuItem.separator(),
          if (connected.isNotEmpty) ...[
            MenuItem.submenu(
              label: l10n.shellTraySendClipboardTo,
              submenu: Menu(
                items: [
                  for (final peer in connected)
                    MenuItem(
                      label: peer.name,
                      onClick: (_) => unawaited(_traySendClipboard(peer.uid)),
                    ),
                ],
              ),
            ),
            MenuItem.submenu(
              label: l10n.shellTraySendFileTo,
              submenu: Menu(
                items: [
                  for (final peer in connected)
                    MenuItem(
                      label: peer.name,
                      onClick: (_) => unawaited(pickAndSend(peer.uid)),
                    ),
                ],
              ),
            ),
          ],
          MenuItem(
            label: l10n.shellTrayScreenshot,
            onClick: (_) =>
                unawaited(DesktopScreenshotController.shared.capture()),
          ),
          MenuItem.separator(),
          if (sink != null)
            MenuItem(
              label: l10n.shellTrayPlaying(nameOf(sink.sourcePeerId)),
              onClick: (_) => unawaited(_showMainWindow()),
            )
          else if (connected.isNotEmpty && supportsNativeSystemAudio())
            MenuItem.submenu(
              label: l10n.shellTrayPlayOn,
              submenu: Menu(
                items: [
                  for (final peer in connected)
                    MenuItem.checkbox(
                      label: peer.name,
                      checked: sound.isSelected(peer.uid),
                      onClick: (_) => unawaited(sound.toggle(peer.uid)),
                    ),
                ],
              ),
            ),
          if (input.controlledBy case final controller?)
            MenuItem(
              label: l10n.shellTrayControlled(nameOf(controller)),
              onClick: (_) => unawaited(input.stopBeingControlled()),
            )
          else if (supportsNativeRemoteInput())
            MenuItem.checkbox(
              label: l10n.shellInput,
              checked: input.on,
              onClick: (_) => unawaited(input.setOn(!input.on)),
            ),
          if (flows.isNotEmpty)
            MenuItem.submenu(
              label: l10n.shellAppsMoving,
              submenu: Menu(
                items: [
                  for (final session in flows)
                    MenuItem(
                      label: '${session.handle.title} · ${l10n.shellAppsEnd}',
                      onClick: (_) => unawaited(
                        WindowStreamCoordinator.shared.close(session),
                      ),
                    ),
                ],
              ),
            ),
          MenuItem.separator(),
          MenuItem(
            label: l10n.shellSettings,
            onClick: (_) {
              unawaited(_showMainWindow());
              _shellActions.openSettings();
            },
          ),
          MenuItem(
            label: AppLocalizations.of(context)?.exit ?? '退出',
            onClick: (_) => unawaited(_shutdownAndDestroyWindow()),
          ),
        ],
      ),
    );
  }

  /// A desktop with no status notifier (plain GNOME without the extension) never
  /// shows the icon: hiding to the tray there would lose the window for good.
  bool? _hasStatusNotifier;

  Future<bool> _statusNotifierAvailable() async {
    final known = _hasStatusNotifier;
    if (known != null) return known;
    if (!Platform.isLinux) return _hasStatusNotifier = true;
    final client = DBusClient.session();
    try {
      final reply = await client.callMethod(
        destination: 'org.freedesktop.DBus',
        path: DBusObjectPath('/org/freedesktop/DBus'),
        interface: 'org.freedesktop.DBus',
        name: 'NameHasOwner',
        values: [const DBusString('org.kde.StatusNotifierWatcher')],
        replySignature: DBusSignature('b'),
      );
      return _hasStatusNotifier = (reply.values.first as DBusBoolean).value;
    } on Object {
      // Cannot tell: keep what the setting says, as before.
      return true;
    } finally {
      await client.close();
    }
  }

  String _formatClipTime(DateTime at) =>
      _formatSessionTime(at.millisecondsSinceEpoch ~/ 1000);

  Future<void> _showMainWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  void _onTrayAction(String action, Object? value) {
    final actions = _shellActions;
    switch (action) {
      case 'send':
        unawaited(_traySendClipboard(value! as String));
      case 'screenshot':
        unawaited(DesktopScreenshotController.shared.capture());
      case 'clipCopy':
        _clipHistory.markCurrent(value! as String);
        unawaited(Clipboard.setData(ClipboardData(text: value as String)));
        _pushTrayState();
      case 'cancel':
        unawaited(socketManager.cancelTransfer(value! as String));
      case 'answer':
        final args = Map<String, dynamic>.from(value! as Map);
        for (final activity in RequestIslandSource.shared.activities) {
          if (activity.id == args['id'] &&
              activity.presenter is RequestPresenter) {
            (activity.presenter as RequestPresenter)
                .answers[args['index'] as int]
                .onTap();
          }
        }
        _pushTrayState();
      case 'endFlow':
        for (final session in WindowStreamCoordinator.shared.sessions) {
          if (session.id == value) {
            unawaited(WindowStreamCoordinator.shared.close(session));
          }
        }
      case 'connect':
        for (final session in _sessionItems) {
          if (session.device.uid == value) actions.connect(session.device);
        }
      case 'openSound':
        unawaited(_showMainWindow());
        actions.openSound();
      case 'openInput':
        unawaited(_showMainWindow());
        actions.openInput();
      case 'openSettings':
        unawaited(_showMainWindow());
        actions.openSettings();
      case 'connectNew':
        unawaited(_showMainWindow());
        unawaited(actions.openPairing());
      case 'openMain':
        unawaited(_showMainWindow());
    }
  }

  /// One click sends: no chooser, the device has been picked.
  Future<void> _traySendClipboard(String peerId) async {
    _traySending = true;
    try {
      final result = await _desktopQuickSendHotKey.captureClipboard(
        revealWindow: () async {},
      );
      if (result.isAccepted) await _sendDesktopQuickSend(peerId);
    } finally {
      _traySending = false;
    }
  }

  // ---- The redesigned shell. Everything it does comes from here. ----

  /// Running or last known file transfers, by peer.
  final Map<String, TransferSnapshot> _shellTransfers = {};

  ShellPlace _shellPlace = ShellPlace.device;
  bool _lanDown = false;
  Timer? _lanWatch;

  /// A cable or Wi-Fi going away has no event of its own here: look now and then.
  void _watchLan() {
    _lanWatch ??= Timer.periodic(const Duration(seconds: 10), (_) async {
      final host = await getLocalIpAddress();
      final down = host.isEmpty || host == '127.0.0.1';
      if (mounted && down != _lanDown) setState(() => _lanDown = down);
    });
  }

  void _updateStatusMoments(BuildContext context) {
    if (!isDesktop()) return;
    final l10n = AppLocalizations.of(context)!;
    String nameOf(String uid) {
      for (final session in _sessionItems) {
        if (session.device.uid == uid) return session.device.name;
      }
      return uid;
    }

    final moments = <String, StatusMoment>{};
    if (_lanDown) {
      moments['lan'] = StatusMoment(
        glyph: WhisperGlyph.warn,
        warning: true,
        title: l10n.shellLanDown,
        detail: l10n.shellSelfNoLan,
      );
    }
    final group = _audioGroupCoordinator.session;
    final playingOn = group?.isLive == true
        ? [
            for (final sink in group!.sinks.values)
              if (!sink.isTerminal) nameOf(sink.sinkPeerId),
          ]
        : const <String>[];
    if (playingOn.isNotEmpty) {
      moments['sound'] = StatusMoment(
        glyph: WhisperGlyph.speaker,
        title: l10n.shellIslandPlayingOn(playingOn.join('、')),
        stopLabel: l10n.cancel,
        onStop: () => unawaited(_stopDesktopAudioShare()),
        home: IslandHomes.sound,
      );
    }
    final workspace = _remoteInputWorkspaceCoordinator.snapshot;
    if (workspace.status == RemoteInputWorkspaceStatus.active &&
        workspace.role == RemoteInputWorkspaceRole.controlled) {
      moments['input'] = StatusMoment(
        glyph: WhisperGlyph.keyboard,
        title: l10n.shellTrayControlled(
          nameOf(_remoteInputCoordinator.state.peerId),
        ),
        home: IslandHomes.input,
      );
    } else if (workspace.status == RemoteInputWorkspaceStatus.active &&
        workspace.activePeerId.isNotEmpty) {
      moments['input'] = StatusMoment(
        glyph: WhisperGlyph.keyboard,
        title: l10n.shellIslandControlling(nameOf(workspace.activePeerId)),
        home: IslandHomes.input,
      );
    }
    StatusIslandSource.shared.show(moments);
  }

  /// What the rows say comes from these too, not only from this screen's state.
  late final Listenable _shellInputs = Listenable.merge([
    ConnectionCoordinator(),
    WindowStreamCoordinator.shared,
    ShareLinkStore.shared,
    RequestIslandSource.shared,
    ShellSoundController.shared,
    ShellInputController.shared,
    DeviceFormFactors.shared,
  ]);

  ShellData _shellData() {
    return ShellData(
      self: device,
      sessions: _sessionItems,
      selectedPeerId: _selectedDesktopPeerId ?? _firstDesktopPeerId,
      place: _shellPlace,
      lanDown: _lanDown,
      factsFor: _shellFacts,
      isPaired: _isTrustedDevice,
      loading: device == null,
      soundActive:
          ShellSoundController.shared.on ||
          ShellSoundController.shared.sinkView != null,
      inputActive:
          ShellInputController.shared.on ||
          ShellInputController.shared.controlledBy != null,
      linksActive: ShareLinkStore.shared.serviceOn,
      soundSupported: supportsNativeSystemAudio(),
      inputSupported: supportsNativeRemoteInput(),
    );
  }

  /// There is always a device to show, once there is one: beside a sidebar it
  /// is on screen, and on a phone nothing is built until a row is tapped.
  /// What the window opened on, until someone chooses. It stays once shown: the
  /// list reorders as devices come and go, and the page must not change under a
  /// pointer on its way to 连接.
  String? _openedOnPeerId;

  String? get _firstDesktopPeerId {
    if (_sessionItems.isEmpty) return null;
    final opened = _openedOnPeerId;
    if (opened == null || !_sessionItems.any((s) => s.device.uid == opened)) {
      _openedOnPeerId = _sessionItems.first.device.uid;
    }
    return _openedOnPeerId;
  }

  DeviceRowFacts _shellFacts(ChatSessionItem session) {
    final uid = session.device.uid;
    final transfer = _shellTransfers[uid];
    final moving = switch (transfer?.state) {
      FileTransferState.queued ||
      FileTransferState.negotiating ||
      FileTransferState.transferring ||
      FileTransferState.verifying => true,
      _ => false,
    };
    final activity = _inputActivityForPeer(uid);
    final groupSink = _audioGroupCoordinator.session?.sinks[uid];
    final audio = _audioCoordinator.state;
    final playingFromIt =
        _audioGroupCoordinator.isPlaybackActive &&
        _audioGroupCoordinator.playbackSourcePeerId == uid;
    return DeviceRowFacts(
      connecting: switch (ConnectionCoordinator().peer(uid)?.state) {
        ConnectionLifecycleState.connecting ||
        ConnectionLifecycleState.reconnecting => !session.isConnected,
        _ => false,
      },
      connected: session.isConnected,
      paired: _isTrustedDevice(session.device),
      nearby: session.isNearby,
      offlineSince: session.lastTimestamp > 0
          ? _formatSessionTime(session.lastTimestamp)
          : null,
      transferName: moving
          ? transfer!.finalPath.split(RegExp(r'[/\\]')).last
          : null,
      transferPercent: moving && transfer!.size > 0
          ? (transfer.committedBytes * 100 ~/ transfer.size).clamp(0, 100)
          : null,
      soundHere:
          playingFromIt ||
          (audio.isForPeer(uid) && audio.role == AudioShareRuntimeRole.sink),
      controllingThis: activity?.phase == RemoteInputPeerPhase.receiving,
      pointerThere: activity?.phase == RemoteInputPeerPhase.controlling,
      playingOurs:
          (groupSink != null && !groupSink.isTerminal) ||
          (audio.isForPeer(uid) && audio.role == AudioShareRuntimeRole.source),
      flowWindows: WindowStreamCoordinator.shared.sessions
          .where(
            (s) =>
                s.handle.source is RemotePeerSource &&
                (s.handle.source as RemotePeerSource).peerId == uid,
          )
          .length,
      preview: session.preview,
    );
  }

  void _shellOpenConnectionCheck(DeviceData target, {bool touch = false}) =>
      unawaited(
        showConnectionCheck(
          context,
          device: target,
          touch: touch,
          connected: () => socketManager.isConnectedTo(target.uid),
          onConnect: () => _shellConnect(target),
        ),
      );

  void _noteSoundMemberStopped(String peerId) {
    if (!mounted) return;
    final name = socketManager.remoteProfileFor(peerId)?.device.name ?? peerId;
    NoteIslandSource.shared.note(
      AppLocalizations.of(context)!.soundMemberStoppedNotice(name),
    );
  }

  void _shellConnect(DeviceData target) =>
      _connectServer(target.host, target.port, peerId: target.uid);

  Future<void> _shellOpenSettings() async {
    await showWhisperSettings(
      context,
      exitForUpdate: _shutdownAndDestroyWindow,
      openPairing: () => unawaited(_openPairingQr(deeper: true)),
      openShareLinks: _shellOpenShareLinks,
    );
    // Restarts the service after a port change, as it always has.
    unawaited(_refreshDevice());
  }

  Future<void> _startInputWith(DeviceData target) async {
    final input = ShellInputController.shared;
    input.attach(devices: devices, self: device);
    if (!_inputMember(target.uid)) await input.add(target.uid);
    if (!input.on) await input.setOn(true);
  }

  /// On the arrangement, offline screens aside.
  bool _inputMember(String uid) =>
      ShellInputController.shared.screens.any((screen) => screen.peerId == uid);

  Future<void> _toggleInputMember(DeviceData target) async {
    final input = ShellInputController.shared;
    // Layouts load when it attaches, which until now only its page did.
    input.attach(devices: devices, self: device);
    if (_inputMember(target.uid)) {
      await input.remove(target.uid);
    } else {
      await input.add(target.uid);
    }
  }

  void _shellOpenShareLinks() {
    // A row of settings on touch, a place of its own with a pointer.
    if (!ShellContent.attached) {
      setState(() => _shellPlace = ShellPlace.links);
      return;
    }
    unawaited(
      ShellContent.push<void>(
        WhisperPageRoute<void>(
          builder: (context) => ShellPlacePage(
            title: AppLocalizations.of(context)!.shellShareLinks,
            end: Builder(
              builder: (buttonContext) => ShellIconButton(
                glyph: WhisperGlyph.plus,
                iconSize: 20,
                touch: true,
                color: buttonContext.wc.accent,
                label: AppLocalizations.of(buttonContext)!.shellLinksNew,
                onTap: () => unawaited(showShellNewLinkMenu(buttonContext)),
              ),
            ),
            child: const ShellLinksPage(touch: true),
          ),
        ),
      ),
    );
  }

  Widget _shellBuildPlace(
    BuildContext context,
    ShellPlace place,
    double rightInset, {
    GlobalKey? titleKey,
    GlobalKey? controlsKey,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return switch (place) {
      ShellPlace.links => ShellPlaceFrame(
        title: l10n.shellShareLinks,
        rightInset: rightInset,
        titleKey: titleKey,
        controlsKey: controlsKey,
        end: Builder(
          builder: (buttonContext) => ShellButton(
            label: l10n.shellLinksNew,
            glyph: WhisperGlyph.plus,
            onTap: () => unawaited(showShellNewLinkMenu(buttonContext)),
          ),
        ),
        child: const ShellLinksPage(),
      ),
      ShellPlace.sound => ShellSoundPage(
        rightInset: rightInset,
        titleKey: titleKey,
        controlsKey: controlsKey,
        selfDevice: device,
        sessions: _sessionItems,
      ),
      ShellPlace.input => ShellInputPage(
        rightInset: rightInset,
        titleKey: titleKey,
        controlsKey: controlsKey,
        selfDevice: device,
        sessions: _sessionItems,
      ),
      ShellPlace.device => const SizedBox.shrink(),
    };
  }

  late final ShellActions _shellActions = ShellActions(
    select: (uid) {
      if (uid != null && socketManager.isConnectedTo(uid)) {
        socketManager.selectPeer(uid);
      }
      setState(() {
        _selectedDesktopPeerId = uid;
        _shellPlace = ShellPlace.device;
      });
    },
    connect: _shellConnect,
    disconnect: (target) => unawaited(socketManager.disconnectPeer(target.uid)),
    openPairing: ({bool startWithAddress = false}) =>
        _openPairingQr(startWithAddress: startWithAddress),
    removeDevice: _removeDevice,
    contextActions: (target, {openCard}) {
      final l10n = AppLocalizations.of(context)!;
      return [
        ..._buildSessionContextActions(target),
        if (openCard != null)
          ContextMenuActionItem(
            label: l10n.shellCardMenu,
            icon: Icons.info_outline_rounded,
            onSelected: openCard,
          ),
      ];
    },
    openSound: () => setState(() => _shellPlace = ShellPlace.sound),
    openInput: () => setState(() => _shellPlace = ShellPlace.input),
    openShareLinks: _shellOpenShareLinks,
    openSettings: () => unawaited(_shellOpenSettings()),
    openDiagnostics: _shellOpenConnectionCheck,
    buildConversation: (context, target) => SendMessageScreen(
      key: ValueKey('shell-chat-${target.uid}'),
      device: target,
      onMessagesDeleted: () => unawaited(_refreshDevice()),
      embedded: true,
      chromeless: true,
      onDeviceDeleted: _removeDevice,
    ),
    buildFiles: (context, target) => RemoteFilesPage(
      key: ValueKey('shell-files-${target.uid}'),
      peerId: target.uid,
      deviceName: target.name,
    ),
    buildApps: (context, target) => FlowSpacePage(
      key: ValueKey('shell-apps-${target.uid}'),
      focusPeerId: target.uid,
    ),
    buildPlace: _shellBuildPlace,
    buildSelfPanel: (context) => ShellSelfPanel(
      self: device,
      onEnterAddress: () => _openPairingQr(startWithAddress: true),
    ),
    buildCard: (context, target, close) {
      final l10n = AppLocalizations.of(context)!;
      final connected = socketManager.isConnectedTo(target.uid);
      final session = _sessionItems.where((s) => s.device.uid == target.uid);
      return ShellDeviceCard(
        key: ValueKey('shell-card-${target.uid}'),
        device: target,
        connected: connected,
        paired: _isTrustedDevice(target),
        onClose: close,
        statusLine: connected
            ? l10n.shellCardConnected
            : session.isEmpty
            ? l10n.shellRowOffline
            : deviceRowText(l10n, _shellFacts(session.first)),
        onSound: supportsNativeSystemAudio()
            ? () => unawaited(
                ShellSoundController.shared.toggleSending(target.uid),
              )
            : null,
        soundOn: ShellSoundController.shared.isSending(target.uid),
        soundStatus: switch (ShellSoundController.shared.channelOf(
          target.uid,
        )) {
          final role? => _audioGroupRoleLabel(role),
          null => null,
        },
        soundEnabled: ShellSoundController.shared.sinkView == null,
        onInput: deviceKindOf(target).handheld || !supportsNativeRemoteInput()
            ? null
            : () => unawaited(_toggleInputMember(target)),
        inputOn: _inputMember(target.uid),
        onDiagnostics: () => _shellOpenConnectionCheck(target),
        onDisconnect: () => socketManager.disconnectPeer(target.uid),
        onRemove: _removeDevice,
      );
    },
    buildTouchCard: _shellBuildTouchCard,
    canControl: _shellCanControl,
    openControl: _shellOpenControl,
    paletteItems: _shellPaletteItems,
    searchMessages: _shellSearchMessages,
  );

  bool _shellCanControl(DeviceData target) =>
      supportsManualRemoteInputSource() &&
      target.uid != device?.uid &&
      !deviceKindOf(target).handheld &&
      socketManager.isConnectedTo(target.uid) &&
      socketManager.supportsManualInputFor(target.uid);

  void _shellOpenControl(DeviceData target) {
    final l10n = AppLocalizations.of(context)!;
    unawaited(
      ShellContent.push<void>(
        WhisperPageRoute<void>(
          settings: const RouteSettings(name: ShellRoutes.control),
          builder: (_) => mobileControlPage(
            device: target,
            self: device,
            l10n: l10n,
            deviceArt: deviceArtFor(target, size: 104),
          ),
        ),
      ),
    );
  }

  /// DESIGN.md「平板和折叠屏」: the device page in the compact size class, with
  /// control, files and apps as its entries. Beside a sidebar it is the card,
  /// and the toolbar has those.
  Widget _shellBuildTouchCard(
    BuildContext context,
    DeviceData target, {
    required bool page,
    required VoidCallback onClose,
    required ValueChanged<int> onOpenTab,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final connected = socketManager.isConnectedTo(target.uid);
    final session = _sessionItems.where((s) => s.device.uid == target.uid);
    void searchHistory() => unawaited(
      ShellContent.push<void>(
        WhisperPageRoute<void>(
          builder: (_) => TransferAssistantScreen(
            peerId: target.uid,
            peerName: target.name,
          ),
        ),
      ),
    );
    void diagnostics() => _shellOpenConnectionCheck(target, touch: true);
    Future<void> remove(String uid) async {
      await _removeDevice(uid);
      onClose();
      ShellContent.showList();
    }

    if (page) {
      return ShellPhoneDevicePage(
        key: ValueKey('shell-device-page-${target.uid}'),
        device: target,
        connected: connected,
        onBack: onClose,
        entries: [
          if (supportsManualRemoteInputSource() &&
              target.uid != device?.uid &&
              !deviceKindOf(target).handheld &&
              (!connected || socketManager.supportsManualInputFor(target.uid)))
            ShellDeviceEntry(
              glyph: WhisperGlyph.keyboard,
              title: l10n.shellPhoneControl,
              onTap: connected ? () => _shellOpenControl(target) : null,
            ),
          ShellDeviceEntry(
            glyph: WhisperGlyph.folder,
            title: l10n.shellTabFiles,
            onTap: connected ? () => onOpenTab(1) : null,
          ),
          ShellDeviceEntry(
            glyph: WhisperGlyph.apps,
            title: l10n.shellTabApps,
            onTap: connected ? () => onOpenTab(2) : null,
          ),
        ],
        onSearchHistory: searchHistory,
        onDiagnostics: diagnostics,
        onDisconnect: () => socketManager.disconnectPeer(target.uid),
        onRemove: remove,
      );
    }
    return ShellDeviceCard(
      key: ValueKey('shell-card-${target.uid}'),
      device: target,
      connected: connected,
      paired: _isTrustedDevice(target),
      touch: true,
      entries: [
        if (_shellCanControl(target))
          ShellDeviceEntry(
            glyph: WhisperGlyph.keyboard,
            title: l10n.shellPhoneControl,
            onTap: connected ? () => _shellOpenControl(target) : null,
          ),
      ],
      onClose: onClose,
      statusLine: connected
          ? l10n.shellCardConnected
          : session.isEmpty
          ? l10n.shellRowOffline
          : deviceRowText(l10n, _shellFacts(session.first)),
      onSearchHistory: searchHistory,
      onDiagnostics: diagnostics,
      onDisconnect: () => socketManager.disconnectPeer(target.uid),
      onRemove: remove,
    );
  }

  List<PaletteItem> _shellPaletteItems(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final actions = _shellActions;
    return [
      for (final session in _sessionItems)
        PaletteItem(
          glyph: WhisperGlyph.info,
          name: session.device.name,
          category: l10n.shellPaletteDevice,
          onRun: () => actions.select(session.device.uid),
          keywords: [session.device.host],
        ),
      for (final session in _sessionItems)
        if (session.isConnected) ...[
          PaletteItem(
            glyph: WhisperGlyph.speaker,
            name: l10n.shellPalettePlayOn(session.device.name),
            category: l10n.shellPaletteAction,
            onRun: () {
              actions.openSound();
              if (!ShellSoundController.shared.isSelected(session.device.uid)) {
                unawaited(
                  ShellSoundController.shared.toggle(session.device.uid),
                );
              }
            },
          ),
          if (!deviceKindOf(session.device).handheld)
            PaletteItem(
              glyph: WhisperGlyph.keyboard,
              name: l10n.shellPaletteControl(session.device.name),
              category: l10n.shellPaletteAction,
              onRun: () {
                actions.openInput();
                unawaited(_startInputWith(session.device));
              },
            ),
        ],
      PaletteItem(
        glyph: WhisperGlyph.speaker,
        name: l10n.shellSound,
        category: l10n.shellPalettePage,
        onRun: actions.openSound,
      ),
      if (!isMobile())
        PaletteItem(
          glyph: WhisperGlyph.keyboard,
          name: l10n.shellInput,
          category: l10n.shellPalettePage,
          onRun: actions.openInput,
        ),
      PaletteItem(
        glyph: WhisperGlyph.link,
        name: l10n.shellShareLinks,
        category: l10n.shellPalettePage,
        onRun: actions.openShareLinks,
      ),
      PaletteItem(
        glyph: WhisperGlyph.gear,
        name: l10n.shellSettings,
        category: l10n.shellPalettePage,
        onRun: actions.openSettings,
      ),
    ];
  }

  /// Chat history, device by device, opening that device's conversation.
  Future<List<PaletteItem>> _shellSearchMessages(
    BuildContext context,
    String query,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final found = <PaletteItem>[];
    for (final session in _sessionItems) {
      final results = await db.searchTextMessagesForPeer(
        session.device.uid,
        query: query,
      );
      for (final result in results.take(2)) {
        found.add(
          PaletteItem(
            glyph: WhisperGlyph.chat,
            name: result.message.content ?? '',
            category: session.device.name.isEmpty
                ? l10n.shellPaletteMessage
                : session.device.name,
            onRun: () => _shellActions.select(session.device.uid),
          ),
        );
      }
      if (found.length >= 8) break;
    }
    return found;
  }

  bool get _usesSplitWorkspace => usesSplitDeviceWorkspace(
    width: MediaQuery.sizeOf(context).width,
    desktop: isDesktop(),
    ios: Platform.isIOS,
  );

  bool get _usesTabletWorkspace {
    if (!Platform.isIOS) return false;
    final view = View.of(context);
    return usesRetainedTabletWorkspace(
      ios: true,
      displayShortestSide:
          view.display.size.shortestSide / view.devicePixelRatio,
    );
  }

  Widget _buildMobileScaffold(bool isDark) {
    return Scaffold(
      // Inputs live in separate routes; their keyboards must not move the
      // device list or briefly expose the welcome icon behind a dialog.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        leading: IconButton(
          tooltip: AppLocalizations.of(context)?.connectDeviceTitle ?? '连接设备',
          onPressed: _openPairingQr,
          icon: Icon(
            Icons.qr_code_scanner_rounded,
            size: 28,
            color: isDark ? Colors.white60 : Colors.black45,
          ),
        ),
        title: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              device?.name ?? 'localhost',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    '${device?.host ?? "127.0.0.1"}:${device?.port ?? 10002}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white54
                          : Colors.black54,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.wifi_rounded,
                  size: socketManager.started ? 14 : 0,
                  color: Colors.lightBlue,
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
              color: isDark ? Colors.white60 : Colors.black45,
            ),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => app_settings.SettingsScreen(
                    exitForUpdate: _shutdownAndDestroyWindow,
                  ),
                ),
              );
              _refreshDevice();
            },
          ),
        ],
      ),
      body: _sessionItems.isEmpty
          ? DeviceConnectionWelcome(
              hasDevices: false,
              isLoading: device == null,
              onPair: _openPairingQr,
              onManualConnect: _showManualConnectDialog,
            )
          : ListView.builder(
              itemCount: _sessionItems.length,
              itemBuilder: (context, index) {
                return _buildDeviceItemOld(_sessionItems[index]);
              },
            ),
    );
  }

  Widget _buildDesktopScaffold(bool isDark, {bool compact = false}) {
    final selectedSession = _selectedDesktopSession();
    final visibleSessions = _visibleSessions();
    final palette = context.whisperPalette;
    return Scaffold(
      backgroundColor: palette.surfaceCanvas,
      body: SafeArea(
        child: Row(
          children: [
            if (!compact)
              SizedBox(
                width: isDesktop() ? 340 : 320,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: palette.surfaceCanvas,
                    border: Border(
                      right: BorderSide(color: palette.borderSubtle),
                    ),
                  ),
                  child: Column(
                    children: [
                      _buildDesktopSidebarToolbar(),
                      Expanded(
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(
                            context,
                          ).copyWith(scrollbars: false),
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                            itemCount: visibleSessions.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 6),
                            itemBuilder: (context, index) {
                              final session = visibleSessions[index];
                              return _buildDesktopSessionTile(
                                session,
                                selected:
                                    session.device.uid ==
                                    _selectedDesktopPeerId,
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              key: const ValueKey('workspace-conversation'),
              child: selectedSession == null
                  ? _buildDesktopPlaceholder(isDark)
                  : SendMessageScreen(
                      key: ValueKey('desktop-${selectedSession.device.uid}'),
                      device: selectedSession.device,
                      embedded: !compact,
                      onBack: compact
                          ? () => setState(() => _selectedDesktopPeerId = null)
                          : null,
                      onDeviceDeleted: _removeDevice,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopSidebarToolbar() {
    return DeviceSidebarToolbar(
      searchExpanded: _isDesktopSearchExpanded,
      search: _buildDesktopSearchPill(expanded: _isDesktopSearchExpanded),
      tools: _buildDesktopTools(),
    );
  }

  Widget _buildDesktopSearchPill({required bool expanded}) {
    final palette = context.whisperPalette;
    final label = AppLocalizations.of(context)?.searchChats ?? '搜索';
    return Container(
      height: _desktopToolbarPillHeight,
      decoration: BoxDecoration(
        color: _desktopToolbarPillColor,
        borderRadius: _desktopToolbarPillRadius,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            ignoring: expanded,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: expanded ? 0 : 1,
              child: Tooltip(
                message: label,
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  borderRadius: _desktopToolbarPillRadius,
                  onPressed: _expandDesktopSearch,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.search_rounded,
                        size: 19,
                        color: palette.textMuted,
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IgnorePointer(
            ignoring: !expanded,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: expanded ? 1 : 0,
              child: CupertinoTextField(
                controller: _desktopSearchController,
                focusNode: _desktopSearchFocusNode,
                clearButtonMode: OverlayVisibilityMode.editing,
                cursorColor: Colors.lightBlue,
                decoration: const BoxDecoration(color: Colors.transparent),
                padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
                prefix: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 7),
                  child: Icon(
                    Icons.search_rounded,
                    size: 19,
                    color: palette.textMuted,
                  ),
                ),
                placeholder: label,
                placeholderStyle: TextStyle(
                  color: palette.textMuted,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                onChanged: (value) {
                  setState(() {
                    _desktopSearchQuery = value;
                  });
                  if (value.isEmpty) {
                    _desktopSearchFocusNode.unfocus();
                  }
                },
                onSubmitted: (_) {
                  if (_desktopSearchController.text.isEmpty) {
                    _desktopSearchFocusNode.unfocus();
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Flow (window streaming) runs on this device.
  /// Everyday tools stay out; the rest (and new features as they come)
  /// slide in from the left as the search makes room. A tool that is
  /// running stays visible either way.
  List<Widget> _buildDesktopTools() {
    final l10n = AppLocalizations.of(context)!;
    final expanded = _toolsExpanded;
    final audioRunning =
        isDesktop() && (_isDesktopAudioShareActive || _isDesktopAudioShareBusy);
    final inputRunning = isDesktop() && _isDesktopRemoteInputActive;
    // 流转 and 文件 belong to a device: they are on its page (the … in its
    // conversation), not here.
    return [
      if (isDesktop())
        _buildDesktopToolButton(
          key: const ValueKey('tool-toggle'),
          icon: Icons.chevron_left_rounded,
          iconTurns: expanded ? 0.5 : 0,
          tooltip: expanded ? l10n.toolbarFewerTools : l10n.toolbarMoreTools,
          onPressed: () => setState(() => _toolsExpanded = !expanded),
        ),
      if (isDesktop() && (expanded || audioRunning))
        KeyedSubtree(
          key: const ValueKey('tool-audio'),
          child: _buildDesktopAudioShareAction(),
        ),
      if (isDesktop() && (expanded || inputRunning))
        KeyedSubtree(
          key: const ValueKey('tool-input'),
          child: _buildDesktopRemoteInputWorkspaceAction(),
        ),
      _buildDesktopToolButton(
        key: const ValueKey('tool-qr'),
        icon: Icons.qr_code_scanner_rounded,
        tooltip: AppLocalizations.of(context)?.connectDeviceTitle ?? '连接设备',
        onPressed: _openPairingQr,
      ),
      _buildDesktopToolButton(
        key: const ValueKey('tool-settings'),
        icon: Icons.settings_outlined,
        tooltip: AppLocalizations.of(context)?.setting ?? '设置',
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => app_settings.SettingsScreen(
                exitForUpdate: _shutdownAndDestroyWindow,
              ),
            ),
          );
          _refreshDevice();
        },
      ),
    ];
  }

  Widget _buildDesktopAudioShareAction() {
    final palette = context.whisperPalette;
    final isActive = _isDesktopAudioShareActive;
    final isBusy = _isDesktopAudioShareBusy;
    return _buildDesktopToolButton(
      icon: isBusy ? Icons.sync_rounded : Icons.volume_up_outlined,
      tooltip: _desktopAudioShareTooltip(isActive: isActive, isBusy: isBusy),
      iconColor: isActive || isBusy ? Colors.lightBlue : palette.textMuted,
      onPressed: isBusy ? null : _toggleDesktopAudioShare,
    );
  }

  bool get _isDesktopRemoteInputActive => isRemoteInputSessionLive(
    workspace: _remoteInputWorkspaceCoordinator.snapshot,
    legacy: _remoteInputCoordinator.state,
    legacyIsManual: _remoteInputCoordinator.isManual,
    isConnected: socketManager.isConnectedTo,
  );

  Widget _buildDesktopRemoteInputWorkspaceAction() {
    final palette = context.whisperPalette;
    final isActive = _isDesktopRemoteInputActive;
    return _buildDesktopToolButton(
      icon: Icons.keyboard_alt_outlined,
      tooltip:
          AppLocalizations.of(context)?.remoteInputWorkspaceTooltip ?? '键鼠工作区',
      iconColor: isActive ? Colors.lightBlue : palette.textMuted,
      onPressed: _openRemoteInputWorkspace,
    );
  }

  Widget _buildDesktopToolButton({
    required IconData icon,
    required VoidCallback? onPressed,
    Color? iconColor,
    String? tooltip,
    Key? key,
    double iconTurns = 0,
  }) {
    return DeviceToolbarButton(
      key: key,
      iconTurns: iconTurns,
      icon: icon,
      label: tooltip ?? '',
      iconColor: iconColor,
      onPressed: onPressed,
    );
  }

  bool get _isDesktopAudioShareActive {
    final groupSession = _audioGroupCoordinator.session;
    if (groupSession?.isLive == true) {
      return true;
    }
    return _audioCoordinator.state.isActive;
  }

  bool get _isDesktopAudioShareBusy {
    final audioState = _audioCoordinator.state;
    return audioState.isBusy;
  }

  String _desktopAudioShareTooltip({
    required bool isActive,
    required bool isBusy,
  }) {
    final l10n = AppLocalizations.of(context)!;
    if (isBusy) {
      return l10n.audioShareCaptureConnecting;
    }
    if (isActive) {
      return l10n.audioGroupAdjust;
    }
    return l10n.audioGroupShareStart;
  }

  Future<void> _toggleDesktopAudioShare() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final audioGroupSession = _audioGroupCoordinator.session;
      if (audioGroupSession?.isLive == true) {
        await _showActiveDesktopAudioGroupSetup();
        return;
      }

      final audioState = _audioCoordinator.state;
      if (audioState.status != AudioShareRuntimeStatus.idle &&
          audioState.status != AudioShareRuntimeStatus.failed) {
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

      final self = device ?? await LocalSetting().instance();
      final groupCandidates = socketManager.connectedAudioGroupSinkDevices(
        preferredPeerId: _selectedDesktopPeerId ?? '',
      );
      if (groupCandidates.isEmpty) {
        showAppToast(l10n.audioGroupSelectAtLeastOne);
        return;
      }

      final Map<String, AudioChannelRole> sinks;
      if (groupCandidates.length == 1) {
        sinks = <String, AudioChannelRole>{
          groupCandidates.single.uid: AudioChannelRole.stereo,
        };
      } else {
        final selectedResult = await _showAudioGroupSetupSheet(
          groupCandidates,
          preferredPeerId: _selectedDesktopPeerId ?? '',
        );
        if (selectedResult == null || selectedResult.shouldStop) {
          return;
        }
        if (selectedResult.sinks.isEmpty) {
          showAppToast(l10n.audioGroupSelectAtLeastOne);
          return;
        }
        sinks = selectedResult.sinks;
      }

      await _applyDesktopAudioGroupSelection(
        sourcePeerId: self.uid,
        sinks: sinks,
      );
    } catch (error) {
      final reason = audioFailureReasonFor(
        error,
        context: AudioFailureContext.protocol,
      );
      _logDeviceListFailure(DeviceListOperationKind.audioToggle, error);
      if (mounted) {
        final detail = reason == AudioFailureReason.unsupported
            ? l10n.audioShareUnsupportedCapture
            : l10n.connectFailed;
        showAppToast(l10n.audioShareFailed(detail), tone: AppToastTone.error);
      }
    }
  }

  Map<String, AudioChannelRole> _activeAudioGroupSinks() {
    final audioGroupSession = _audioGroupCoordinator.session;
    if (audioGroupSession == null) {
      return const <String, AudioChannelRole>{};
    }
    return <String, AudioChannelRole>{
      for (final entry in audioGroupSession.sinks.entries)
        entry.key: entry.value.channelRole,
    };
  }

  Future<void> _showActiveDesktopAudioGroupSetup() async {
    final l10n = AppLocalizations.of(context)!;
    final self = device ?? await LocalSetting().instance();
    final groupCandidates = socketManager.connectedAudioGroupSinkDevices(
      preferredPeerId: _selectedDesktopPeerId ?? '',
    );
    final result = await _showAudioGroupSetupSheet(
      groupCandidates,
      preferredPeerId: _selectedDesktopPeerId ?? '',
      initialSinks: _activeAudioGroupSinks(),
      allowStop: true,
      applyingActiveConfig: true,
    );
    if (result == null) {
      return;
    }
    if (result.shouldStop) {
      await _stopDesktopAudioShare();
      return;
    }
    if (result.sinks.isEmpty) {
      showAppToast(l10n.audioGroupSelectAtLeastOne);
      return;
    }
    await _applyDesktopAudioGroupSelection(
      sourcePeerId: self.uid,
      sinks: result.sinks,
      replaceActive: true,
    );
  }

  Future<void> _stopDesktopAudioShare() async {
    await _audioGroupCoordinator.stopGroup(
      sendControl: socketManager.sendAudioGroupControlTo,
    );
  }

  Future<void> _applyDesktopAudioGroupSelection({
    required String sourcePeerId,
    required Map<String, AudioChannelRole> sinks,
    bool replaceActive = false,
  }) async {
    if (replaceActive && _audioGroupCoordinator.session?.isLive == true) {
      await _audioGroupCoordinator.updateGroup(
        sinks: sinks,
        sendControl: socketManager.sendAudioGroupControlTo,
      );
      return;
    }
    _audioGroupCoordinator.startGroup(
      sourcePeerId: sourcePeerId,
      sinks: sinks,
      format: AudioShareCoordinator.defaultFormat,
      sendControl: socketManager.sendAudioGroupControlTo,
    );
  }

  Future<void> _openRemoteInputWorkspace() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RemoteInputWorkspaceScreen(
          initialDevices: socketManager.connectedRemoteInputDevices(
            preferredPeerId: _selectedDesktopPeerId ?? '',
          ),
          preferredPeerId: _selectedDesktopPeerId ?? '',
        ),
      ),
    );
    _refreshDevice();
  }

  Future<_AudioGroupSetupResult?> _showAudioGroupSetupSheet(
    List<DeviceData> candidates, {
    String preferredPeerId = '',
    Map<String, AudioChannelRole> initialSinks =
        const <String, AudioChannelRole>{},
    bool allowStop = false,
    bool applyingActiveConfig = false,
  }) {
    final selected = <String, bool>{
      for (final candidate in candidates)
        candidate.uid: initialSinks.isNotEmpty
            ? initialSinks.containsKey(candidate.uid)
            : candidate.uid ==
                  (preferredPeerId.isNotEmpty
                      ? preferredPeerId
                      : candidates.first.uid),
    };
    final roles = <String, AudioChannelRole>{
      for (var index = 0; index < candidates.length; index++)
        candidates[index].uid:
            initialSinks[candidates[index].uid] ??
            (index == 0
                ? AudioChannelRole.left
                : (index == 1
                      ? AudioChannelRole.right
                      : AudioChannelRole.stereo)),
    };
    final l10n = AppLocalizations.of(context)!;
    return showWhisperGlassBottomSheet<_AudioGroupSetupResult>(
      context,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final selectedCount = selected.values
                .where((value) => value)
                .length;
            final applyLabel = applyingActiveConfig
                ? l10n.audioGroupApply
                : selectedCount > 1
                ? l10n.audioGroupStart
                : l10n.audioShareStart;
            return WhisperGlassBottomSheet(
              maxSheetWidth: 680,
              maxContentWidth: 600,
              title: Text(l10n.audioGroupSelectSinks),
              content: AnimatedBuilder(
                animation: _audioGroupCoordinator,
                builder: (context, _) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (var index = 0; index < candidates.length; index += 1)
                        Padding(
                          padding: EdgeInsets.only(
                            bottom: index == candidates.length - 1 ? 0 : 8,
                          ),
                          child: WhisperGlassSurface(
                            borderRadius: BorderRadius.circular(14),
                            showTopHighlight: false,
                            showShadow: false,
                            neutral: true,
                            child: CheckboxListTile(
                              controlAffinity: ListTileControlAffinity.leading,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              value: selected[candidates[index].uid] ?? false,
                              onChanged: (value) {
                                setSheetState(() {
                                  selected[candidates[index].uid] =
                                      value ?? false;
                                });
                              },
                              title: _buildAudioGroupDeviceTitle(
                                candidates[index],
                              ),
                              subtitle: _buildAudioGroupSinkSubtitle(
                                candidates[index],
                              ),
                              secondary:
                                  WhisperGlassMenuButton<AudioChannelRole>(
                                    value:
                                        roles[candidates[index].uid] ??
                                        AudioChannelRole.stereo,
                                    enabled:
                                        selected[candidates[index].uid] == true,
                                    options:
                                        <
                                          WhisperGlassMenuOption<
                                            AudioChannelRole
                                          >
                                        >[
                                          for (final role
                                              in AudioChannelRole.values)
                                            WhisperGlassMenuOption<
                                              AudioChannelRole
                                            >(
                                              value: role,
                                              label: _audioGroupRoleLabel(role),
                                            ),
                                        ],
                                    onChanged: (role) {
                                      setSheetState(() {
                                        roles[candidates[index].uid] = role;
                                      });
                                    },
                                  ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              actions: <Widget>[
                if (allowStop)
                  WhisperDialogButton(
                    label: l10n.audioGroupStop,
                    icon: Icons.stop_rounded,
                    destructive: true,
                    onPressed: () => Navigator.of(
                      sheetContext,
                    ).pop(const _AudioGroupSetupResult.stop()),
                  ),
                WhisperDialogButton(
                  label: applyLabel,
                  icon: Icons.spatial_audio_off_rounded,
                  prominent: true,
                  onPressed: selectedCount == 0
                      ? null
                      : () {
                          Navigator.of(sheetContext).pop(
                            _AudioGroupSetupResult.apply(
                              <String, AudioChannelRole>{
                                for (final candidate in candidates)
                                  if (selected[candidate.uid] == true)
                                    candidate.uid:
                                        roles[candidate.uid] ??
                                        AudioChannelRole.stereo,
                              },
                            ),
                          );
                        },
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _audioGroupRoleLabel(AudioChannelRole role) {
    final l10n = AppLocalizations.of(context)!;
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

  Widget _buildAudioGroupDeviceTitle(DeviceData candidate) {
    final palette = context.whisperPalette;
    return Row(
      children: [
        Tooltip(
          message: candidate.platform,
          child: Icon(
            platformIcon(
              candidate.platform,
              tablet: DeviceFormFactors.shared.isTablet(candidate.uid),
            ),
            size: 18,
            color: palette.textMuted,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            candidate.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget? _buildAudioGroupSinkSubtitle(DeviceData candidate) {
    final evidence = _audioGroupSyncEvidenceLabel(candidate.uid);
    final text = evidence.isEmpty
        ? AppLocalizations.of(context)!.audioGroupDeviceIdle
        : evidence;
    final palette = context.whisperPalette;
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: palette.textMuted, fontSize: 12),
    );
  }

  String _audioGroupSyncEvidenceLabel(String peerId) {
    final sink = _audioGroupCoordinator.session?.sinks[peerId];
    if (sink == null) {
      return '';
    }
    final hasEvidence =
        sink.rttMicros > 0 ||
        sink.jitterMicros > 0 ||
        sink.bufferTargetMicros > 0 ||
        sink.latePacketCount > 0 ||
        sink.syncErrorMicros != 0;
    if (!hasEvidence) {
      return AppLocalizations.of(context)!.audioGroupSyncCalibrating;
    }
    final l10n = AppLocalizations.of(context)!;
    return l10n.audioGroupSyncEvidenceCompact(
      _audioGroupSyncQualityLabel(sink),
      l10n.audioGroupLatencyShortLabel,
      _formatAudioMicros(sink.rttMicros),
      l10n.audioGroupJitterShortLabel,
      _formatAudioMicros(sink.jitterMicros),
      l10n.audioGroupBufferShortLabel,
      _formatAudioMicros(sink.bufferTargetMicros),
      l10n.audioGroupRecentLatePacketShortLabel,
      sink.latePacketCount,
    );
  }

  String _audioGroupSyncQualityLabel(AudioGroupSink sink) {
    final l10n = AppLocalizations.of(context)!;
    final errorMs = sink.syncErrorMicros.abs() / 1000;
    final jitterMs = sink.jitterMicros.abs() / 1000;
    final hasMeasuredError = sink.syncErrorMicros != 0;
    if (sink.latePacketCount > 0 ||
        (hasMeasuredError && errorMs > 30) ||
        jitterMs > 20) {
      return l10n.audioGroupSyncUnstable;
    }
    if ((hasMeasuredError && errorMs > 12) || jitterMs > 8) {
      return l10n.audioGroupSyncFair;
    }
    return l10n.audioGroupSyncGood;
  }

  String _formatAudioMicros(int value) {
    final ms = value / 1000;
    if (ms == ms.roundToDouble()) {
      return ms.round().toString();
    }
    return ms.toStringAsFixed(1);
  }

  Widget _buildDesktopPlaceholder(bool isDark) => DeviceConnectionWelcome(
    hasDevices: _sessionItems.isNotEmpty,
    isLoading: device == null,
    onPair: _openPairingQr,
    onManualConnect: _showManualConnectDialog,
  );

  String _sessionStatusLabel(ChatSessionItem session) {
    final l10n = AppLocalizations.of(context)!;
    if (session.isConnected) return l10n.connectedNow;
    if (session.isNearby) return l10n.nearbyAvailable;
    return l10n.deviceOffline;
  }

  Widget _buildDesktopSessionTile(
    ChatSessionItem session, {
    required bool selected,
  }) {
    final peer = session.device;
    final activity = _inputActivityForPeer(peer.uid);
    final shortId = peer.uid.length > 6
        ? peer.uid.substring(peer.uid.length - 6)
        : peer.uid;
    return ContextMenuRegion(
      child: DesktopDeviceSessionTile(
        name: peer.name,
        identity: '${platformLabel(peer.platform)} · $shortId',
        statusLabel: _sessionStatusLabel(session),
        preview: session.preview,
        time: _formatSessionTime(session.lastTimestamp),
        avatar: _buildSessionAvatar(session),
        statusColor: _sessionStatusColor(session),
        selected: selected,
        trusted: _isTrustedDevice(peer),
        controlActivity: activity,
        onControlAction: activity == null
            ? null
            : activity.isManual
            ? () => _stopMobileControl(peer.uid, activity.sessionId)
            : _openRemoteInputWorkspace,
        onTap: () => setState(() => _selectedDesktopPeerId = peer.uid),
      ),
      items: _buildSessionContextActions(peer),
    );
  }

  RemoteInputPeerActivity? _inputActivityForPeer(String peerId) =>
      RemoteInputPeerActivity.forPeer(
        peerId: peerId,
        isConnected: socketManager.isConnectedTo(peerId),
        legacy: _remoteInputCoordinator.state,
        isManual: _remoteInputCoordinator.isManual,
        workspace: _remoteInputWorkspaceCoordinator.snapshot,
      );

  bool _isReceivingMobileControl(String peerId) =>
      _inputActivityForPeer(peerId)?.isManual == true &&
      _remoteInputCoordinator.state.role == RemoteInputRuntimeRole.sink;

  Future<void> _stopMobileControl(String peerId, String sessionId) async {
    if (!_isReceivingMobileControl(peerId) ||
        _remoteInputCoordinator.state.sessionId != sessionId) {
      return;
    }
    await _remoteInputCoordinator.stopSharing(
      sendControl: (control) {
        socketManager.sendRemoteInputControlTo(peerId, control);
      },
    );
  }

  List<ContextMenuActionItem> _buildSessionContextActions(
    DeviceData deviceItem,
  ) {
    final l10n = AppLocalizations.of(context);
    final isConnected = socketManager.isConnectedTo(deviceItem.uid);
    final inputSessionId = _remoteInputCoordinator.state.sessionId;
    return [
      if (_isReceivingMobileControl(deviceItem.uid))
        ContextMenuActionItem(
          label: l10n!.mobileControlStop,
          icon: Icons.stop_circle_outlined,
          onSelected: () => _stopMobileControl(deviceItem.uid, inputSessionId),
        ),
      if (isConnected)
        ContextMenuActionItem(
          label: l10n?.disconnect ?? '断开',
          icon: Icons.link_off_rounded,
          onSelected: () async {
            await socketManager.disconnectPeer(deviceItem.uid);
          },
        ),
      if (!isConnected)
        ContextMenuActionItem(
          label: l10n?.connect ?? '连接',
          icon: Icons.link_rounded,
          onSelected: () {
            _connectServer(
              deviceItem.host,
              deviceItem.port,
              peerId: deviceItem.uid,
            );
          },
        ),
      if (!isConnected)
        ContextMenuActionItem(
          label: l10n?.delete ?? '删除',
          icon: Icons.delete_outline_rounded,
          destructive: true,
          onSelected: () async {
            await _confirmRemoveDevice(deviceItem);
          },
        ),
    ];
  }

  Widget _buildSessionAvatar(ChatSessionItem session) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = session.isConnected
        ? Colors.lightBlue
        : session.isNearby
        ? Colors.green
        : (isDark ? Colors.grey[700]! : Colors.grey[300]!);
    return Tooltip(
      message: platformLabel(
        session.device.platform,
        tablet: DeviceFormFactors.shared.isTablet(session.device.uid),
      ),
      child: CircleAvatar(
        radius: 24,
        backgroundColor: background,
        child: Icon(
          platformIcon(
            session.device.platform,
            tablet: DeviceFormFactors.shared.isTablet(session.device.uid),
          ),
          size: 24,
          color: Colors.white,
          semanticLabel: platformLabel(
            session.device.platform,
            tablet: DeviceFormFactors.shared.isTablet(session.device.uid),
          ),
        ),
      ),
    );
  }

  Color _sessionStatusColor(ChatSessionItem session) {
    if (session.isConnected) {
      return Colors.lightBlue;
    }
    if (session.isNearby) {
      return Colors.green;
    }
    return Colors.grey;
  }

  String _formatSessionTime(int timestamp) {
    if (timestamp <= 0) {
      return '';
    }
    final messageTime = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final targetDay = DateTime(
      messageTime.year,
      messageTime.month,
      messageTime.day,
    );
    if (targetDay == today) {
      return DateFormat('HH:mm').format(messageTime);
    }
    if (messageTime.year == now.year) {
      return DateFormat('MM/dd').format(messageTime);
    }
    return DateFormat('yyyy/MM/dd').format(messageTime);
  }

  Future<void> _showManualConnectDialog() =>
      _openPairingQr(startWithAddress: true);

  Future<void> _openPairingQr({
    bool startWithAddress = false,
    bool deeper = false,
  }) async {
    // surfaces.md「这台面板」: on a desktop the code lives there.
    if (whisperNewUi && !ShellContent.attached && !startWithAddress) {
      await showShellSheet<void>(
        context,
        scrolls: false,
        builder: _shellActions.buildSelfPanel,
      );
      return;
    }
    final qrController = PairingQrDialogController();
    _activePairingQrController?.dismiss();
    _activePairingQrController = qrController;
    try {
      final localDevice = device ?? await LocalSetting().instance();
      final currentHost = await getLocalIpAddress();
      final identity = await DeviceIdentityStore().loadOrCreate();
      PairingInvite? localInvite;
      try {
        localInvite = PairingInvite(
          host: currentHost,
          port: localDevice.port,
          peerId: localDevice.uid,
          publicKeyHash: identityPublicKeyHash(identity.publicKeyBase64Url),
        );
      } on PairingInviteFormatException catch (error) {
        // An unavailable local QR address must not block manual connections.
        if (error.reason != PairingInviteError.invalidHost) rethrow;
      }
      if (!mounted) {
        return;
      }
      final result = await showPairingQrDialog(
        context,
        localInvite: localInvite,
        localPeerId: localDevice.uid,
        startWithAddress: startWithAddress,
        startWithScanner: isMobile(),
        controller: qrController,
        localName: localDevice.name,
        localFingerprint: identityPublicKeyHash(identity.publicKeyBase64Url),
        reloadInvite: () async {
          try {
            return PairingInvite(
              host: await getLocalIpAddress(),
              port: localDevice.port,
              peerId: localDevice.uid,
              publicKeyHash: identityPublicKeyHash(identity.publicKeyBase64Url),
            );
          } on PairingInviteFormatException {
            return null;
          }
        },
      );
      if (!mounted || result == null) {
        return;
      }
      final invite = result.invite;
      if (invite != null) {
        await _connectServerInternal(
          invite.host,
          invite.port,
          manual: true,
          peerId: invite.peerId,
          publicKeyHash: invite.publicKeyHash,
        );
      } else {
        _connectServer(result.endpoint.host, result.endpoint.port);
      }
    } on PairingInviteFormatException catch (error) {
      if (mounted) {
        _showConnectionDiagnosticStage(
          error.reason == PairingInviteError.invalidHost
              ? ConnectionDiagnosticStage.wifi
              : ConnectionDiagnosticStage.address,
        );
      }
    } on Object {
      if (mounted) {
        _showConnectionDiagnosticStage(ConnectionDiagnosticStage.service);
      }
    } finally {
      if (identical(_activePairingQrController, qrController)) {
        _activePairingQrController = null;
      }
    }
  }

  void _openConv(DeviceData deviceItem) async {
    if (socketManager.isConnectedTo(deviceItem.uid)) {
      socketManager.selectPeer(deviceItem.uid);
    }
    if (whisperNewUi) {
      _shellShowDevice(deviceItem.uid);
      return;
    }
    if (_usesSplitWorkspace ||
        (_usesTabletWorkspace &&
            _sessionItems.any((s) => s.device.uid == deviceItem.uid))) {
      setState(() {
        _selectedDesktopPeerId = deviceItem.uid;
      });
      return;
    }
    Widget page(BuildContext context) =>
        SendMessageScreen(device: deviceItem, onDeviceDeleted: _removeDevice);
    await Navigator.push(
      context,
      whisperNewUi
          ? WhisperPageRoute<void>(builder: page)
          : MaterialPageRoute(builder: page),
    );
    _refreshDevice();
  }

  /// A device on screen: selected beside a sidebar, the top of the stack on a
  /// phone, whichever way the window is now.
  void _shellShowDevice(String uid) {
    setState(() {
      _selectedDesktopPeerId = uid;
      _shellPlace = ShellPlace.device;
    });
    ShellContent.showDevice();
  }

  Future<void> _confirmRemoveDevice(DeviceData target) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await app_dialogs.confirmAction(
      context,
      title: l10n?.deleteDeviceTitle(target.name) ?? '删除 ${target.name}',
      description: l10n?.deleteDeviceDesc ?? '删除与此设备的所有消息，不可恢复',
      confirmButtonText: l10n?.confirm ?? '确定',
      cancelButtonText: l10n?.cancel ?? '取消',
      isDestructive: true,
    );
    if (confirmed) {
      await _removeDevice(target.uid);
    }
  }

  Future<void> _removeDevice(String uid) async {
    _connectionAttempts.cancel('peer:$uid');
    ComposerDrafts.shared.forget(uid);
    await socketManager.deletePeer(uid);
    if (!mounted) {
      return;
    }
    setState(() {
      devices.removeWhere((item) => item.uid == uid);
      _sessionItems = _sessionItems
          .where((item) => item.device.uid != uid)
          .toList(growable: false);
      if (_selectedDesktopPeerId == uid) {
        _selectedDesktopPeerId = null;
      }
    });
    await _refreshDevice();
  }

  void _handleDeviceConnect(DeviceData deviceItem) {
    final isConnected = socketManager.isConnectedTo(deviceItem.uid);
    showConfirmationDialog(
      context,
      title: isConnected
          ? AppLocalizations.of(context)?.brokeConnectTitle ?? "断开连接"
          : AppLocalizations.of(context)?.connectDeviceTitle ?? "连接设备",
      description:
          '${isConnected ? AppLocalizations.of(context)?.disconnect ?? "断开" : AppLocalizations.of(context)?.connectTo ?? "连接到"} ${deviceItem.name}',
      confirmButtonText: AppLocalizations.of(context)?.confirm ?? '确定',
      cancelButtonText: AppLocalizations.of(context)?.cancel ?? '取消',
      onConfirm: () async {
        if (isConnected) {
          await socketManager.disconnectPeer(deviceItem.uid);
        } else {
          _connectServer(
            deviceItem.host,
            deviceItem.port,
            peerId: deviceItem.uid,
          );
        }
      },
    );
  }

  @Deprecated("use context menu, just for mobile")
  Widget _buildDeviceItemOld(ChatSessionItem session) {
    final deviceItem = session.device;
    bool ism = isMobile();
    return SwipeActionCell(
      key: ValueKey(deviceItem.uid),
      trailingActions: [
        if (!socketManager.isConnectedTo(deviceItem.uid))
          SwipeAction(
            widthSpace: ism ? 120 : 140,
            nestedAction: SwipeNestedAction(
              /// 自定义你nestedAction 的内容
              content: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: Colors.red,
                ),
                width: ism ? 100 : 120,
                height: 40,
                child: OverflowBox(
                  maxWidth: double.infinity,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.delete, color: Colors.white),
                      Text(
                        AppLocalizations.of(context)?.deleteConfirm ?? '确认删除 ',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: ism ? 16 : 18,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            /// 将原本的背景设置为透明，因为要用你自己的背景
            color: Colors.transparent,

            /// 设置了content就不要设置title和icon了
            content: _getIconButton(Colors.red, Icons.delete),
            onTap: (handler) {
              unawaited(_removeDevice(deviceItem.uid));
            },
          ),
      ],
      child: InkWell(
        onTap: () {
          _openConv(deviceItem);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              _buildSessionAvatar(session),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            deviceItem.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (_isTrustedDevice(deviceItem)) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: AppLocalizations.of(
                              context,
                            )!.e2eeTrustedConnection,
                            child: Icon(
                              Icons.verified_user_rounded,
                              size: 16,
                              color: context.whisperPalette.trusted,
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        Text(
                          _formatSessionTime(session.lastTimestamp),
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? Colors.white38
                                : Colors.black38,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        ConnectionStatusDot(
                          color: _sessionStatusColor(session),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: WhisperAnimatedSwitcher(
                            value: (session.isConnected, session.isNearby),
                            alignment: Alignment.centerLeft,
                            child: Text(
                              session.preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.white54
                                    : Colors.black45,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _getIconButton(color, icon) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),

        /// 设置你自己的背景
        color: color,
      ),
      child: Icon(icon, color: Colors.white),
    );
  }

  String _connectionDiagnosticDescription(ConnectionDiagnosticStage stage) {
    final l10n = AppLocalizations.of(context)!;
    return switch (stage) {
      ConnectionDiagnosticStage.wifi => l10n.connectionDiagnosticWifi,
      ConnectionDiagnosticStage.address => l10n.connectionDiagnosticAddress,
      ConnectionDiagnosticStage.service => l10n.connectionDiagnosticService,
      ConnectionDiagnosticStage.firewall => l10n.connectionDiagnosticFirewall,
      ConnectionDiagnosticStage.identity => l10n.connectionDiagnosticIdentity,
      ConnectionDiagnosticStage.version => l10n.connectionDiagnosticVersion,
      ConnectionDiagnosticStage.pairing => l10n.connectionDiagnosticPairing,
    };
  }

  void _showConnectionDiagnosticStage(
    ConnectionDiagnosticStage stage, {
    Future<void> Function()? onRetry,
    String? description,
  }) {
    final l10n = AppLocalizations.of(context)!;
    showWhisperDialog<void>(
      context,
      builder: (dialogContext) => WhisperGlassDialog(
        constraints: const BoxConstraints(
          minWidth: 300,
          maxWidth: 440,
          maxHeight: 620,
        ),
        title: Row(
          children: <Widget>[
            Icon(
              stage == ConnectionDiagnosticStage.identity
                  ? Icons.shield_outlined
                  : Icons.wifi_find_rounded,
              color: Theme.of(dialogContext).colorScheme.error,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.connectionDiagnosticTitle,
                style: Theme.of(
                  dialogContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        content: Text(description ?? _connectionDiagnosticDescription(stage)),
        actions: <Widget>[
          WhisperDialogButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            label: l10n.cancel,
          ),
          if (onRetry != null)
            WhisperDialogButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(onRetry());
              },
              label: l10n.retry,
              prominent: true,
            ),
        ],
      ),
    );
  }

  void _connectServer(
    String host,
    int port, {
    String? peerId,
    String? publicKeyHash,
  }) async {
    await _connectServerInternal(
      host,
      port,
      manual: true,
      peerId: peerId,
      publicKeyHash: publicKeyHash,
    );
  }

  Future<void> _connectServerInternal(
    String host,
    int port, {
    required bool manual,
    String? peerId,
    String? publicKeyHash,
  }) async {
    if (await isLocalhost(host)) {
      if (publicKeyHash?.isNotEmpty == true) {
        if (mounted) {
          _showConnectionDiagnosticStage(ConnectionDiagnosticStage.address);
        }
        return;
      }
      afterAuth(true, device);
      return;
    }
    if (manual && peerId != null) {
      await ConnectionCoordinator().markManualSelection(peerId);
    }
    if (!manual && peerId != null) {
      ConnectionCoordinator().markConnecting(peerId, reconnecting: true);
      _pendingAutoConnectPeerId = peerId;
      try {
        socketManager.scheduleReconnect(peerId, host, port);
      } on ArgumentError {
        ConnectionCoordinator().markDisconnected(peerId: peerId);
        _pendingAutoConnectPeerId = null;
      }
      return;
    }
    if (peerId != null) {
      ConnectionCoordinator().markConnecting(peerId);
      _pendingAutoConnectPeerId = peerId;
    }
    final targetKey = peerId?.isNotEmpty == true
        ? 'peer:$peerId'
        : 'endpoint:${host.trim()}:$port';
    final attemptGeneration = _connectionAttempts.begin(targetKey);
    try {
      ConnectionAttemptResult result;
      try {
        final endpoint = PeerEndpoint(host: host, port: port);
        result = await socketManager.connectToServer(
          ConnectionAttemptRequest(
            requestId: '$targetKey:$attemptGeneration',
            endpoint: endpoint,
            expectedPeerId: peerId ?? '',
            expectedPublicKeyHash: publicKeyHash ?? '',
            mode: ConnectionAttemptMode.interactive,
          ),
        );
      } on ArgumentError {
        result = ConnectionAttemptResult.networkFailure(
          requestId: '$targetKey:$attemptGeneration',
          reason: ConnectionAttemptReason.invalidEndpoint,
        );
      }
      if (!mounted ||
          !_connectionAttempts.isCurrent(targetKey, attemptGeneration)) {
        return;
      }
      if (result.isAuthenticated &&
          socketManager.isCurrentConnectionGeneration(
            result.peerId,
            result.generation,
          )) {
        final connectedDevice = await db.fetchDevice(result.peerId);
        if (!mounted ||
            !_connectionAttempts.isCurrent(targetKey, attemptGeneration) ||
            connectedDevice == null ||
            !socketManager.isCurrentConnectionGeneration(
              result.peerId,
              result.generation,
            )) {
          return;
        }
        socketManager.selectPeer(result.peerId);
        ConnectionCoordinator().markConnected(connectedDevice);
        _pendingAutoConnectPeerId = null;
        await _refreshDevice();
        if (!mounted ||
            !_connectionAttempts.isCurrent(targetKey, attemptGeneration)) {
          return;
        }
        if (whisperNewUi) {
          _shellShowDevice(connectedDevice.uid);
        } else if (_usesSplitWorkspace || _usesTabletWorkspace) {
          setState(() {
            _selectedDesktopPeerId = connectedDevice.uid;
          });
        } else {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => SendMessageScreen(
                device: connectedDevice,
                onDeviceDeleted: _removeDevice,
              ),
            ),
          );
          if (mounted) {
            _refreshDevice();
          }
        }
        return;
      }
      final localizations = AppLocalizations.of(context);
      if (result.reason == ConnectionAttemptReason.duplicateRequest) {
        // 同 peer 已有连接尝试在途:复位方法开头预置的 connecting 状态——
        // 挡路的在途尝试若以 cancelled/networkFailure 收场,不会有任何
        // 路径清理该状态,设备行会永久转圈。随后仅轻提示,不弹失败对话框;
        // 在途尝试成功时 markConnected 会自行恢复状态。
        if (peerId != null) {
          ConnectionCoordinator().markDisconnected(peerId: peerId);
        }
        if (_pendingAutoConnectPeerId == peerId) {
          _pendingAutoConnectPeerId = null;
        }
        if (manual) {
          showAppToast(
            localizations?.connectAlreadyInProgress ??
                'Connection already in progress',
          );
        }
        return;
      }
      final diagnostic = ConnectionDiagnostic.fromReason(result.reason);
      final displayMessage =
          result.reason == ConnectionAttemptReason.peerRejected &&
              localizations != null
          ? localizations.pairingRejectedByPeer
          : _connectionDiagnosticDescription(diagnostic.stage);
      ConnectionCoordinator().markDisconnected(
        peerId: peerId,
        error: displayMessage,
      );
      if (_pendingAutoConnectPeerId == peerId) {
        _pendingAutoConnectPeerId = null;
      }
      if (manual && result.status != ConnectionAttemptStatus.cancelled) {
        _showConnectionDiagnosticStage(
          diagnostic.stage,
          description: displayMessage,
          onRetry:
              diagnostic.stage == ConnectionDiagnosticStage.identity ||
                  diagnostic.stage == ConnectionDiagnosticStage.version
              ? null
              : () => _connectServerInternal(
                  host,
                  port,
                  manual: true,
                  peerId: peerId,
                  publicKeyHash: publicKeyHash,
                ),
        );
      }
    } finally {
      _connectionAttempts.complete(targetKey, attemptGeneration);
    }
  }

  Future<void> _attemptAutoConnect() async {
    final candidate = await ConnectionCoordinator()
        .chooseAutoConnectCandidate();
    if (candidate == null) {
      return;
    }
    await _connectServerInternal(
      candidate.host,
      candidate.port,
      manual: false,
      peerId: candidate.peerId,
    );
  }

  Future<void> _startServer({port}) async {
    await socketManager.reconcileInterruptedTransfersOnStartup();
    final result = await socketManager.startServer(
      port ?? device?.port ?? 10002,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      socketManager.started = result.isSuccess;
    });
    if (result.isSuccess) {
      if (Platform.isAndroid) {
        final keepAliveEnabled = await LocalSetting()
            .androidBackgroundKeepAlive();
        if (!mounted) {
          return;
        }
        final l10n = AppLocalizations.of(context);
        final notification = AndroidKeepAliveNotification(
          title: l10n?.androidBackgroundKeepAliveActiveTitle ?? 'Whisper',
          description:
              l10n?.androidBackgroundKeepAliveActiveDesc ??
              'Listening for nearby connection requests',
        );
        await AndroidBackgroundKeepAliveCoordinator.shared.setEnabled(
          keepAliveEnabled,
          notification: notification,
        );
        await AndroidBackgroundKeepAliveCoordinator.shared.setReason(
          AndroidKeepAliveReason.lanServer,
          true,
          notification: notification,
        );
      }
      return;
    }
    await AndroidBackgroundKeepAliveCoordinator.shared.setReason(
      AndroidKeepAliveReason.lanServer,
      false,
    );
    final error = result.error;
    privacyLog.event(PrivacyEvent.localOperation, <PrivacyField, Object>{
      PrivacyField.kind: DeviceListOperationKind.serverStart,
      PrivacyField.success: false,
      if (error != null) PrivacyField.errorType: privacyLog.errorType(error),
    });
    if (mounted) {
      unawaited(_recoverServerStart(error, port ?? device?.port ?? 10002));
    }
  }

  bool _serverStartFailureVisible = false;

  Future<void> _recoverServerStart(Object? error, int port) async {
    if (_serverStartFailureVisible || !mounted) return;
    _serverStartFailureVisible = true;
    ServerStartRecovery? recovery;
    try {
      recovery = await showServerStartFailureDialog(
        context,
        error: error,
        port: port,
      );
    } finally {
      _serverStartFailureVisible = false;
    }
    if (!mounted) return;
    if (recovery == ServerStartRecovery.retry) {
      await _startServer(port: port);
    } else if (recovery == ServerStartRecovery.settings && whisperNewUi) {
      await _shellOpenSettings();
    } else if (recovery == ServerStartRecovery.settings) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => app_settings.SettingsScreen(
            exitForUpdate: _shutdownAndDestroyWindow,
          ),
        ),
      );
      if (mounted) await _refreshDevice();
    }
  }

  @override
  void onPairing(PairingRequest request, void Function(bool) resolve) {
    if (!mounted) {
      resolve(false);
      return;
    }
    final pairingQrController = _activePairingQrController;
    unawaited(_presentPairingRequest(request, resolve, pairingQrController));
  }

  Future<void> _presentPairingRequest(
    PairingRequest request,
    void Function(bool) resolve,
    PairingQrDialogController? pairingQrController,
  ) async {
    await revealDesktopWindowForAttention();
    if (request.presentation?.isDismissed == true) {
      return;
    }
    if (!mounted) {
      resolve(false);
      return;
    }
    if (whisperNewUi && isDesktop()) {
      askPairing(AppLocalizations.of(context)!, request, (allow) {
        if (allow) pairingQrController?.dismiss();
        resolve(allow);
      });
      return;
    }
    await showPairingDialog(
      context,
      request: request,
      resolve: (allow) {
        if (allow) {
          pairingQrController?.dismiss();
        }
        resolve(allow);
      },
    );
  }

  @override
  void afterAuth(bool allow, DeviceData? deviceData) async {
    if (!allow || deviceData == null) {
      return;
    }
    await db.upsertDevice(deviceData);
    ConnectionCoordinator().markConnected(deviceData);
    _pendingAutoConnectPeerId = null;
    await _refreshDevice();
    if (!mounted) {
      return;
    }
    if (whisperNewUi) {
      _shellShowDevice(deviceData.uid);
      return;
    }
    if (_usesSplitWorkspace || _usesTabletWorkspace) {
      setState(() {
        _selectedDesktopPeerId = deviceData.uid;
      });
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SendMessageScreen(
          device: deviceData,
          onDeviceDeleted: _removeDevice,
        ),
      ),
    );
    _refreshDevice();
  }

  @override
  void onClose() {
    final coordinator = ConnectionCoordinator();
    final stillConnected = socketManager.connectedPeerIds;
    final previouslyConnected = coordinator.snapshot.connectedPeerIds;
    for (final peerId in previouslyConnected) {
      if (!stillConnected.contains(peerId)) {
        coordinator.markDisconnected(peerId: peerId);
      }
    }
    if (previouslyConnected.isEmpty && stillConnected.isEmpty) {
      coordinator.markDisconnected();
    }
    _pendingAutoConnectPeerId = null;
    _refreshDevice();
  }

  @override
  void onConnect() {
    _pendingAutoConnectPeerId = null;
    _refreshDevice();
  }

  var _isAlert = false;

  @override
  void onError(String message) {
    if (_isAlert) {
      return;
    }
    _isAlert = true;
    unawaited(_handleSocketError(message));
  }

  Future<void> _handleSocketError(String message) async {
    if (!mounted) {
      _isAlert = false;
      return;
    }
    final l10n = AppLocalizations.of(context);
    try {
      final confirmed = await app_dialogs.confirmAction(
        context,
        title: l10n?.timeoutTitle ?? "是否释放连接",
        description: l10n?.connectFailed ?? 'Connection Failed',
        confirmButtonText: l10n?.disconnect ?? "断开",
        cancelButtonText: l10n?.keepConnect ?? "取消",
      );
      if (confirmed) {
        await WsSvrManager().close();
      }
    } catch (error) {
      _logDeviceListFailure(DeviceListOperationKind.socketDialog, error);
      if (mounted) {
        showAppToast(
          l10n?.connectFailed ?? 'Connection Failed',
          tone: AppToastTone.error,
        );
      }
    } finally {
      _isAlert = false;
    }
  }

  @override
  void onNotice(String message) {
    final l10n = AppLocalizations.of(context);
    showAppToast(
      l10n == null ? 'Transfer failed' : transferFailureNotice(l10n, message),
      tone: AppToastTone.error,
    );
  }

  @override
  void onMessage(MessageData messageData) {
    _refreshDevice();
  }

  @override
  void onTransferUpdated(TransferSnapshot snapshot) {
    if (whisperNewUi) {
      setState(() => _shellTransfers[snapshot.peerUid] = snapshot);
      TransferIslandSource.shared.update(snapshot);
    }
    // Device list only needs to refresh high-level presence state for now.
  }

  @override
  void onTrayIconMouseDown() async {
    final panel = _trayPanel;
    if (whisperNewUi && panel != null) {
      _pushTrayState();
      await panel.toggle();
      return;
    }
    await windowManager.show();
  }

  @override
  void onTrayIconMouseUp() async {
    // await windowManager.isVisible()? windowManager.hide(): windowManager.show();
  }

  @override
  void onTrayIconRightMouseDown() {
    // TODO: implement onTrayIconRightMouseDown
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseUp() {
    // TODO: implement onTrayIconRightMouseUp
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    // TODO: implement onTrayMenuItemClick
  }

  @override
  void onWindowBlur() {
    // TODO: implement onWindowBlur
  }

  @override
  void onWindowClose() async {
    if (_isDestroyingWindow) {
      return;
    }
    if (whisperNewUi &&
        await LocalSetting().isClose2Tray() &&
        !await _statusNotifierAvailable()) {
      // No tray to come back from: minimized it can still be found.
      await windowManager.minimize();
    } else if (await LocalSetting().isClose2Tray() &&
        await windowManager.isPreventClose()) {
      await windowManager.hide();
    } else {
      await _shutdownAndDestroyWindow();
    }
  }

  @override
  void onWindowDocked() {
    // TODO: implement onWindowDocked
  }

  @override
  void onWindowEnterFullScreen() {
    // TODO: implement onWindowEnterFullScreen
  }

  @override
  void onWindowEvent(String eventName) {
    // TODO: implement onWindowEvent
  }

  @override
  void onWindowFocus() {
    // TODO: implement onWindowFocus
    setState(() {});
  }

  @override
  void onWindowLeaveFullScreen() {
    // TODO: implement onWindowLeaveFullScreen
  }

  @override
  void onWindowMaximize() {
    // TODO: implement onWindowMaximize
  }

  @override
  void onWindowMinimize() {
    // TODO: implement onWindowMinimize
  }

  @override
  void onWindowMove() {
    // TODO: implement onWindowMove
  }

  @override
  void onWindowMoved() {
    // TODO: implement onWindowMoved
  }

  @override
  void onWindowResize() async {
    if (!Platform.isLinux ||
        await windowManager.isMaximized() ||
        await windowManager.isMinimized()) {
      return;
    }
    var rect = await windowManager.getBounds();
    LocalSetting().setWindowWidth(rect.width);
    LocalSetting().setWindowHeight(rect.height);
  }

  @override
  void onWindowResized() async {
    if (await windowManager.isMaximized() ||
        await windowManager.isMinimized()) {
      return;
    }
    var rect = await windowManager.getBounds();
    LocalSetting().setWindowWidth(rect.width);
    LocalSetting().setWindowHeight(rect.height);
  }

  @override
  void onWindowRestore() {
    // TODO: implement onWindowRestore
  }

  @override
  void onWindowUndocked() {
    // TODO: implement onWindowUndocked
  }

  @override
  void onWindowUnmaximize() {
    // TODO: implement onWindowUnmaximize
  }

  @override
  void onClipboardChanged() async {
    if (whisperNewUi) unawaited(_recordClipboard());
    final generation = ++_clipboardSyncGeneration;
    final inputState = _remoteInputCoordinator.state;
    final workspace = _remoteInputWorkspaceCoordinator.snapshot;
    final remoteClipboardTargets = <({String peerId, String sessionId})>{};
    if (isDesktop() &&
        inputState.role == RemoteInputRuntimeRole.source &&
        inputState.sessionId.isNotEmpty &&
        inputState.peerId.isNotEmpty) {
      remoteClipboardTargets.add((
        peerId: inputState.peerId,
        sessionId: inputState.sessionId,
      ));
    }
    if (isDesktop() &&
        inputState.role == RemoteInputRuntimeRole.sink &&
        inputState.sessionId.isNotEmpty &&
        inputState.peerId.isNotEmpty) {
      remoteClipboardTargets.add((
        peerId: inputState.peerId,
        sessionId: inputState.sessionId,
      ));
    }
    if (isDesktop() && workspace.isControllerLive) {
      for (final target in workspace.targets.values) {
        if (target.isConnected) {
          remoteClipboardTargets.add((
            peerId: target.peerId,
            sessionId: target.sessionId,
          ));
        }
      }
    }
    final clipboardAutoSyncEnabled = await LocalSetting().clipboardAutoSync();
    if (isMobile() && !clipboardAutoSyncEnabled) return;
    if (generation != _clipboardSyncGeneration) {
      return;
    }
    final canPublishRemotePayload =
        remoteClipboardTargets.isNotEmpty && clipboardAutoSyncEnabled;
    final fileDrafts = isDesktop()
        ? await _clipboardFileReader.readFileDrafts()
        : const <ClipboardFileDraft>[];
    traceRemoteClipboard(
      'clipboard_changed',
      count: fileDrafts.length,
      success: canPublishRemotePayload,
      reason: canPublishRemotePayload
          ? 'source_ready'
          : '${inputState.role.name}:${inputState.status.name}',
    );
    if (generation != _clipboardSyncGeneration) {
      return;
    }
    final paths = fileDrafts.map((draft) => draft.path).toList(growable: false);
    if (isOwnClipboardFiles(paths)) {
      // The file manager's copy, there for pasting in other apps.
      return;
    }
    if (paths.isNotEmpty) {
      for (final target in remoteClipboardTargets) {
        if (socketManager.remoteClipboardOwnsPaths(
          sessionId: target.sessionId,
          paths: paths,
        )) {
          return;
        }
      }
    }
    if (canPublishRemotePayload) {
      socketManager.markLocalWorkspaceClipboard();
    }
    if (isDesktop() && canPublishRemotePayload) {
      for (final target in remoteClipboardTargets) {
        await socketManager.clearRemoteClipboardSession(
          peerId: target.peerId,
          sessionId: target.sessionId,
        );
      }
      if (generation != _clipboardSyncGeneration) {
        return;
      }
    }
    if (fileDrafts.isNotEmpty) {
      if (canPublishRemotePayload) {
        final items = fileDrafts
            .map(RemoteClipboardLocalItem.file)
            .toList(growable: false);
        for (final target in remoteClipboardTargets) {
          await _publishRemoteClipboardItems(
            generation: generation,
            peerId: target.peerId,
            sessionId: target.sessionId,
            items: items,
          );
        }
      }
      return;
    }
    final text = await readClipboardTextForSync(
      fileDraftsProvider: () async => const <ClipboardFileDraft>[],
    );
    if (generation != _clipboardSyncGeneration) {
      return;
    }
    if (canPublishRemotePayload && (text == null || text.isEmpty)) {
      final image = await _clipboardImageReader.readImageBytes();
      if (generation != _clipboardSyncGeneration) {
        return;
      }
      if (image != null && image.isNotEmpty) {
        final items = <RemoteClipboardLocalItem>[
          RemoteClipboardLocalItem.bytes('Clipboard Image.png', image),
        ];
        for (final target in remoteClipboardTargets) {
          await _publishRemoteClipboardItems(
            generation: generation,
            peerId: target.peerId,
            sessionId: target.sessionId,
            items: items,
          );
        }
        return;
      }
    }
    if (text == null) {
      return;
    }
    if (canPublishRemotePayload) {
      for (final target in remoteClipboardTargets) {
        await socketManager.clearRemoteClipboardSession(
          peerId: target.peerId,
          sessionId: target.sessionId,
          notifyPeer: true,
        );
      }
    }
    if (shouldIgnoreClipboardSync(text)) {
      _clipboardText = text;
      return;
    }
    if (_clipboardText == text) {
      return;
    }
    _clipboardText = text;
    if (!clipboardAutoSyncEnabled) {
      return;
    }
    if (generation != _clipboardSyncGeneration) {
      return;
    }
    final syncsWorkspace = workspace.isControllerLive;
    final syncsControlledPeer =
        !syncsWorkspace &&
        inputState.role == RemoteInputRuntimeRole.sink &&
        inputState.peerId.isNotEmpty;
    final textPeerIds = syncsWorkspace
        ? workspace.connectedTargetPeerIds.toList(growable: false)
        : syncsControlledPeer
        ? <String>[inputState.peerId]
        : <String>[socketManager.receiver];
    for (final peerId in textPeerIds.toSet()) {
      if (peerId.isEmpty || !socketManager.isConnectedTo(peerId)) {
        continue;
      }
      if (!syncsWorkspace &&
          !syncsControlledPeer &&
          socketManager.receiver != peerId) {
        continue;
      }
      final target = await db.fetchDevice(peerId);
      final currentInputState = _remoteInputCoordinator.state;
      final targetIsCurrent = syncsWorkspace
          ? _remoteInputWorkspaceCoordinator
                    .snapshot
                    .targets[peerId]
                    ?.isConnected ==
                true
          : syncsControlledPeer
          ? currentInputState.role == RemoteInputRuntimeRole.sink &&
                currentInputState.peerId == peerId &&
                currentInputState.sessionId == inputState.sessionId
          : socketManager.receiver == peerId;
      if (generation != _clipboardSyncGeneration ||
          !targetIsCurrent ||
          !socketManager.isConnectedTo(peerId) ||
          target == null ||
          !target.auth ||
          !target.clipboard ||
          target.identityPublicKey.isEmpty) {
        continue;
      }
      await socketManager.sendMessageTo(peerId, text, clipboard: true);
    }
  }

  Future<void> _publishRemoteClipboardItems({
    required int generation,
    required String peerId,
    required String sessionId,
    required List<RemoteClipboardLocalItem> items,
  }) async {
    if (items.isEmpty ||
        items.length > remoteClipboardMaxItems ||
        items.any((item) => item.size > remoteClipboardMaxFileBytes) ||
        items.fold<int>(0, (sum, item) => sum + item.size) >
            remoteClipboardMaxBatchBytes) {
      traceRemoteClipboard('publish_skipped', reason: 'settings_or_limits');
      return;
    }
    final target = await db.fetchDevice(peerId);
    final legacyState = _remoteInputCoordinator.state;
    final workspaceTarget =
        _remoteInputWorkspaceCoordinator.snapshot.targets[peerId];
    final sessionIsLive =
        ((legacyState.role == RemoteInputRuntimeRole.source ||
                legacyState.role == RemoteInputRuntimeRole.sink) &&
            legacyState.peerId == peerId &&
            legacyState.sessionId == sessionId) ||
        (workspaceTarget?.isConnected == true &&
            workspaceTarget?.sessionId == sessionId);
    if (generation != _clipboardSyncGeneration ||
        !sessionIsLive ||
        target == null ||
        !target.auth ||
        !target.clipboard ||
        target.identityPublicKey.isEmpty ||
        !socketManager.isConnectedTo(peerId)) {
      traceRemoteClipboard('publish_skipped', reason: 'peer_or_session');
      return;
    }
    final published = await socketManager.publishRemoteClipboard(
      peerId: peerId,
      sessionId: sessionId,
      items: items,
    );
    traceRemoteClipboard('publish_done', success: published);
  }
}

class DeviceDetailsScreen extends StatelessWidget {
  final DeviceData device;

  const DeviceDetailsScreen({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(device.name.toString()), centerTitle: true),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('Device Name: ${device.name.toString()}'),
            Text('IP Address: ${device.host.toString()}'),
            device.isServer
                ? const Icon(Icons.desktop_mac) // Server 图标
                : const Icon(Icons.phone_android), // Client 图标
            // 其他设备详情信息...
          ],
        ),
      ),
    );
  }
}

void showConfirmationDialog(
  BuildContext context, {
  required String title,
  required String description,
  required String confirmButtonText,
  required String cancelButtonText,
  required VoidCallback onConfirm,
  VoidCallback? onCancel,
}) {
  unawaited(() async {
    final confirmed = await app_dialogs.confirmAction(
      context,
      title: title,
      description: description,
      confirmButtonText: confirmButtonText,
      cancelButtonText: cancelButtonText,
    );
    if (confirmed) {
      onConfirm();
    } else {
      onCancel?.call();
    }
  }());
}

void showInputAlertDialog(
  BuildContext context, {
  required String title,
  required String description,
  required List<Map<String, bool>> inputHints,
  required String confirmButtonText,
  required String cancelButtonText,
  required Function(List<String>) onConfirm,
}) {
  unawaited(() async {
    final values = await app_dialogs.showValidatedInputDialog(
      context,
      title: title,
      description: description,
      fields: inputHints
          .map((hint) {
            final entry = hint.entries.first;
            return app_dialogs.InputDialogField(
              initialValue: entry.key,
              label: entry.key,
              keyboardType: entry.value ? TextInputType.number : null,
              inputFormatters: entry.value
                  ? <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly]
                  : const <TextInputFormatter>[],
            );
          })
          .toList(growable: false),
      confirmButtonText: confirmButtonText,
      cancelButtonText: cancelButtonText,
    );
    if (values != null) {
      onConfirm(values);
    }
  }());
}

void showLoadingDialog(
  BuildContext context, {
  required String title,
  required String description,
  required bool isLoading,
  required Widget icon,
  required String cancelButtonText,
  bool showCancel = true,
  required VoidCallback onCancel,
  required Function(VoidCallback onCancel) task,
}) async {
  await app_dialogs.showLoadingDialog(
    context,
    title: title,
    description: description,
    isLoading: isLoading,
    icon: icon,
    cancelButtonText: cancelButtonText,
    showCancel: showCancel,
    onCancel: onCancel,
    task: task,
  );
}
