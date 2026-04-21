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
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:whisper/global.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/main.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/chat_session_list.dart';
import 'package:whisper/widget/context_menu_region.dart';
import 'package:window_manager/window_manager.dart';
import '../helper/ftp.dart';
import '../helper/local.dart';
import '../helper/notification.dart';
import '../l10n/app_localizations.dart';
import '../socket/svrmanager.dart';
import 'appList.dart';
import 'conversation.dart';
import 'settings.dart' as app_settings;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;

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
  final db = LocalDatabase();
  final socketManager = WsSvrManager();
  DeviceData? device;
  List<DeviceData> devices = [];
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  final serviceName = "whisper";
  final serviceType = "_whisper._tcp";
  bool discovering = false;
  var lastClickCloseTimestamp = 0;
  static var listenApps = {};
  var _clipboardText = "";
  final TextEditingController _desktopSearchController =
      TextEditingController();
  List<ChatSessionItem> _sessionItems = const [];
  String _desktopSearchQuery = "";
  String? _selectedDesktopPeerId;

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

  static void setListenApps() async {
    listenApps = await LocalSetting().listenAppNotifyList();
  }

  @pragma('vm:entry-point')
  static void _callback(NotificationEvent evt) {
    // send data to ui thread if necessary.
    // try to send the event to ui
    print("send evt to ui: $evt");
    var soc = WsSvrManager();
    if (soc.receiver.isNotEmpty &&
        filterNotification(evt) &&
        listenApps.containsKey(evt.packageName)) {
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
    _desktopSearchController.dispose();
    // stop watch
    clipboardWatcher.stop();
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
            for (var item in devices) {
              if (item.uid == uid) {
                break;
              }
            }
            var temp = await LocalDatabase().fetchDevice(uid);
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
                devices.insert(
                    0,
                    buildDevice(
                        uid: uid,
                        name: temp?.name ?? name,
                        port: port,
                        host: host,
                        platform: platform));
              }
            });
            _refreshDevice();
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
    var temp = await LocalSetting().instance();
    var arr = await db.fetchAllDevice();
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

    final latestMessages = await db
        .fetchLatestMessagesByPeers(newArr.map((item) => item.uid).toList());
    final sessions = ChatSessionListBuilder.build(
      devices: newArr,
      latestMessages: latestMessages,
      activePeerId:
          socketManager.receiver.isEmpty ? null : socketManager.receiver,
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

    logger.i("refresh ui: $discovering $serverPortUpdate");
    if (!discovering || serverPortUpdate) {
      discovering = true;
      Future.delayed(const Duration(milliseconds: 100), () {
        _broadcastService();
      });
      if (isFirst) {
        _discoverService();

        setListenApps();
      }
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
          color: socketManager.receiver.isNotEmpty
              ? Colors.redAccent
              : Colors.grey,
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
    return Scaffold(
      backgroundColor: isDark ? Colors.grey[950] : Colors.grey[100],
      body: SafeArea(
        child: Row(
          children: [
            Container(
              width: 340,
              decoration: BoxDecoration(
                color: isDark ? Colors.grey[900] : Colors.white,
                border: Border(
                  right: BorderSide(
                    color: isDark ? Colors.grey[800]! : Colors.grey[200]!,
                  ),
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: CupertinoSearchTextField(
                            controller: _desktopSearchController,
                            placeholder:
                                AppLocalizations.of(context)?.searchChats ??
                                    '搜索',
                            onChanged: (value) {
                              setState(() {
                                _desktopSearchQuery = value;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        _buildSidebarAction(
                          icon: Icons.add,
                          onPressed: _showManualConnectDialog,
                        ),
                        const SizedBox(width: 6),
                        _buildSidebarAction(
                          icon: Icons.settings_outlined,
                          onPressed: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const app_settings.SettingsScreen(),
                              ),
                            );
                            _refreshDevice();
                          },
                        ),
                      ],
                    ),
                  ),
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

  Widget _buildSidebarAction({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: 38,
      height: 38,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        color: isDark ? Colors.grey[850] : Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
        onPressed: onPressed,
        child: Icon(
          icon,
          size: 20,
          color: isDark ? Colors.white70 : Colors.black54,
        ),
      ),
    );
  }

  Widget _buildDesktopPlaceholder(bool isDark) {
    return Container(
      color: isDark ? Colors.black : Colors.white,
      alignment: Alignment.center,
      child: Text(
        AppLocalizations.of(context)?.selectConversationPlaceholder ??
            '选择一个设备开始对话',
        style: TextStyle(
          color: isDark ? Colors.white54 : Colors.black45,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = selected
        ? (isDark ? Colors.grey[800] : Colors.blue.withOpacity(0.08))
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
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatSessionTime(session.lastTimestamp),
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white38 : Colors.black38,
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
                                color: isDark ? Colors.white54 : Colors.black45,
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
    return [
      if (deviceItem.uid == socketManager.receiver)
        ContextMenuActionItem(
          label: l10n?.disconnect ?? '断开',
          onSelected: () {
            socketManager.close();
          },
        ),
      if (socketManager.receiver.isEmpty)
        ContextMenuActionItem(
          label: l10n?.connect ?? '连接',
          onSelected: () {
            _connectServer(deviceItem.host, deviceItem.port);
          },
        ),
      if (deviceItem.uid != socketManager.receiver)
        ContextMenuActionItem(
          label: l10n?.delete ?? '删除',
          onSelected: () {
            _removeDevice(deviceItem.uid);
          },
        ),
      ContextMenuActionItem(
        label: 'FTP',
        onSelected: () {
          SimpleFtpServer().openClient("${deviceItem.host}:$defaultFtpPort");
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
    if (socketManager.receiver.isNotEmpty) {
      socketManager.close();
      return;
    }
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
    await LocalDatabase().clearDevices([uid]);
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
          _connectServer(deviceItem.host, deviceItem.port);
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

  void _connectServer(String host, int port) async {
    if (await isLocalhost(host)) {
      afterAuth(true, device);
      return;
    }
    socketManager.connectToServer(host, port, (ok, message) {
      // _showToast(message);
      if (!ok) {
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
    _refreshDevice();
  }

  @override
  void onConnect() {
    _refreshDevice();
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
    _refreshDevice();
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
    logger.i("resized window: ${rect.width} ${rect.height}");
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
