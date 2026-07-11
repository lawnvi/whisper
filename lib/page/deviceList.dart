import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:bonsoir/bonsoir.dart';
import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_group_session.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/helper/toast.dart';
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
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local_network_permission.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/main.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_screen.dart';
import 'package:whisper/state/app_shutdown.dart';
import 'package:whisper/state/chat_session_list.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/discovery_resolve_limiter.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_dialogs.dart' show confirmAction;
import 'package:whisper/widget/context_menu_region.dart';
import 'package:whisper/widget/pairing_dialog.dart';
import 'package:window_manager/window_manager.dart';
import '../helper/local.dart';
import '../helper/notification.dart';
import '../l10n/app_localizations.dart';
import '../socket/svrmanager.dart';
import 'appList.dart';
import 'conversation.dart';
import 'settings.dart' as app_settings;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;

enum DeviceListOperationKind {
  temporaryFileCleanup,
  audioToggle,
  socketDialog,
  serverStart,
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

void _logDeviceListFailure(DeviceListOperationKind kind, Object error) {
  privacyLog.event(
    PrivacyEvent.localOperation,
    <PrivacyField, Object>{
      PrivacyField.kind: kind,
      PrivacyField.success: false,
      PrivacyField.errorType: privacyLog.errorType(error),
    },
  );
}

void _logDiscovery(
  DiscoveryDiagnosticKind kind, {
  Enum? state,
}) {
  privacyLog.event(
    PrivacyEvent.discoveryState,
    <PrivacyField, Object>{
      PrivacyField.kind: kind,
      if (state != null) PrivacyField.state: state,
    },
  );
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

class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key});

  @override
  _DeviceListScreen createState() => _DeviceListScreen();

  static void setListenApps() {
    _DeviceListScreen.setListenApps();
  }
}

class _DeviceListScreen extends State<DeviceListScreen>
    implements ISocketEvent, TrayListener, WindowListener, ClipboardListener {
  static const double _desktopToolbarPillHeight = 38;
  static const double _desktopToolbarGap = 10;
  static const double _desktopToolbarToolGroupWidth = 140;
  static const Duration _desktopToolbarAnimationDuration =
      Duration(milliseconds: 220);
  static const Curve _desktopToolbarAnimationCurve = Curves.easeOutCubic;

  final db = LocalDatabase();
  final socketManager = WsSvrManager();
  final AudioShareCoordinator _audioCoordinator = AudioShareCoordinator.shared;
  final AudioGroupCoordinator _audioGroupCoordinator =
      AudioGroupCoordinator.shared;
  final RemoteInputCoordinator _remoteInputCoordinator =
      RemoteInputCoordinator.shared;
  final RemoteInputWorkspaceCoordinator _remoteInputWorkspaceCoordinator =
      RemoteInputWorkspaceCoordinator.shared;
  DeviceData? device;
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
  static var listenApps = {};
  var _clipboardText = "";
  final TextEditingController _desktopSearchController =
      TextEditingController();
  final FocusNode _desktopSearchFocusNode = FocusNode();
  final AppShutdownCoordinator _shutdownCoordinator = AppShutdownCoordinator();
  final ConnectionAttemptTracker _connectionAttempts =
      ConnectionAttemptTracker();
  List<ChatSessionItem> _sessionItems = const [];
  String _desktopSearchQuery = "";
  bool _isDesktopSearchExpanded = false;
  String? _selectedDesktopPeerId;
  String? _pendingAutoConnectPeerId;
  Future<void>? _desktopShutdownFuture;
  bool _isDestroyingWindow = false;

  BorderRadius get _desktopToolbarPillRadius => BorderRadius.circular(14);

  Color get _desktopToolbarPillColor => context.whisperPalette.surfaceMuted;

  @override
  void initState() {
    // if (!kIsWeb &&
    //     (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
    //   initSystemTray();
    // }
    _setDesktopWindow();
    _requestPermission();
    _desktopSearchFocusNode.addListener(_handleDesktopSearchFocusChanged);
    _audioCoordinator.addListener(_handleDesktopAudioChanged);
    _audioGroupCoordinator.addListener(_handleDesktopAudioChanged);
    _remoteInputCoordinator.addListener(
      _handleDesktopRemoteInputWorkspaceChanged,
    );
    _remoteInputWorkspaceCoordinator.addListener(
      _handleDesktopRemoteInputWorkspaceChanged,
    );
    clipboardWatcher.addListener(this);
    // start watch
    clipboardWatcher.start();
    super.initState();
  }

  @override
  void didChangeDependencies() async {
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
      if (await Permission.manageExternalStorage.isDenied) {
        await Permission.manageExternalStorage.request();
      }
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
      initPlatformState();
      unawaited(notifyExistingDownloadsVisibleToAndroidPickers());
    } else if (Platform.isIOS) {
      await LocalNetworkPermission().ensureGranted();
    }

    var permissions = [Permission.storage];

    for (var item in permissions) {
      if (await item.isDenied) {
        await item.request();
      }
    }

    _clipboardText = await getClipboardText() ?? "";
  }

  static void setListenApps() async {
    listenApps = await LocalSetting().listenAppNotifyList();
  }

  @pragma('vm:entry-point')
  static void _callback(NotificationEvent evt) {
    var soc = WsSvrManager();
    final allowed = soc.isConnected &&
        filterNotification(evt) &&
        listenApps.containsKey(evt.packageName);
    privacyLog.event(
      PrivacyEvent.notificationForwarded,
      <PrivacyField, Object>{PrivacyField.allowed: allowed},
    );
    if (allowed) {
      soc.sendNotification(evt.packageName, evt.title, evt.text);
    }
  }

  Future<void> initPlatformState() async {
    // register the static to handle the events
    NotificationsListener.initialize(callbackHandle: _callback);
    // NotificationsListener.receivePort?.listen((evt) => _callback(evt));
  }

  Future<void> _setDesktopWindow() async {
    if (isMobile()) {
      final cleared = await FilePicker.platform.clearTemporaryFiles();
      privacyLog.event(
        PrivacyEvent.localOperation,
        <PrivacyField, Object>{
          PrivacyField.kind: DeviceListOperationKind.temporaryFileCleanup,
          PrivacyField.success: cleared ?? false,
        },
      );
      return;
    }
    await windowManager.setPreventClose(true);
    await trayManager.setIcon(
      Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon_round.png',
    );

    Menu menu = Menu(
      items: [
        MenuItem(
            key: 'show_window',
            label: AppLocalizations.of(context)?.menuShow ?? "显示",
            onClick: (MenuItem item) {
              windowManager.show();
            }),
        MenuItem(
            key: 'hide_window',
            label: AppLocalizations.of(context)?.menuHide ?? "隐藏",
            onClick: (MenuItem item) {
              windowManager.hide();
            }),
        MenuItem(
            key: 'clipboard',
            label: AppLocalizations.of(context)?.menuClipboard ?? "发送剪切板",
            onClick: (MenuItem item) {
              socketManager.sendMessage("", clipboard: true);
            }),
        MenuItem(
            key: 'pick_file',
            label: AppLocalizations.of(context)?.menuSendFile ?? "发送文件",
            onClick: (MenuItem item) async {
              if (!socketManager.isConnected) {
                return;
              }
              FilePickerResult? result =
                  await FilePicker.platform.pickFiles(allowMultiple: true);
              if (result != null) {
                for (var item in result.files) {
                  await socketManager.sendFile(item.path ?? "");
                }
              }
            }),
        MenuItem.separator(),
        MenuItem(
            key: 'exit_app',
            label: AppLocalizations.of(context)?.exit ?? '退出',
            onClick: (MenuItem menuItem) async {
              await _shutdownAndDestroyWindow();
            }),
      ],
    );
    await trayManager.setContextMenu(menu);
    trayManager.addListener(this);
    windowManager.addListener(this);
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
    // 在这里执行一些清理操作，比如取消订阅、关闭流、释放资源等
    _broadcastRestartTimer?.cancel();
    _connectionAttempts.cancelAll();
    unawaited(_stopDiscovery());
    unawaited(_stopBroadcast());
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    clipboardWatcher.removeListener(this);
    socketManager.unregisterEvent(this);
    _desktopSearchFocusNode.removeListener(_handleDesktopSearchFocusChanged);
    _audioCoordinator.removeListener(_handleDesktopAudioChanged);
    _audioGroupCoordinator.removeListener(_handleDesktopAudioChanged);
    _remoteInputCoordinator.removeListener(
      _handleDesktopRemoteInputWorkspaceChanged,
    );
    _remoteInputWorkspaceCoordinator.removeListener(
      _handleDesktopRemoteInputWorkspaceChanged,
    );
    _desktopSearchController.dispose();
    _desktopSearchFocusNode.dispose();
    // stop watch
    unawaited(clipboardWatcher.stop());
    super.dispose();
  }

  Future<void> _stopClipboardWatcher() async {
    clipboardWatcher.removeListener(this);
    await clipboardWatcher.stop();
  }

  Future<void> _destroyTray() async {
    trayManager.removeListener(this);
    await trayManager.destroy();
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

  Future<void> _stopSocketServer() {
    return socketManager.closeGracefully(
      closeServer: true,
      forceServerClose: true,
    );
  }

  Future<void> _closeDatabase() async {
    await db.close();
  }

  Future<void> _shutdownDesktopResources() {
    return _desktopShutdownFuture ??= _shutdownCoordinator.run([
      _stopDiscovery,
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
    await _shutdownDesktopResources();
    await windowManager.destroy();
  }

  void _broadcastService({port}) async {
    final wifiIP = await getLocalIpAddress();

    if (wifiIP == "127.0.0.1") {
      _isBroadcasting = false;
      return;
    }

    await _stopBroadcast(close: false);
    BonsoirService service = BonsoirService(
      name: buildWhisperServiceName(serviceName, device?.uid ?? ""),
      type: serviceType,
      port: 10004,
      attributes: {
        'host': wifiIP,
        'port': (port ?? device?.port ?? 10002).toString(),
        'name': device?.name ?? await deviceName(),
        'platform': device?.platform ?? "未知",
        'uid': device?.uid ?? "",
      },
    );

    // And now we can broadcast it :
    _broadcast = BonsoirBroadcast(service: service);
    await _broadcast!.ready;

    _broadcastSubscription?.cancel();
    _broadcastSubscription = _broadcast!.eventStream!.listen((event) {
      _logDiscovery(
        DiscoveryDiagnosticKind.broadcastEvent,
        state: event.type,
      );
    });

    await _broadcast!.start();
    _isBroadcasting = true;
  }

  Future<void> _stopBroadcast({close = true}) async {
    _broadcastRestartTimer?.cancel();
    _broadcastRestartTimer = null;
    await _broadcastSubscription?.cancel();
    _broadcastSubscription = null;
    await _broadcast?.stop();
    _broadcast = null;
    _isBroadcasting = !close;
  }

  Future<void> _discoverService() async {
    await _stopDiscovery();
    // This is the type of service we're looking for :

    // Once defined, we can start the discovery :
    _discovery = BonsoirDiscovery(type: serviceType, printLogs: false);
    await _discovery!.ready;

    // If you want to listen to the discovery :
    _discoverySubscription?.cancel();
    _discoverySubscription = _discovery?.eventStream!.listen((event) async {
      _logDiscovery(
        DiscoveryDiagnosticKind.discoveryEvent,
        state: event.type,
      );
      // `eventStream` is not null as the discovery instance is "ready" !
      final service = event.service;
      if (service != null) {
        switch (event.type) {
          case BonsoirDiscoveryEventType.discoveryServiceFound:
            _logDiscovery(DiscoveryDiagnosticKind.serviceFound);
            if (service.name.startsWith(serviceName) &&
                _shouldResolveService(service)) {
              event.service!.resolve(_discovery!.serviceResolver);
            }
            break;
          case BonsoirDiscoveryEventType.discoveryStarted:
            _logDiscovery(DiscoveryDiagnosticKind.discoveryStarted);
            break;
          case BonsoirDiscoveryEventType.discoveryServiceResolved ||
                BonsoirDiscoveryEventType.discoveryServiceLost:
            final svr = service;
            if (!svr.attributes.containsKey('uid')) {
              _logDiscovery(DiscoveryDiagnosticKind.serviceSkipped);
              return;
            }
            var isLost =
                event.type == BonsoirDiscoveryEventType.discoveryServiceLost;
            final host = svr.attributes["host"];
            final port =
                int.tryParse(svr.attributes["port"] ?? "10002") ?? 10002;
            final uid = svr.attributes["uid"];
            final name = svr.attributes["name"];
            final platform = svr.attributes["platform"];
            _logDiscovery(
              isLost
                  ? DiscoveryDiagnosticKind.serviceLost
                  : DiscoveryDiagnosticKind.serviceResolved,
            );
            if (uid == null || uid == device?.uid) {
              return;
            }
            if (isLost) {
              _resolveLimiter.clear(_serviceResolveKey(svr));
            }
            var temp = await LocalDatabase().fetchDevice(uid);
            final resolvedDevice = buildDevice(
              uid: uid,
              name: temp?.name ?? name,
              port: port,
              host: host,
              platform: platform,
              around: !isLost,
            );
            final visibleDevice = _mergeStoredDeviceWithDiscovery(
              temp,
              resolvedDevice,
            );
            if (!isLost) {
              await db.upsertDevice(visibleDevice);
            }
            await ConnectionCoordinator().updateDiscovery(
              visibleDevice,
              discovered: !isLost,
            );
            if (!isLost && host != null) {
              try {
                socketManager.updateReconnectEndpoint(uid, host, port);
              } on ArgumentError {
                // Invalid discovery endpoints are never promoted to retries.
              }
            }
            for (var item in devices) {
              if (item.uid == uid) {
                break;
              }
            }
            setState(() {
              var index = -1;
              for (var i = devices.length - 1; i >= 0; i--) {
                if (devices[i].uid == uid) {
                  index = i;
                  devices.removeAt(i);
                  break;
                }
              }
              if (isLost && temp != null) {
                devices.insert(index, temp);
              } else if (!isLost) {
                devices.insert(0, visibleDevice);
              }
            });
            _refreshDevice();
            if (!isLost) {
              await _attemptAutoConnect();
            }
            break;
          case BonsoirDiscoveryEventType.discoveryServiceResolveFailed:
          // TODO: Handle this case.
          case BonsoirDiscoveryEventType.discoveryStopped:
          // TODO: Handle this case.
          case BonsoirDiscoveryEventType.unknown:
          // TODO: Handle this case.
        }
      }
    });

    // Start discovery **after** having listened to discovery events :
    await _discovery?.start();
    _isDiscovering = true;
  }

  Future<void> _stopDiscovery() async {
    await _discoverySubscription?.cancel();
    _discoverySubscription = null;
    await _discovery?.stop();
    _discovery = null;
    _isDiscovering = false;
  }

  DeviceData buildDevice(
      {uid = "",
      name = "",
      host = "",
      port = 10002,
      platform = "",
      around = true}) {
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
        around: around);
  }

  DeviceData _mergeStoredDeviceWithDiscovery(
    DeviceData? stored,
    DeviceData discovered,
  ) {
    if (stored == null) {
      return discovered;
    }
    return DeviceData(
      id: stored.id,
      uid: discovered.uid,
      name: discovered.name.isNotEmpty ? discovered.name : stored.name,
      host: discovered.host.isNotEmpty ? discovered.host : stored.host,
      port: discovered.port,
      password: stored.password,
      platform: discovered.platform.isNotEmpty
          ? discovered.platform
          : stored.platform,
      isServer: stored.isServer,
      online: stored.online,
      clipboard: stored.clipboard,
      auth: stored.auth,
      lastTime: discovered.lastTime,
      around: discovered.around,
    );
  }

  Future<void> _refreshDevice({isFirst = false}) async {
    var temp = await LocalSetting().instance();
    var arr = await db.fetchAllDevice();
    final storedDevicesByUid = <String, DeviceData>{
      for (final item in arr) item.uid: item,
    };
    await ConnectionCoordinator().bootstrap(temp.uid);
    await ConnectionCoordinator().syncKnownDevices(arr);
    var newArr = <DeviceData>[];
    var aroundIds = <String>{};
    for (var item in devices) {
      if (aroundIds.contains(item.uid)) {
        continue;
      }
      if (socketManager.isConnectedTo(item.uid)) {
        newArr.insert(
          0,
          _mergeStoredDeviceWithDiscovery(storedDevicesByUid[item.uid], item),
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

    if (isFirst || device?.port != temp.port) {
      await _startServer(port: temp.port);
    }

    final latestMessages = await db
        .fetchLatestMessagesByPeers(newArr.map((item) => item.uid).toList());
    final sessions = ChatSessionListBuilder.build(
      devices: newArr,
      latestMessages: latestMessages,
      activePeerId:
          socketManager.receiver.isEmpty ? null : socketManager.receiver,
      connectedPeerIds: socketManager.connectedPeerIds,
      selectedPeerId: _selectedDesktopPeerId,
      strings: _sessionPreviewStrings(context),
    );
    final selectedPeerId = _selectedDesktopPeerId != null &&
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
    });

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
      setListenApps();
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
    final isDesk = isDesktop();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isDesk) {
      return _buildDesktopScaffold(isDark);
    }
    return _buildMobileScaffold(isDark);
  }

  Widget _buildMobileScaffold(bool isDark) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: _showManualConnectDialog,
          color: Colors.grey,
          icon: const Icon(Icons.add, size: 32), // 调整圆角以获得更圆的按钮
        ),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(device?.name ?? "localhost"), // 替换为实际昵称
                Row(
                  children: [
                    Text(
                      "${device?.host ?? "127.0.0.1"}:${device?.port ?? 10002}",
                      // 替换为实际 IP 地址
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white54
                              : Colors.black54),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.wifi_rounded,
                        size: socketManager.started ? 14 : 0,
                        color: Colors.lightBlue)
                  ],
                )
              ],
            ),
          ],
        ),
        // automaticallyImplyLeading: true, // 隐藏返回按钮
        actions: [
          if (false)
            CupertinoButton(
              // 使用CupertinoButton
              padding: EdgeInsets.zero,
              child: const Icon(
                Icons.chat_bubble_outline_rounded,
                size: 26,
                color: Colors.black45,
              ),
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => SendMessageScreen(
                        device: buildDevice(
                            uid: LocalUuid.v4(),
                            name: "",
                            port: -1,
                            host: "localhost")),
                  ),
                );
                _refreshDevice();
              },
            ),
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
                  builder: (context) => const app_settings.SettingsScreen(),
                ),
              );
              _refreshDevice();
            },
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: _sessionItems.length,
        itemBuilder: (context, index) {
          return _buildDeviceItemOld(_sessionItems[index]);
        },
      ),
    );
  }

  Widget _buildDesktopScaffold(bool isDark) {
    final selectedSession = _selectedDesktopSession();
    final visibleSessions = _visibleSessions();
    final palette = context.whisperPalette;
    return Scaffold(
      backgroundColor: palette.surfaceCanvas,
      body: SafeArea(
        child: Row(
          children: [
            Container(
              width: 340,
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                border: Border(
                  right: BorderSide(
                    color: palette.borderSubtle,
                  ),
                ),
              ),
              child: Column(
                children: [
                  _buildDesktopSidebarToolbar(),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      itemCount: visibleSessions.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final session = visibleSessions[index];
                        return _buildDesktopSessionTile(
                          session,
                          selected:
                              session.device.uid == _selectedDesktopPeerId,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: selectedSession == null
                  ? _buildDesktopPlaceholder(isDark)
                  : SendMessageScreen(
                      key: ValueKey('desktop-${selectedSession.device.uid}'),
                      device: selectedSession.device,
                      embedded: true,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopSidebarToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: SizedBox(
        height: 40,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxWidth = constraints.maxWidth;
            final collapsedSearchWidth =
                (maxWidth - _desktopToolbarGap - _desktopToolbarToolGroupWidth)
                    .clamp(0.0, maxWidth)
                    .toDouble();
            final searchWidth =
                _isDesktopSearchExpanded ? maxWidth : collapsedSearchWidth;
            final gapWidth =
                _isDesktopSearchExpanded ? 0.0 : _desktopToolbarGap;
            final toolGroupWidth =
                _isDesktopSearchExpanded ? 0.0 : _desktopToolbarToolGroupWidth;

            return ClipRect(
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: _desktopToolbarAnimationDuration,
                    curve: _desktopToolbarAnimationCurve,
                    width: searchWidth,
                    child: _buildDesktopSearchPill(
                      expanded: _isDesktopSearchExpanded,
                    ),
                  ),
                  AnimatedContainer(
                    duration: _desktopToolbarAnimationDuration,
                    curve: _desktopToolbarAnimationCurve,
                    width: gapWidth,
                  ),
                  _buildCollapsibleDesktopToolGroup(width: toolGroupWidth),
                ],
              ),
            );
          },
        ),
      ),
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
                decoration: const BoxDecoration(
                  color: Colors.transparent,
                ),
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

  Widget _buildCollapsibleDesktopToolGroup({required double width}) {
    return ClipRect(
      child: AnimatedContainer(
        duration: _desktopToolbarAnimationDuration,
        curve: _desktopToolbarAnimationCurve,
        width: width,
        child: Align(
          alignment: Alignment.centerRight,
          child: OverflowBox(
            alignment: Alignment.centerRight,
            minWidth: _desktopToolbarToolGroupWidth,
            maxWidth: _desktopToolbarToolGroupWidth,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 140),
              opacity: _isDesktopSearchExpanded ? 0 : 1,
              child: IgnorePointer(
                ignoring: _isDesktopSearchExpanded,
                child: _buildDesktopToolGroup(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopToolGroup() {
    return SizedBox(
      width: _desktopToolbarToolGroupWidth,
      child: Container(
        height: _desktopToolbarPillHeight,
        padding: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: _desktopToolbarPillColor,
          borderRadius: _desktopToolbarPillRadius,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDesktopToolButton(
              icon: Icons.add,
              tooltip: AppLocalizations.of(context)?.connect ?? '连接',
              onPressed: _showManualConnectDialog,
            ),
            const SizedBox(width: 2),
            _buildDesktopAudioShareAction(),
            const SizedBox(width: 2),
            _buildDesktopRemoteInputWorkspaceAction(),
            const SizedBox(width: 2),
            _buildDesktopToolButton(
              icon: Icons.settings_outlined,
              tooltip: AppLocalizations.of(context)?.setting ?? '设置',
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const app_settings.SettingsScreen(),
                  ),
                );
                _refreshDevice();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopAudioShareAction() {
    final palette = context.whisperPalette;
    final isActive = _isDesktopAudioShareActive;
    final isBusy = _isDesktopAudioShareBusy;
    return _buildDesktopToolButton(
      icon: isBusy ? Icons.sync_rounded : Icons.volume_up_outlined,
      tooltip: _desktopAudioShareTooltip(
        isActive: isActive,
        isBusy: isBusy,
      ),
      iconColor: isActive || isBusy ? Colors.lightBlue : palette.textMuted,
      onPressed: isBusy ? null : _toggleDesktopAudioShare,
    );
  }

  Widget _buildDesktopRemoteInputWorkspaceAction() {
    final palette = context.whisperPalette;
    final snapshot = _remoteInputWorkspaceCoordinator.snapshot;
    final legacyState = _remoteInputCoordinator.state;
    final legacyLive = legacyState.status != RemoteInputRuntimeStatus.idle &&
        legacyState.status != RemoteInputRuntimeStatus.failed;
    final isActive =
        snapshot.isControllerLive || snapshot.isControlledLive || legacyLive;
    final isBusy = snapshot.status == RemoteInputWorkspaceStatus.offering ||
        legacyState.status == RemoteInputRuntimeStatus.offering ||
        legacyState.status == RemoteInputRuntimeStatus.connecting;
    return _buildDesktopToolButton(
      icon: Icons.keyboard_alt_outlined,
      tooltip:
          AppLocalizations.of(context)?.remoteInputWorkspaceTooltip ?? '键鼠工作区',
      iconColor: isActive || isBusy ? Colors.lightBlue : palette.textMuted,
      onPressed: _openRemoteInputWorkspace,
    );
  }

  Widget _buildDesktopToolButton({
    required IconData icon,
    required VoidCallback? onPressed,
    Color? iconColor,
    String? tooltip,
  }) {
    final palette = context.whisperPalette;
    return SizedBox(
      width: 32,
      height: 32,
      child: Tooltip(
        message: tooltip ?? '',
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(11),
          onPressed: onPressed,
          child: Icon(
            icon,
            size: 20,
            color: iconColor ?? palette.textMuted,
          ),
        ),
      ),
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
        showAppToast(l10n.audioShareFailed(detail));
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
    final l10n = AppLocalizations.of(context)!;
    await _audioGroupCoordinator.stopGroup(
      sendControl: socketManager.sendAudioGroupControlTo,
    );
    if (mounted) {
      showAppToast(l10n.audioShareCaptureStopped);
    }
  }

  Future<void> _applyDesktopAudioGroupSelection({
    required String sourcePeerId,
    required Map<String, AudioChannelRole> sinks,
    bool replaceActive = false,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    if (replaceActive && _audioGroupCoordinator.session?.isLive == true) {
      await _audioGroupCoordinator.updateGroup(
        sinks: sinks,
        sendControl: socketManager.sendAudioGroupControlTo,
      );
      if (mounted) {
        showAppToast(l10n.audioGroupRequestingPlayback);
      }
      return;
    }
    _audioGroupCoordinator.startGroup(
      sourcePeerId: sourcePeerId,
      sinks: sinks,
      format: AudioShareCoordinator.defaultFormat,
      sendControl: socketManager.sendAudioGroupControlTo,
    );
    if (mounted) {
      showAppToast(l10n.audioGroupRequestingPlayback);
    }
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
        candidates[index].uid: initialSinks[candidates[index].uid] ??
            (index == 0
                ? AudioChannelRole.left
                : (index == 1
                    ? AudioChannelRole.right
                    : AudioChannelRole.stereo)),
    };
    final l10n = AppLocalizations.of(context)!;
    return showModalBottomSheet<_AudioGroupSetupResult>(
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
                      child: AnimatedBuilder(
                        animation: _audioGroupCoordinator,
                        builder: (context, _) {
                          return ListView.builder(
                            shrinkWrap: true,
                            itemCount: candidates.length,
                            itemBuilder: (context, index) {
                              final candidate = candidates[index];
                              final isSelected =
                                  selected[candidate.uid] ?? false;
                              return CheckboxListTile(
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                value: isSelected,
                                onChanged: (value) {
                                  setSheetState(() {
                                    selected[candidate.uid] = value ?? false;
                                  });
                                },
                                title: _buildAudioGroupDeviceTitle(candidate),
                                subtitle: _buildAudioGroupSinkSubtitle(
                                  candidate,
                                ),
                                secondary: DropdownButton<AudioChannelRole>(
                                  value: roles[candidate.uid],
                                  underline: const SizedBox.shrink(),
                                  isDense: true,
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
                                          child:
                                              Text(_audioGroupRoleLabel(role)),
                                        ),
                                      )
                                      .toList(growable: false),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (allowStop) ...[
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(context).pop(
                            const _AudioGroupSetupResult.stop(),
                          );
                        },
                        icon: const Icon(Icons.stop_rounded),
                        label: Text(l10n.audioGroupStop),
                      ),
                      const SizedBox(height: 8),
                    ],
                    FilledButton.icon(
                      onPressed: selectedCount == 0
                          ? null
                          : () {
                              Navigator.of(context).pop(
                                _AudioGroupSetupResult.apply(
                                  <String, AudioChannelRole>{
                                    for (final candidate in candidates)
                                      if (selected[candidate.uid] == true)
                                        candidate.uid: roles[candidate.uid] ??
                                            AudioChannelRole.stereo,
                                  },
                                ),
                              );
                            },
                      icon: const Icon(Icons.spatial_audio_off_rounded),
                      label: Text(
                        applyingActiveConfig
                            ? l10n.audioGroupApply
                            : selectedCount > 1
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
            platformIcon(candidate.platform),
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
      style: TextStyle(
        color: palette.textMuted,
        fontSize: 12,
      ),
    );
  }

  String _audioGroupSyncEvidenceLabel(String peerId) {
    final sink = _audioGroupCoordinator.session?.sinks[peerId];
    if (sink == null) {
      return '';
    }
    final hasEvidence = sink.rttMicros > 0 ||
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

  Widget _buildDesktopPlaceholder(bool isDark) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    return Container(
      color: colorScheme.surface,
      alignment: Alignment.center,
      child: Text(
        AppLocalizations.of(context)?.selectConversationPlaceholder ??
            '选择一个设备开始对话',
        style: TextStyle(
          color: palette.textMuted,
          fontSize: 18,
        ),
      ),
    );
  }

  Widget _buildDesktopSessionTile(
    ChatSessionItem session, {
    required bool selected,
  }) {
    final deviceItem = session.device;
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final backgroundColor = selected
        ? (colorScheme.brightness == Brightness.dark
            ? palette.surfaceMuted
            : colorScheme.primary.withValues(alpha: 0.08))
        : Colors.transparent;

    return ContextMenuRegion(
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            setState(() {
              _selectedDesktopPeerId = deviceItem.uid;
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatSessionTime(session.lastTimestamp),
                            style: TextStyle(
                              fontSize: 12,
                              color: palette.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _sessionStatusColor(session),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              session.preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: palette.textMuted,
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
      ),
      items: _buildSessionContextActions(deviceItem),
    );
  }

  List<ContextMenuActionItem> _buildSessionContextActions(
      DeviceData deviceItem) {
    final l10n = AppLocalizations.of(context);
    final isConnected = socketManager.isConnectedTo(deviceItem.uid);
    return [
      if (isConnected)
        ContextMenuActionItem(
          label: l10n?.disconnect ?? '断开',
          onSelected: () async {
            await socketManager.disconnectPeer(deviceItem.uid);
          },
        ),
      if (!isConnected)
        ContextMenuActionItem(
          label: l10n?.connect ?? '连接',
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
          onSelected: () {
            _removeDevice(deviceItem.uid);
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
    return CircleAvatar(
      radius: 24,
      backgroundColor: background,
      child: Text(
        session.avatarLabel,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
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
    final targetDay =
        DateTime(messageTime.year, messageTime.month, messageTime.day);
    if (targetDay == today) {
      return DateFormat('HH:mm').format(messageTime);
    }
    if (messageTime.year == now.year) {
      return DateFormat('MM/dd').format(messageTime);
    }
    return DateFormat('yyyy/MM/dd').format(messageTime);
  }

  void _showManualConnectDialog() {
    showInputAlertDialog(
      context,
      title: AppLocalizations.of(context)?.connectDeviceTitle ?? "连接设备",
      description:
          AppLocalizations.of(context)?.connectDeviceDesc ?? '输入对方局域网地址与端口',
      inputHints: [
        {device?.host ?? "192.168.0.1": false},
        {"10002": true}
      ],
      confirmButtonText: AppLocalizations.of(context)?.connect ?? '连接',
      cancelButtonText: AppLocalizations.of(context)?.cancel ?? '取消',
      onConfirm: (List<String> inputValues) async {
        _connectServer(inputValues[0], int.parse(inputValues[1]));
      },
    );
  }

  void _openConv(DeviceData deviceItem) async {
    if (socketManager.isConnectedTo(deviceItem.uid)) {
      socketManager.selectPeer(deviceItem.uid);
    }
    if (isDesktop()) {
      setState(() {
        _selectedDesktopPeerId = deviceItem.uid;
      });
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SendMessageScreen(device: deviceItem),
      ),
    );
    _refreshDevice();
  }

  void _removeDevice(String uid) async {
    _connectionAttempts.cancel('peer:$uid');
    await socketManager.deletePeer(uid);
    if (!mounted) {
      return;
    }
    setState(() {
      if (_selectedDesktopPeerId == uid) {
        _selectedDesktopPeerId = null;
      }
    });
    _refreshDevice();
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
        if (socketManager.receiver != deviceItem.uid)
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
                        const Icon(
                          Icons.delete,
                          color: Colors.white,
                        ),
                        Text(
                            AppLocalizations.of(context)?.deleteConfirm ??
                                '确认删除 ',
                            style: TextStyle(
                                color: Colors.white, fontSize: ism ? 16 : 18)),
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
                if (socketManager.isConnectedTo(deviceItem.uid)) {
                  showLoadingDialog(
                    context,
                    title: AppLocalizations.of(context)?.warning ?? '警告',
                    description:
                        AppLocalizations.of(context)?.deleteWarningText ??
                            "连接正在使用，禁止快速删除",
                    isLoading: true,
                    // 是否显示加载指示器
                    icon: const Icon(
                      Icons.warning_rounded,
                      color: Colors.red,
                    ),
                    cancelButtonText:
                        AppLocalizations.of(context)?.close ?? '关闭',
                    onCancel: () {
                      // 处理取消操作
                      Navigator.of(context).pop(); // 关闭对话框
                    },
                    task: (VoidCallback onCancel) async {},
                  );
                  return;
                }
                _removeDevice(deviceItem.uid);
              }),
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
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _sessionStatusColor(session),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            session.preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.white54
                                  : Colors.black45,
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
      child: Icon(
        icon,
        color: Colors.white,
      ),
    );
  }

  void _connectServer(String host, int port, {String? peerId}) async {
    await _connectServerInternal(
      host,
      port,
      manual: true,
      peerId: peerId,
    );
  }

  Future<void> _connectServerInternal(
    String host,
    int port, {
    required bool manual,
    String? peerId,
  }) async {
    if (await isLocalhost(host)) {
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
            mode: ConnectionAttemptMode.interactive,
          ),
        );
      } on ArgumentError {
        result = ConnectionAttemptResult.networkFailure(
          requestId: '$targetKey:$attemptGeneration',
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
        if (isDesktop()) {
          setState(() {
            _selectedDesktopPeerId = connectedDevice.uid;
          });
        } else {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => SendMessageScreen(device: connectedDevice),
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
      final displayMessage =
          result.reason == ConnectionAttemptReason.protocolMismatch
              ? localizations?.pairingUpgradeRequired ?? 'Connection Failed'
              : result.reason == ConnectionAttemptReason.pairingExpired
                  ? localizations?.pairingExpired ?? 'Connection Failed'
                  : localizations?.connectFailed ?? 'Connection Failed';
      ConnectionCoordinator()
          .markDisconnected(peerId: peerId, error: displayMessage);
      if (_pendingAutoConnectPeerId == peerId) {
        _pendingAutoConnectPeerId = null;
      }
      if (manual && result.status != ConnectionAttemptStatus.cancelled) {
        showLoadingDialog(
          context,
          title: localizations?.connectFailed ?? '连接失败',
          description: displayMessage,
          isLoading: true,
          // 是否显示加载指示器
          icon: const Icon(
            Icons.warning_rounded,
            color: Colors.red,
          ),
          cancelButtonText: 'Cancel',
          onCancel: () {
            // 处理取消操作
            Navigator.of(context).pop(); // 关闭对话框
          },
          task: (VoidCallback onCancel) async {},
        );
      }
    } finally {
      _connectionAttempts.complete(targetKey, attemptGeneration);
    }
  }

  Future<void> _attemptAutoConnect() async {
    final candidate =
        await ConnectionCoordinator().chooseAutoConnectCandidate();
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
      return;
    }
    final error = result.error;
    privacyLog.event(
      PrivacyEvent.localOperation,
      <PrivacyField, Object>{
        PrivacyField.kind: DeviceListOperationKind.serverStart,
        PrivacyField.success: false,
        if (error != null) PrivacyField.errorType: privacyLog.errorType(error),
      },
    );
    final failureMessage =
        AppLocalizations.of(context)?.startServerFailed ?? '服务启动失败';
    showLoadingDialog(
      context,
      title: failureMessage,
      description: failureMessage,
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

  @override
  void onPairing(
    PairingRequest request,
    void Function(bool) resolve,
  ) {
    if (!mounted) {
      resolve(false);
      return;
    }
    unawaited(
      showPairingDialog(context, request: request, resolve: resolve),
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
    if (isDesktop()) {
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
      final confirmed = await confirmAction(
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
        showAppToast(l10n?.connectFailed ?? 'Connection Failed');
      }
    } finally {
      _isAlert = false;
    }
  }

  @override
  void onNotice(String message) {
    showAppToast(
      AppLocalizations.of(context)?.fileTransferFailedRetryable ??
          'Transfer failed',
    );
  }

  @override
  void onMessage(MessageData messageData) {
    _refreshDevice();
  }

  @override
  void onTransferUpdated(TransferSnapshot snapshot) {
    // Device list only needs to refresh high-level presence state for now.
  }

  @override
  void onTrayIconMouseDown() async {
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
    if (await LocalSetting().isClose2Tray() &&
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
    final text = await readClipboardTextForSync();
    if (text == null ||
        _clipboardText == text ||
        shouldIgnoreClipboardSync(text)) {
      return;
    }
    _clipboardText = text;
    socketManager.sendMessage(text, clipboard: true);
  }
}

class DeviceDetailsScreen extends StatelessWidget {
  final DeviceData device;

  const DeviceDetailsScreen({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(device.name.toString()),
        centerTitle: true,
      ),
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
  final isDark = Theme.of(context).brightness == Brightness.dark;

  showCupertinoDialog(
    context: context,
    builder: (BuildContext context) {
      return CupertinoAlertDialog(
        title: Text(title),
        content: Column(
          children: [
            const SizedBox(
              height: 14,
            ),
            Text(
              description,
              style: TextStyle(
                color: isDark ? Colors.grey[400] : Colors.black87,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            child: Text(
              cancelButtonText,
              style: const TextStyle(
                color: Colors.red,
              ),
            ),
            onPressed: () {
              if (onCancel != null) {
                onCancel();
              }
              Navigator.of(context).pop();
            },
          ),
          CupertinoDialogAction(
            child: Text(
              confirmButtonText,
              style: const TextStyle(
                color: Colors.lightBlue,
              ),
            ),
            onPressed: () {
              Navigator.of(context).pop();
              onConfirm();
            },
          ),
        ],
      );
    },
  );
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
  List<TextEditingController> controllers = [];
  List<Widget> inputFields = [];
  final isDark = Theme.of(context).brightness == Brightness.dark;

  for (int i = 0; i < inputHints.length; i++) {
    TextEditingController controller =
        TextEditingController(text: inputHints[i].keys.first);
    controllers.add(controller);

    inputFields.add(
      Column(
        children: [
          const SizedBox(height: 8),
          CupertinoTextField(
            controller: controller,
            placeholder: inputHints[i].keys.first,
            style: TextStyle(
              color: isDark ? Colors.white : Colors.black,
            ),
            decoration: BoxDecoration(
              color: isDark ? Colors.grey[800] : Colors.white,
              border: Border.all(
                color: isDark ? Colors.grey[700]! : Colors.grey[300]!,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            inputFormatters: inputHints[i].values.first
                ? <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                  ]
                : null,
          ),
        ],
      ),
    );
  }

  showCupertinoDialog(
    context: context,
    builder: (BuildContext context) {
      return CupertinoAlertDialog(
        title: Text(title),
        content: Column(
          children: [
            const SizedBox(height: 6),
            Text(
              description,
              style: TextStyle(
                color: isDark ? Colors.grey[400] : Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            ...inputFields,
          ],
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            child: Text(
              cancelButtonText,
              style: const TextStyle(
                color: Colors.red,
              ),
            ),
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
          CupertinoDialogAction(
            child: Text(
              confirmButtonText,
              style: const TextStyle(
                color: Colors.lightBlue,
              ),
            ),
            onPressed: () {
              List<String> inputValues =
                  controllers.map((controller) => controller.text).toList();
              onConfirm(inputValues);
              Navigator.of(context).pop();
            },
          ),
        ],
      );
    },
  );
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
  final isDark = Theme.of(context).brightness == Brightness.dark;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) {
      return CupertinoAlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              height: 12,
            ),
            if (isLoading) icon,
            const SizedBox(
              height: 8,
            ),
            Text(
              description,
              style: TextStyle(
                color: isDark ? Colors.grey[400] : Colors.black87,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          if (isLoading && showCancel)
            CupertinoDialogAction(
              onPressed: onCancel,
              child: Text(
                cancelButtonText,
                style: const TextStyle(
                  color: Colors.red,
                ),
              ),
            ),
        ],
      );
    },
  );
  await task(onCancel);
}
