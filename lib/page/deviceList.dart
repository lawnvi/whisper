import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:bonsoir/bonsoir.dart';
import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_notification_listener_plus/flutter_notification_listener_plus.dart';
import 'package:flutter_swipe_action_cell/core/cell.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:whisper/global.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/auto_connect_planner.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/connection_models.dart';
import 'package:whisper/state/device_workspace_state.dart';
import 'package:whisper/state/notification_app_registry.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_dialogs.dart';
import 'package:whisper/widget/context_menu_region.dart';
import 'package:whisper/widget/device_workspace.dart';
import 'package:window_manager/window_manager.dart';
import '../helper/ftp.dart';
import '../helper/local.dart';
import '../helper/notification.dart';
import '../l10n/app_localizations.dart';
import '../socket/svrmanager.dart';
import 'conversation.dart';
import 'settings.dart';
import 'dart:io' show Platform;

class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key});

  @override
  _DeviceListScreen createState() => _DeviceListScreen();
}

class _DeviceListScreen extends State<DeviceListScreen>
    implements ISocketEvent, TrayListener, WindowListener, ClipboardListener {
  final db = LocalDatabase();
  final socketManager = WsSvrManager();
  final connectionCoordinator = ConnectionCoordinator();
  DeviceData? device;
  List<DeviceData> devices = [];
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  final serviceName = "whisper";
  final serviceType = "_whisper._tcp";
  bool discovering = false;
  var lastClickCloseTimestamp = 0;
  var _clipboardText = "";
  String? _pendingOpenPeerId;
  String? _selectedPeerId;

  @override
  void initState() {
    // if (!kIsWeb &&
    //     (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
    //   initSystemTray();
    // }
    _setDesktopWindow();
    _requestPermission();
    clipboardWatcher.addListener(this);
    // start watch
    clipboardWatcher.start();
    NotificationAppRegistry.instance.refresh();
    connectionCoordinator.addListener(_handleConnectionStateChanged);
    super.initState();
  }

  @override
  void didChangeDependencies() async {
    _refreshDevice(isFirst: true);
    socketManager.registerEvent(this, uid: device?.uid ?? "");
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
    } else {
      if (await Permission.location.isDenied) {
        await Permission.location.request();
      }
    }

    var permissions = [Permission.storage];

    for (var item in permissions) {
      logger.i("permission status: ${await item.status}");
      if (await item.isDenied) {
        logger.i("permission request: ${await item.isRestricted}");
        await item.request();
      }
    }

    _clipboardText = await getClipboardText() ?? "";
  }

  @pragma('vm:entry-point')
  static void _callback(NotificationEvent evt) {
    // send data to ui thread if necessary.
    // try to send the event to ui
    print("send evt to ui: $evt");
    var soc = WsSvrManager();
    if (soc.receiver.isNotEmpty &&
        filterNotification(evt) &&
        NotificationAppRegistry.instance.containsPackage(evt.packageName)) {
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
      logger.i(
          "mobile clear file picker cache res: ${await FilePicker.platform.clearTemporaryFiles()}");
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
              if (socketManager.receiver.isEmpty) {
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
              await windowManager.destroy();
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
  //     debugPrint("eventName: $eventName");
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
    logger.i("dispose page");
    _stopDiscovery();
    _stopBroadcast();
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    clipboardWatcher.removeListener(this);
    // stop watch
    clipboardWatcher.stop();
    connectionCoordinator.removeListener(_handleConnectionStateChanged);
    super.dispose();
  }

  void _broadcastService({port}) async {
    final wifiIP = await getLocalIpAddress();

    logger.i("wifi ip: $wifiIP");

    if (wifiIP == "127.0.0.1") {
      discovering = false;
      return;
    }

    await _stopBroadcast(close: false);
    final trustedPeerIds = await db.fetchTrustedPeerIds();
    final autoConnectEnabled = await LocalSetting().autoConnectEnabled();
    BonsoirService service = BonsoirService(
      name: serviceName,
      type: serviceType,
      port: 10004,
      attributes: {
        'host': wifiIP,
        'port': (port ?? device?.port ?? 10002).toString(),
        'name': await deviceName(),
        'platform': device?.platform ?? "未知",
        'uid': device?.uid ?? "",
        'trustedPeers': trustedPeerIds.join(','),
        'autoConnect': autoConnectEnabled ? '1' : '0',
      },
    );

    // And now we can broadcast it :
    _broadcast = BonsoirBroadcast(service: service);
    await _broadcast!.ready;

    _broadcast!.eventStream!.listen((event) {
      debugPrint('Broadcast event : ${event.type}');
    });

    await _broadcast!.start();
    discovering = true;
  }

  Future<void> _stopBroadcast({close = true}) async {
    await _broadcast?.stop();
    discovering = !close;
  }

  Future<void> _discoverService() async {
    // This is the type of service we're looking for :

    // Once defined, we can start the discovery :
    _discovery = BonsoirDiscovery(type: serviceType, printLogs: true);
    await _discovery!.ready;

    // If you want to listen to the discovery :
    _discovery?.eventStream!.listen((event) async {
      debugPrint('Discovery event : ${event.type}');
      // `eventStream` is not null as the discovery instance is "ready" !
      final service = event.service;
      if (service != null) {
        switch (event.type) {
          case BonsoirDiscoveryEventType.discoveryServiceFound:
            logger.i(
                "event type: ${event.type}, service name: $serviceName ${service.name}");
            if (service.name.startsWith(serviceName)) {
              event.service!.resolve(_discovery!.serviceResolver);
            }
            break;
          case BonsoirDiscoveryEventType.discoveryStarted:
            logger.i(
                "event type: ${event.type}, service name: ${service.name} start");
            break;
          case BonsoirDiscoveryEventType.discoveryServiceResolved ||
                BonsoirDiscoveryEventType.discoveryServiceLost:
            final svr = service;
            if (!svr.attributes.containsKey('uid')) {
              logger.i(
                  "event type: ${event.type}, service name: ${service.name} not contains uid skip. ${svr.toString()}");
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
            logger.i("${isLost ? '丢失' : '发现'}本地设备");
            logger.i("本地设备uid: $uid");
            logger.i("本地设备name: $name");
            logger.i("本地设备host: $host");
            logger.i("本地设备port: $port");
            logger.i("本地设备platform: $platform");
            if (uid == null || uid == device?.uid) {
              return;
            }
            var temp = await LocalDatabase().fetchDevice(uid);
            final discoveredDevice = buildDevice(
              uid: uid,
              name: temp?.name ?? name,
              port: port,
              host: host,
              platform: platform,
              around: !isLost,
            ).copyWith(
              auth: temp?.auth ?? false,
              clipboard: temp?.clipboard ?? false,
              lastTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            );
            await connectionCoordinator.updateDiscovery(
              discoveredDevice,
              discovered: !isLost,
              remoteTrustedPeerIds:
                  PeerProfile.trustedPeersFromDiscovery(svr.attributes),
              remoteAutoConnectEnabled:
                  PeerProfile.autoConnectFromDiscovery(svr.attributes),
            );
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
                devices.insert(0, discoveredDevice);
              }
            });
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
  }

  Future<void> _stopDiscovery() async {
    await _discovery?.stop();
    discovering = false;
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

  Future<void> _refreshDevice({isFirst = false}) async {
    // 数据加载完成后更新状态
    var temp = await LocalSetting().instance();
    var arr = await db.fetchAllDevice();
    await connectionCoordinator.bootstrap(temp.uid);
    await connectionCoordinator.syncKnownDevices(arr);
    var newArr = <DeviceData>[];
    var aroundIds = <String>{};
    for (var item in devices) {
      if (aroundIds.contains(item.uid)) {
        continue;
      }
      if (item.uid == socketManager.receiver) {
        newArr.insert(0, item);
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

    if (isFirst || device?.port != temp.port) {
      _startServer(port: temp.port);
    }

    setState(() {
      device = temp;
      devices = newArr;
      _selectedPeerId ??= socketManager.receiver.isNotEmpty
          ? socketManager.receiver
          : newArr.isNotEmpty
              ? newArr.first.uid
              : null;
    });

    logger.i("refresh ui: $discovering $serverPortUpdate");
    if (!discovering || serverPortUpdate) {
      discovering = true;
      Future.delayed(const Duration(milliseconds: 100), () {
        logger.i("refresh ui 你是来拉屎的吧");
        _broadcastService();
      });
      if (isFirst) {
        logger.i("refresh ui 你也是来拉屎的吗");
        _discoverService();
        NotificationAppRegistry.instance.refresh();
      }
    }
    await _attemptAutoConnect();
  }

  void _handleConnectionStateChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _attemptAutoConnect() async {
    if (device == null || socketManager.receiver.isNotEmpty) {
      return;
    }
    final candidate = await connectionCoordinator.chooseAutoConnectCandidate();
    if (candidate == null) {
      return;
    }
    DeviceData? target;
    for (final item in devices) {
      if (item.uid == candidate.peerId) {
        target = item;
        break;
      }
    }
    if (target == null) {
      return;
    }
    await _connectServer(
      target.host,
      target.port,
      deviceData: target,
      manual: false,
      openConversation: false,
      reconnecting: connectionCoordinator.snapshot.state ==
          ConnectionLifecycleState.disconnected,
    );
  }

  @override
  Widget build(BuildContext context) {
    var isDesk = isDesktop();
    final colorScheme = Theme.of(context).colorScheme;
    final workspaceState = DeviceWorkspaceStateBuilder.build(
      devices: devices,
      presences: {
        for (final presence in connectionCoordinator.peers)
          presence.peerId: presence,
      },
      selectedPeerId: _selectedPeerId,
      activePeerId: socketManager.receiver,
      connectedTitle: AppLocalizations.of(context)?.connect ?? 'Connected',
      trustedTitle: AppLocalizations.of(context)?.trust ?? 'Trusted',
    );
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () {
            // 处理悬浮按钮点击事件
            // 作为服务端
            if (socketManager.receiver.isNotEmpty) {
              socketManager.close();
              return;
            }
            // 作为客户端
            showInputAlertDialog(
              context,
              title: AppLocalizations.of(context)?.connectDeviceTitle ?? "连接设备",
              description: AppLocalizations.of(context)?.connectDeviceDesc ??
                  '输入对方局域网地址与端口',
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
          },
          color: socketManager.receiver.isNotEmpty
              ? context.whisperPalette.danger
              : colorScheme.onSurfaceVariant,
          icon: Icon(
              socketManager.receiver.isNotEmpty
                  ? Icons.power_settings_new
                  : Icons.add,
              size: 32), // 调整圆角以获得更圆的按钮
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
          CupertinoButton(
            // 使用CupertinoButton
            padding: EdgeInsets.zero,
            child: Icon(
              Icons.settings_outlined,
              size: 30,
              color: colorScheme.onSurfaceVariant,
            ),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SettingsScreen(),
                ),
              );
              _refreshDevice();
            },
          ),
        ],
      ),
      body: isDesk
          ? Row(
              children: [
                SizedBox(
                  width: 380,
                  child: _buildDeviceRail(workspaceState),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _buildDesktopWorkspace(workspaceState),
                ),
              ],
            )
          : _buildMobileWorkspace(workspaceState),
    );
  }

  Widget _buildDeviceRail(DeviceWorkspaceState workspaceState) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 18),
        children: [
          WorkspaceOverviewCard(
            connectedCount: workspaceState.connectedCount,
            trustedCount: workspaceState.trustedCount,
            totalPeers: devices.length,
          ),
          const SizedBox(height: 12),
          for (final section in workspaceState.sections)
            DeviceSectionCard(
              section: section,
              compact: false,
              onSelectDevice: _selectDevice,
              onOpenChat: _openConv,
              onToggleConnection: _toggleConnection,
              onOpenSettings: _openClientSettings,
            ),
        ],
      ),
    );
  }

  Widget _buildMobileWorkspace(DeviceWorkspaceState workspaceState) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 24),
      children: [
        WorkspaceOverviewCard(
          connectedCount: workspaceState.connectedCount,
          trustedCount: workspaceState.trustedCount,
          totalPeers: devices.length,
        ),
        const SizedBox(height: 12),
        for (final section in workspaceState.sections)
          DeviceSectionCard(
            section: section,
            compact: true,
            onSelectDevice: _selectDevice,
            onOpenChat: _openConv,
            onToggleConnection: _toggleConnection,
            onOpenSettings: _openClientSettings,
          ),
      ],
    );
  }

  Widget _buildDesktopWorkspace(DeviceWorkspaceState workspaceState) {
    final selectedDevice = workspaceState.selectedDevice;
    final presence = selectedDevice == null
        ? null
        : connectionCoordinator.peer(selectedDevice.uid);
    final isConnected = selectedDevice != null &&
        connectionCoordinator.isConnectedTo(selectedDevice.uid);
    final localTrust = selectedDevice != null &&
        (presence?.locallyTrusted ?? selectedDevice.auth);
    final remoteTrust = presence?.remotelyTrusted ?? false;
    return DeviceWorkspaceDetail(
      selectedDevice: selectedDevice,
      isConnected: isConnected,
      isNearby: presence?.discovered == true,
      localTrust: localTrust,
      remoteTrust: remoteTrust,
      onOpenChat: () {
        if (selectedDevice != null) {
          _openConv(selectedDevice);
        }
      },
      onToggleConnection: () {
        if (selectedDevice != null) {
          _toggleConnection(selectedDevice);
        }
      },
      onOpenSettings: () {
        if (selectedDevice != null) {
          _openClientSettings(selectedDevice);
        }
      },
    );
  }

  void _selectDevice(DeviceData deviceItem) {
    setState(() {
      _selectedPeerId = deviceItem.uid;
    });
    if (!isDesktop()) {
      _openConv(deviceItem);
    }
  }

  void _toggleConnection(DeviceData deviceItem) {
    if (deviceItem.uid == socketManager.receiver) {
      socketManager.close();
      return;
    }
    _connectServer(
      deviceItem.host,
      deviceItem.port,
      deviceData: deviceItem,
    );
  }

  Future<void> _openClientSettings(DeviceData deviceItem) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ClientSettingsScreen(device: deviceItem),
      ),
    );
    _refreshDevice();
  }

  Widget _buildDeviceItem(int index) {
    final deviceItem = devices[index];

    return ContextMenuRegion(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0.0, 0),
          child: ListTile(
            leading: Icon(platformIcon(deviceItem.platform),
                size: 28,
                color: deviceItem.uid == socketManager.receiver ||
                        deviceItem.around == true
                    ? Colors.lightBlue
                    : Colors.grey),
            // Server 图标,
            title: Text(deviceItem.name),
            subtitle: Row(
              children: [
                Text(deviceItem.host),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (deviceItem.uid == socketManager.receiver ||
                    socketManager.receiver.isEmpty)
                  IconButton(
                    icon: deviceItem.uid == socketManager.receiver
                        ? const Icon(Icons.wifi_rounded,
                            color: Colors.lightBlue)
                        : const Icon(Icons.wifi_off_rounded), // 连接/断开 图标
                    onPressed: () {
                      // 处理连接/断开按钮点击事件
                      _handleDeviceConnect(deviceItem);
                    },
                  ),
              ],
            ),
            onTap: () {
              _openConv(deviceItem);
            },
          ),
        ),
        items: [
          if (deviceItem.uid == socketManager.receiver)
            ContextMenuActionItem(
              label: "断开",
              onSelected: () {
                socketManager.close();
              },
            ),
          if (socketManager.receiver.isEmpty)
            ContextMenuActionItem(
              label: "连接",
              onSelected: () {
                _connectServer(
                  deviceItem.host,
                  deviceItem.port,
                  deviceData: deviceItem,
                );
              },
            ),
          if (deviceItem.uid != socketManager.receiver)
            ContextMenuActionItem(
              label: "删除",
              onSelected: () {
                LocalDatabase().clearDevices([deviceItem.uid]);
                devices.removeAt(index);
                setState(() {});
              },
            ),
          if (isDesktop())
            ContextMenuActionItem(
              label: "连接FTP",
              onSelected: () {
                SimpleFtpServer()
                    .openClient("${deviceItem.host}:$defaultFtpPort");
              },
            ),
        ]);
  }

  void _openConv(deviceItem) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SendMessageScreen(device: deviceItem),
      ),
    );
    _refreshDevice();
  }

  void _handleDeviceConnect(deviceItem) {
    showConfirmationDialog(
      context,
      title: deviceItem.uid == socketManager.receiver
          ? AppLocalizations.of(context)?.brokeConnectTitle ?? "断开连接"
          : AppLocalizations.of(context)?.connectDeviceTitle ?? "连接设备",
      description:
          '${deviceItem.uid == socketManager.receiver ? AppLocalizations.of(context)?.disconnect ?? "断开" : AppLocalizations.of(context)?.connectTo ?? "连接到"} ${deviceItem.name}',
      confirmButtonText: AppLocalizations.of(context)?.confirm ?? '确定',
      cancelButtonText: AppLocalizations.of(context)?.cancel ?? '取消',
      onConfirm: () {
        if (deviceItem.uid == socketManager.receiver) {
          socketManager.close();
        } else {
          _connectServer(
            deviceItem.host,
            deviceItem.port,
            deviceData: deviceItem,
          );
        }
      },
    );
  }

  @Deprecated("use context menu, just for mobile")
  Widget _buildDeviceItemOld(int index) {
    final deviceItem = devices[index];
    bool ism = isMobile();
    return SwipeActionCell(
      key: ValueKey(devices[index]),
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
                if (socketManager.receiver == deviceItem.uid) {
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
                LocalDatabase().clearDevices([deviceItem.uid]);
                devices.removeAt(index);
                setState(() {});
              }),
      ],
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 0, 0.0, 0),
        child: ListTile(
          leading: Icon(platformIcon(deviceItem.platform),
              size: 28,
              color: deviceItem.uid == socketManager.receiver ||
                      deviceItem.around == true
                  ? Colors.lightBlue
                  : Colors.grey),
          // Server 图标,
          title: Text(deviceItem.name),
          subtitle: Row(
            children: [
              Text(deviceItem.host),
              // const SizedBox(width: 4,),
              // Client 图标
              // if (deviceItem.around == true) SizedBox(width: 6,),
              // if (deviceItem.around == true) Icon(Icons.online_prediction_rounded, color: Colors.lightBlue,size: 18,)
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (deviceItem.uid == socketManager.receiver ||
                  socketManager.receiver.isEmpty)
                IconButton(
                  icon: deviceItem.uid == socketManager.receiver
                      ? const Icon(Icons.wifi_rounded, color: Colors.lightBlue)
                      : const Icon(Icons.wifi_off_rounded), // 连接/断开 图标
                  onPressed: () {
                    // 处理连接/断开按钮点击事件
                    showConfirmationDialog(
                      context,
                      title: deviceItem.uid == socketManager.receiver
                          ? AppLocalizations.of(context)?.brokeConnectTitle ??
                              "断开连接"
                          : AppLocalizations.of(context)?.connectDeviceTitle ??
                              "连接设备",
                      description:
                          '${deviceItem.uid == socketManager.receiver ? AppLocalizations.of(context)?.disconnect ?? "断开" : AppLocalizations.of(context)?.connectTo ?? "连接到"} ${deviceItem.name}',
                      confirmButtonText:
                          AppLocalizations.of(context)?.confirm ?? '确定',
                      cancelButtonText:
                          AppLocalizations.of(context)?.cancel ?? '取消',
                      onConfirm: () {
                        if (deviceItem.uid == socketManager.receiver) {
                          socketManager.close();
                        } else {
                          _connectServer(
                            deviceItem.host,
                            deviceItem.port,
                            deviceData: deviceItem,
                          );
                        }
                      },
                    );
                  },
                ),
            ],
          ),
          onTap: () {
            _openConv(deviceItem);
          },
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

  Future<void> _connectServer(
    String host,
    int port, {
    DeviceData? deviceData,
    bool manual = true,
    bool openConversation = true,
    bool reconnecting = false,
  }) async {
    final targetPeerId = deviceData?.uid;
    if (manual && targetPeerId != null) {
      await connectionCoordinator.markManualSelection(targetPeerId);
    }
    _pendingOpenPeerId = openConversation ? targetPeerId : null;
    if (targetPeerId != null) {
      connectionCoordinator.markConnecting(
        targetPeerId,
        reconnecting: reconnecting,
      );
    }
    if (await isLocalhost(host)) {
      afterAuth(true, deviceData ?? device);
      return;
    }
    socketManager.connectToServer(host, port, (ok, message) {
      // _showToast(message);
      if (!ok) {
        connectionCoordinator.markDisconnected(error: message.toString());
        showLoadingDialog(
          context,
          title: AppLocalizations.of(context)?.connectFailed ?? '连接失败',
          description: "$message",
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
        return;
      }
    });
  }

  void _startServer({port}) {
    socketManager.startServer(port ?? device?.port ?? 10002, (ok, msg) {
      setState(() {
        socketManager.started = ok;
        if (!ok) {
          showLoadingDialog(
            context,
            title: AppLocalizations.of(context)?.startServerFailed ?? '服务启动失败',
            description: "error: $msg",
            isLoading: true,
            // 是否显示加载指示器
            icon: const Icon(
              Icons.warning_rounded,
              color: Colors.red,
            ),
            cancelButtonText: AppLocalizations.of(context)?.cancel ?? 'Cancel',
            onCancel: () {
              // 处理取消操作
              Navigator.of(context).pop(); // 关闭对话框
            },
            task: (VoidCallback onCancel) async {},
          );
        }
      });
    });
  }

  @override
  void onAuth(DeviceData? deviceData, bool asServer, String msg, var callback) {
    if (msg.isNotEmpty) {
      showLoadingDialog(
        context,
        title: AppLocalizations.of(context)?.connectFailed ?? '连接失败',
        description: "${deviceData?.name} $msg",
        isLoading: true,
        // 是否显示加载指示器
        icon: const Icon(
          Icons.warning_rounded,
          color: Colors.red,
        ),
        cancelButtonText: AppLocalizations.of(context)?.confirm ?? '确定',
        onCancel: () {
          // 处理取消操作
          callback(false);
          Navigator.of(context).pop(); // 关闭对话框
        },
        task: (VoidCallback onCancel) async {},
      );
      return;
    }
    if (asServer) {
      showConfirmationDialog(context,
          title: AppLocalizations.of(context)?.connectRequest ?? '连接请求',
          description: AppLocalizations.of(context)
                  ?.connectRequestDesc(deviceData?.name ?? "") ??
              '接入设备: ${deviceData?.name}?',
          confirmButtonText: AppLocalizations.of(context)?.allow ?? '同意',
          cancelButtonText: AppLocalizations.of(context)?.refuse ?? '拒绝',
          onConfirm: () {
        callback(true);
      }, onCancel: () {
        logger.i("拒绝连接");
        callback(false);
      });
    } else {
      callback(true);
    }
  }

  @override
  void afterAuth(bool allow, DeviceData? deviceData) async {
    if (!allow || deviceData == null) {
      return;
    }
    await db.upsertDevice(deviceData);
    connectionCoordinator.markConnected(deviceData);
    // 在确认后执行的逻辑
    if (_pendingOpenPeerId == deviceData.uid) {
      _pendingOpenPeerId = null;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => SendMessageScreen(
            device: deviceData,
          ),
        ),
      );
    }
    _refreshDevice();
  }

  @override
  void onClose() {
    // TODO: implement onClose
    connectionCoordinator.markDisconnected();
    _refreshDevice();
  }

  @override
  void onConnect() {
    // TODO: implement onConnect
  }

  var _isAlert = false;

  @override
  void onError(String message) {
    connectionCoordinator.markDisconnected(error: message);
    if (_isAlert) {
      return;
    }
    _isAlert = true;
    showConfirmationDialog(context,
        title: AppLocalizations.of(context)?.timeoutTitle ?? "是否释放连接",
        description: message,
        confirmButtonText: AppLocalizations.of(context)?.disconnect ?? "断开",
        cancelButtonText: AppLocalizations.of(context)?.keepConnect ?? "取消",
        onConfirm: () {
      WsSvrManager().close();
      _isAlert = false;
    }, onCancel: () {
      _isAlert = false;
    });
  }

  @override
  void onMessage(MessageData messageData) {
    // TODO: implement onMessage
  }

  @override
  void onProgress(int size, length) {
    // TODO: implement onProgress
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
    var timestamp = DateTime.now().millisecondsSinceEpoch;
    if (await LocalSetting().isClose2Tray() &&
        await windowManager.isPreventClose()) {
      if (Platform.isMacOS &&
          (timestamp - lastClickCloseTimestamp > 1000) &&
          await windowManager.isFocused()) {
        await windowManager.blur();
      } else {
        await windowManager.hide();
      }
    } else {
      await windowManager.destroy();
    }
    lastClickCloseTimestamp = timestamp;
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
    final rect = await windowManager.getBounds();
    await Future.wait([
      LocalSetting().setWindowWidth(rect.width),
      LocalSetting().setWindowHeight(rect.height),
    ]);
  }

  @override
  void onWindowResized() async {
    if (await windowManager.isMaximized() ||
        await windowManager.isMinimized()) {
      return;
    }
    final rect = await windowManager.getBounds();
    logger.i("resized window: ${rect.width} ${rect.height}");
    await Future.wait([
      LocalSetting().setWindowWidth(rect.width),
      LocalSetting().setWindowHeight(rect.height),
    ]);
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
    var text = await getClipboardText() ?? "";
    if (_clipboardText == text) {
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
