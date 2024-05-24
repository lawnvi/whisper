import 'dart:io';
import 'package:bonsoir/bonsoir.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_swipe_action_cell/core/cell.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/main.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:window_manager/window_manager.dart';
import '../helper/local.dart';
import '../socket/svrmanager.dart';
import 'conversation.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

class DeviceListScreen extends StatefulWidget {
  @override
  _DeviceListScreen createState() => _DeviceListScreen();
}

class _DeviceListScreen extends State<DeviceListScreen> implements ISocketEvent, TrayListener, WindowListener {
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

  @override
  void initState() {
    // if (!kIsWeb &&
    //     (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
    //   initSystemTray();
    // }
    _setDesktopWindow();
    _requestPermission();
    super.initState();
  }

  @override
  void didChangeDependencies() async {
    _refreshDevice(isFirst: true);
    socketManager.registerEvent(this, uid: device?.uid??"");
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
    }else {
      if (await Permission.location.isDenied) {
        await Permission.location.request();
      }
    }

    var permissions = [Permission.storage];

    for (var item in permissions) {
      logger.i("permission status: ${await item.status}");
      if(await item.isDenied) {
        logger.i("permission request: ${await item.isRestricted}");
        await item.request();
      }
    }
  }

  Future<void> _setDesktopWindow() async {
    if (isMobile()) {
      logger.i("mobile clear file picker cache res: ${await FilePicker.platform.clearTemporaryFiles()}");
      return;
    }
    await windowManager.setPreventClose(true);
    await trayManager.setIcon(
      Platform.isWindows
          ? 'assets/app_icon.ico'
          : 'assets/app_icon_round.png',
    );

    Menu menu = Menu(
      items: [
        MenuItem(
            key: 'show_window',
            label: AppLocalizations.of(context)?.menuShow??"显示",
            onClick: (MenuItem item) {
              windowManager.show();
            }),
        MenuItem(
            key: 'hide_window',
            label: AppLocalizations.of(context)?.menuHide??"隐藏",
            onClick: (MenuItem item) {
              windowManager.hide();
            }),
        MenuItem(
            key: 'clipboard',
            label: AppLocalizations.of(context)?.menuClipboard??"发送剪切板",
            onClick: (MenuItem item) {
              socketManager.sendMessage("", clipboard: true);
            }),
        MenuItem(
            key: 'pick_file',
            label: AppLocalizations.of(context)?.menuSendFile??"发送文件",
            onClick: (MenuItem item) async {
              if (socketManager.receiver.isEmpty) {
                return;
              }
              FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);
              if (result != null) {
                for (var item in result.files) {
                  await socketManager.sendFile(item.path??"");
                }
              }
            }),
        MenuItem.separator(),
        MenuItem(
            key: 'exit_app',
            label: AppLocalizations.of(context)?.exit??'退出',
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
        'port': (port??device?.port??10002).toString(),
        'name': await deviceName(),
        'platform': device?.platform?? "未知",
        'uid': device?.uid?? "",
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

  Future<void> _stopBroadcast({close=true}) async {
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
        switch(event.type) {
          case BonsoirDiscoveryEventType.discoveryServiceFound:
            logger.i("event type: ${event.type}, service name: $serviceName ${service.name}");
            if (service.name.startsWith(serviceName)) {
              event.service!.resolve(_discovery!.serviceResolver);
            }
            break;
          case BonsoirDiscoveryEventType.discoveryStarted:
            logger.i("event type: ${event.type}, service name: ${service.name} start");
            break;
          case BonsoirDiscoveryEventType.discoveryServiceResolved || BonsoirDiscoveryEventType.discoveryServiceLost:
            final svr = service;
            if (!svr.attributes.containsKey('uid')) {
              logger.i("event type: ${event.type}, service name: ${service.name} not contains uid skip. ${svr.toString()}");
              return;
            }
            var isLost = event.type == BonsoirDiscoveryEventType.discoveryServiceLost;
            final host = svr.attributes["host"];
            final port = int.tryParse(svr.attributes["port"]??"10002")?? 10002;
            final uid = svr.attributes["uid"];
            final name = svr.attributes["name"];
            final platform = svr.attributes["platform"];
            logger.i("${isLost?'丢失': '发现'}本地设备");
            logger.i("本地设备uid: $uid");
            logger.i("本地设备name: $name");
            logger.i("本地设备host: $host");
            logger.i("本地设备port: $port");
            logger.i("本地设备platform: $platform");
            if (uid == null || uid == device?.uid) {
              return;
            }
            var index = -1;
            for (var item in devices) {
              if (item.uid == uid) {
                index = devices.indexOf(item);
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
              }else if (!isLost) {
                devices.insert(0, buildDevice(
                    uid: uid, name: temp?.name??name, port: port, host: host, platform: platform
                ));
              }
            });
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

  DeviceData buildDevice({uid="", name="", host="", port=10002, platform="", around=true}) {
    return DeviceData(id: 0,
      uid: uid,
      name: name,
      host: host,
      port: port,
      platform: platform,
      isServer: false,
      lastTime: DateTime.now().millisecondsSinceEpoch~/1000,
      online: false,
      password: "",
      clipboard: false,
      auth: false,
      around: around
    );
  }

  Future<void> _refreshDevice({isFirst=false}) async {
    // 数据加载完成后更新状态
    var temp = await LocalSetting().instance();
    var arr = await db.fetchAllDevice();
    var newArr = <DeviceData>[];
    var aroundIds = <String>{};
    for(var item in devices) {
      if (aroundIds.contains(item.uid)) {
        continue;
      }
      if(item.uid == socketManager.receiver) {
        newArr.insert(0, item);
        aroundIds.add(item.uid);
        continue;
      }
      if (item.around == true) {
        newArr.add(item);
        aroundIds.add(item.uid);
      }
    }

    for(var item in arr) {
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
    });

    logger.i("refresh ui: $discovering $serverPortUpdate");
    if (!discovering || serverPortUpdate) {
      discovering = true;
      Future.delayed(const Duration(milliseconds: 100), (){
        logger.i("refresh ui 你是来拉屎的吧");
        _broadcastService();
      });
      if (isFirst) {
        logger.i("refresh ui 你也是来拉屎的吗");
        _discoverService();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
              title: AppLocalizations.of(context)?.connectDeviceTitle??"连接设备",
              description: AppLocalizations.of(context)?.connectDeviceDesc??'输入对方局域网地址与端口',
              inputHints: [{device?.host??"192.168.0.1": false}, {"10002": true}],
              confirmButtonText: AppLocalizations.of(context)?.connect??'连接',
              cancelButtonText: AppLocalizations.of(context)?.cancel??'取消',
              onConfirm: (List<String> inputValues) async {
                _connectServer(inputValues[0], int.parse(inputValues[1]));
              },
            );
          },
          color: socketManager.receiver.isNotEmpty? Colors.redAccent: Colors.grey,
          icon: Icon(socketManager.receiver.isNotEmpty? Icons.power_settings_new: Icons.add, size: 32), // 调整圆角以获得更圆的按钮
        ),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(device?.name?? "localhost"), // 替换为实际昵称
                Row(
                  children: [
                    Text(
                      "${device?.host??"127.0.0.1"}:${device?.port??10002}", // 替换为实际 IP 地址
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.wifi_rounded,
                        size: socketManager.started ? 14 : 0, color: Colors.lightBlue)
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
            child: const Icon(
              Icons.settings_outlined,
              size: 30,
              color: Colors.black45,
            ),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SettingsScreen(),
                ),
              );
              _refreshDevice();
            },
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: devices.length,
        itemBuilder: (context, index) {
          return _buildDeviceItem(index);
        },
      ),
    );
  }

  Widget _buildDeviceItem(int index) {
    final deviceItem = devices[index];
    bool ism = isMobile();
    return SwipeActionCell(
      key: ValueKey(devices[index]),
      trailingActions: [
        if (socketManager.receiver != deviceItem.uid) SwipeAction(
          widthSpace: ism? 120: 140 ,
            nestedAction: SwipeNestedAction(
              /// 自定义你nestedAction 的内容
              content: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: Colors.red,
                ),
                width: ism? 100: 120,
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
                      Text('确认删除 ', style: TextStyle(color: Colors.white, fontSize: ism? 16: 18)),
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
                  title: AppLocalizations.of(context)?.warning?? '警告',
                  description: AppLocalizations.of(context)?.deleteWarningText?? "连接正在使用，禁止快速删除",
                  isLoading: true,
                  // 是否显示加载指示器
                  icon: const Icon(Icons.warning_rounded, color: Colors.red,),
                  cancelButtonText: AppLocalizations.of(context)?.close??'关闭',
                  onCancel: () {
                    // 处理取消操作
                    Navigator.of(context).pop(); // 关闭对话框
                  },
                  task: (VoidCallback onCancel) async {

                  },
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
                color: deviceItem.uid == socketManager.receiver || deviceItem.around == true
                    ? Colors.lightBlue
                    : Colors.grey), // Server 图标,
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
                if (deviceItem.uid == socketManager.receiver || socketManager.receiver.isEmpty) IconButton(
                  icon: deviceItem.uid == socketManager.receiver
                      ? const Icon(Icons.wifi_rounded, color: Colors.lightBlue)
                      : const Icon(Icons.wifi_off_rounded), // 连接/断开 图标
                  onPressed: () {
                    // 处理连接/断开按钮点击事件
                    showConfirmationDialog(
                      context,
                      title: deviceItem.uid == socketManager.receiver? AppLocalizations.of(context)?.brokeConnectTitle??"断开连接": AppLocalizations.of(context)?.connectDeviceTitle??"连接设备",
                      description: '${deviceItem.uid == socketManager.receiver? AppLocalizations.of(context)?.disconnect??"断开": AppLocalizations.of(context)?.connectTo??"连接到"} ${deviceItem.name}',
                      confirmButtonText: AppLocalizations.of(context)?.confirm??'确定',
                      cancelButtonText: AppLocalizations.of(context)?.cancel??'取消',
                      onConfirm: () {
                        if (deviceItem.uid == socketManager.receiver) {
                          socketManager.close();
                        }else {
                          _connectServer(deviceItem.host, deviceItem.port);
                        }
                      },
                    );
                  },
                ),
              ],
            ),
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SendMessageScreen(device: deviceItem),
                ),
              );
              _refreshDevice();
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
          title: AppLocalizations.of(context)?.connectFailed??'连接失败',
          description: "$message",
          isLoading: true,
          // 是否显示加载指示器
          icon: const Icon(Icons.warning_rounded, color: Colors.red,),
          cancelButtonText: 'Cancel',
          onCancel: () {
            // 处理取消操作
            Navigator.of(context).pop(); // 关闭对话框
          },
          task: (VoidCallback onCancel) async {

          },
        );
        return;
      }
    });
  }

  void _startServer({port}) {
    socketManager.startServer(port??device?.port?? 10002, (ok, msg) {
      setState(() {
        socketManager.started = ok;
        if (!ok) {
          showLoadingDialog(
            context,
            title: AppLocalizations.of(context)?.startServerFailed??'服务启动失败',
            description: "error: $msg",
            isLoading: true,
            // 是否显示加载指示器
            icon: const Icon(Icons.warning_rounded, color: Colors.red,),
            cancelButtonText: AppLocalizations.of(context)?.cancel??'Cancel',
            onCancel: () {
              // 处理取消操作
              Navigator.of(context).pop(); // 关闭对话框
            },
            task: (VoidCallback onCancel) async {

            },
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
        title: AppLocalizations.of(context)?.connectFailed??'连接失败',
        description: "${deviceData?.name} $msg",
        isLoading: true,
        // 是否显示加载指示器
        icon: const Icon(Icons.warning_rounded, color: Colors.red,),
        cancelButtonText: AppLocalizations.of(context)?.confirm??'确定',
        onCancel: () {
          // 处理取消操作
          callback(false);
          Navigator.of(context).pop(); // 关闭对话框
        },
        task: (VoidCallback onCancel) async {

        },
      );
      return;
    }
    if (asServer) {
      showConfirmationDialog(
        context,
        title: AppLocalizations.of(context)?.connectRequest??'连接请求',
        description: AppLocalizations.of(context)?.connectRequestDesc(deviceData?.name??"")??'接入设备: ${deviceData?.name}?',
        confirmButtonText: AppLocalizations.of(context)?.allow??'同意',
        cancelButtonText: AppLocalizations.of(context)?.refuse??'拒绝',
        onConfirm: () {
          callback(true);
        },
        onCancel: () {
          logger.i("拒绝连接");
          callback(false);
        }
      );
    }else {
      callback(true);
    }
  }

  @override
  void afterAuth(bool allow, DeviceData? deviceData) async {
    if (!allow || deviceData == null) {
      return;
    }
    db.upsertDevice(deviceData);
    // 在确认后执行的逻辑
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SendMessageScreen(device: deviceData,),
      ),
    );
    _refreshDevice();
  }

  @override
  void onClose() {
    // TODO: implement onClose
    _refreshDevice();
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
    showConfirmationDialog(context, title: AppLocalizations.of(context)?.timeoutTitle??"是否释放连接", description: message, confirmButtonText: AppLocalizations.of(context)?.disconnect??"断开", cancelButtonText: AppLocalizations.of(context)?.keepConnect??"取消", onConfirm: (){
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
    if (await LocalSetting().isClose2Tray() && await windowManager.isPreventClose()) {
      if (Platform.isMacOS && (timestamp - lastClickCloseTimestamp > 1000) && await windowManager.isFocused()) {
        await windowManager.blur();
      }else {
        await windowManager.hide();
      }
    }else {
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
    if (!Platform.isLinux || await windowManager.isMaximized() || await windowManager.isMinimized()) {
    return;
    }
    var rect = await windowManager.getBounds();
    LocalSetting().setWindowWidth(rect.width);
    LocalSetting().setWindowHeight(rect.height);
  }

  @override
  void onWindowResized() async {
    if (await windowManager.isMaximized() || await windowManager.isMinimized()) {
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
}

class DeviceDetailsScreen extends StatelessWidget {
  final DeviceData device;

  DeviceDetailsScreen({required this.device});

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
            device.isServer as bool
                ? Icon(Icons.desktop_mac) // Server 图标
                : Icon(Icons.phone_android), // Client 图标
            // 其他设备详情信息...
          ],
        ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  @override
  _SettingsScreen createState() => _SettingsScreen();
}

class _SettingsScreen extends State<SettingsScreen> {
  DeviceData? device;
  String _path = "";
  PackageInfo? _packageInfo;
  bool _doubleClickDelete = false;
  bool _close2tray = true;

  @override
  void initState() {
    _refreshDevice();
    super.initState();
  }

  Future<void> _refreshDevice() async {
    // 数据加载完成后更新状态
    var temp = await LocalSetting().instance();
    var p = await downloadDir();
    var pkg = await PackageInfo.fromPlatform();
    var doubleClick = await LocalSetting().isDoubleClickDelete();
    var closeToTray = await LocalSetting().isClose2Tray();
    setState(() {
      device = temp;
      _path = p.path;
      _packageInfo = pkg;
      _close2tray = closeToTray;
      _doubleClickDelete = doubleClick;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          leading: CupertinoNavigationBarBackButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            color: Colors.lightBlue, // 设置返回按钮图标的颜色
          ),
          title: Text(AppLocalizations.of(context)?.setting?? "设置"),
        ),
        body: SafeArea(
          child: Material(
            child: ListView(
              padding: const EdgeInsets.all(16.0), // 添加内边距以改善外观
              children: [
                Card(
                    elevation: 2.0, // 设置卡片的阴影
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12.0), // 圆角边框
                    ),
                    child: Column(
                      children: [
                        _buildSettingItem(
                          device?.name??"",
                          Icon(
                            platformIcon(device?.platform?? ""),
                            color: CupertinoColors.systemGrey,
                          ),
                          onTap: () {
                            showInputAlertDialog(
                              context,
                              title: AppLocalizations.of(context)?.nickname??'昵称',
                              description: AppLocalizations.of(context)?.nicknameDesc??'请输入昵称',
                              inputHints: [{device?.name ?? "localhost": false}],
                              confirmButtonText: AppLocalizations.of(context)?.confirm??'确定',
                              cancelButtonText: AppLocalizations.of(context)?.cancel??'取消',
                              onConfirm: (List<String> inputValues) async {
                                // 处理输入框的内容
                                if (inputValues[0].isEmpty) {
                                  inputValues[0] = await deviceName();
                                }
                                LocalSetting().updateNickname(inputValues[0]);
                                _refreshDevice();
                              },
                            );
                          }
                        ),
                        _buildSettingItem(
                          AppLocalizations.of(context)?.serverPort(device?.port??10002)?? '服务端口 ${device?.port}',
                          const Icon(
                            Icons.wifi_tethering,
                            color: CupertinoColors.systemGrey,
                          ),
                          onTap: () {
                            showInputAlertDialog(
                              context,
                              title: AppLocalizations.of(context)?.serverPortTitle??'服务端口',
                              description: AppLocalizations.of(context)?.portDesc??'请输入服务端口 [1000, 65535]',
                              inputHints: [{'${device?.port ?? "10002"}': true}],
                              confirmButtonText: AppLocalizations.of(context)?.confirm??'确定',
                              cancelButtonText: AppLocalizations.of(context)?.cancel??'取消',
                              onConfirm: (List<String> inputValues) async {
                                // 处理输入框的内容
                                try {
                                  var port = int.parse(inputValues[0]);
                                  if (port > 1000 && port <= 65535) {
                                    LocalSetting().updatePort(port);
                                    _refreshDevice();
                                  }
                                }on Exception catch (_, e) {

                                }
                              },
                            );
                          }
                        ),
                        // _buildSettingItem(
                        //   '作为服务端',
                        //   const Icon(
                        //     Icons.wifi_rounded,
                        //     color: CupertinoColors.systemGrey,
                        //   ),
                        //   trailing: CupertinoSwitch(
                        //     value: device?.isServer ?? false,
                        //     onChanged: (bool value) {
                        //       LocalSetting().updateServer(value);
                        //       WsSvrManager().close(closeServer: true);
                        //       _refreshDevice();
                        //     },
                        //   ),
                        // ),
                        _buildSettingItem(
                          AppLocalizations.of(context)?.trustNewDevice??'自动通过新设备',
                          const Icon(Icons.lock_open, color: CupertinoColors.systemGrey),
                          trailing: CupertinoSwitch(
                            value: device?.auth ?? false,
                            onChanged: (bool value) {
                              LocalSetting().updateNoAuth(value);
                              _refreshDevice();
                            },
                          ),
                        ),
                        _buildSettingItem(
                          AppLocalizations.of(context)?.accessClipboard??'允许访问剪切板',
                          const Icon(Icons.copy,  color: CupertinoColors.systemGrey),
                          trailing: CupertinoSwitch(
                            value: device?.clipboard ?? false,
                            onChanged: (bool value) {
                              LocalSetting().updateClipboard(value);
                              _refreshDevice();
                            },
                          ),
                        ),
                        _buildSettingItem(
                          AppLocalizations.of(context)?.doubleClickRmMessage??'双击消息删除',
                          const Icon(Icons.delete_outline_rounded, color: CupertinoColors.systemGrey),
                          trailing: CupertinoSwitch(
                              value: _doubleClickDelete,
                              onChanged: (bool value) {
                              LocalSetting().updateDoubleClickDelete(value);
                              setState(() {
                                _doubleClickDelete = value;
                              });
                            },
                          ),
                        ),
                        if (!isMobile()) _buildSettingItem(
                          AppLocalizations.of(context)?.close2tray??'关闭时隐藏到托盘',
                          const Icon(Icons.close_rounded, color: CupertinoColors.systemGrey),
                          trailing: CupertinoSwitch(
                            value: _close2tray,
                            onChanged: (bool value) async {
                              LocalSetting().updateClose2Tray(value);
                              setState(() {
                                _close2tray = value;
                              });
                            },
                          ),
                        ),
                        _buildSettingItem(
                            (AppLocalizations.of(context)?.language(Localizations.localeOf(context).languageCode)??'language ${Localizations.localeOf(context).languageCode}'),
                            const Icon(Icons.language_rounded, color: CupertinoColors.systemGrey),
                            onTap: () {
                              var local = Localizations.localeOf(context);
                              var languageCode = "zh";
                              if (local.languageCode == "zh") {
                                languageCode = "en";
                              }
                              MyApp.setLocale(context, Locale(languageCode));
                              LocalSetting().setLocalization(languageCode);
                            }
                        ),
                        _buildSettingItem(
                          _path,
                          const Icon(Icons.file_download_outlined, color: CupertinoColors.systemGrey),
                          onTap: () {
                            openDir();
                          }
                        ),
                        _buildSettingItem(
                            _packageInfo?.version?? "UNKNOWN",
                            const Icon(Icons.copyright, color: CupertinoColors.systemGrey),
                            onTap: () async {
                              final Uri toLaunch = Uri(scheme: 'https', host: '2.127014.xyz', path: '/whisper.html');
                              _launchInBrowser(toLaunch);
                            }
                        ),
                      ],
                    ))
              ],
            ),
          ),
        ));
  }

  Future<void> _launchInBrowser(Uri url) async {
    if (!await launchUrl(
      url,
      mode: LaunchMode.externalApplication,
    )) {
      throw Exception('Could not launch $url');
    }
  }

  Widget _buildSettingItem(String title, Icon icon,
      {Widget? trailing , bool showDivider = true, GestureTapCallback? onTap, String desc = ""}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          children: [
            Container(
              constraints: const BoxConstraints(minHeight: 56),
              // height: 56.0, // 增加高度以适应 iOS 设置样式
              child: Row(
                children: [
                  icon, // 设置项的图标
                  const SizedBox(width: 8.0), // 图标与文字之间的间距
                  Expanded(
                    child: Text(
                      title,
                      softWrap: true,
                      // overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17.0,
                        color: CupertinoColors.black,
                        fontWeight: FontWeight.w500, // 尝试更轻的字重
                        fontFamily:
                            'SF Pro Display', // 使用 iOS 默认字体（若有）), // 设置项的文字样式
                      ),
                      // style: TextStyle(fontSize: 17.0, color: CupertinoColors.black, fontWeight: FontWeight.bold), // 设置项的文字样式
                    ),
                  ),
                  if (trailing != null) trailing,
                ],
              ),
            ),
            if (desc.isNotEmpty) Text(desc,
              softWrap: true,
              // overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.0,
                color: CupertinoColors.black,
                fontWeight: FontWeight.w500, // 尝试更轻的字重
                fontFamily:
                'SF Pro Display', // 使用 iOS 默认字体（若有）), // 设置项的文字样式
              ),),
            if (showDivider) const Divider(height: 1, color: Colors.white38), // 分割线
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
  showCupertinoDialog(
    context: context,
    builder: (BuildContext context) {
      return CupertinoAlertDialog(
        title: Text(title),
        content: Column(
          children: [
            SizedBox(
              height: 14,
            ),
            Text(description),
          ],
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            child: Text(
              cancelButtonText,
              style: TextStyle(
                color: Colors.red, // 自定义取消按钮文本颜色
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
              style: TextStyle(
                color: Colors.lightBlue, // 自定义取消按钮文本颜色
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

  for (int i = 0; i < inputHints.length; i++) {
    TextEditingController controller = TextEditingController(text: inputHints[i].keys.first);
    controllers.add(controller);

    inputFields.add(
      Column(
        children: [
          SizedBox(height: 8), // 间隔
          CupertinoTextField(
            controller: controller,
            placeholder: inputHints[i].keys.first,
            inputFormatters: inputHints[i].values.first?<TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ]:null,
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
            Text(description,
              style: const TextStyle(
                color: Colors.grey, // 自定义取消按钮文本颜色
            ),),
            const SizedBox(height: 8),
            ...inputFields,
          ],
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            child: Text(
              cancelButtonText,
              style: const TextStyle(
                color: Colors.red, // 自定义取消按钮文本颜色
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
                color: Colors.lightBlue, // 自定义取消按钮文本颜色
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
  showDialog(
    context: context,
    barrierDismissible: false, // 不能通过点击外部来关闭对话框
    builder: (BuildContext context) {
      return CupertinoAlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              height: 12,
            ),
            if (isLoading) icon, // 显示加载指示器
            const SizedBox(
              height: 8,
            ),
            Text(description),
          ],
        ),
        actions: <Widget>[
          if (isLoading && showCancel) // 如果正在加载，显示取消按钮
            CupertinoDialogAction(
              onPressed: onCancel,
              child: Text(
                cancelButtonText,
                style: const TextStyle(
                  color: Colors.red, // 自定义取消按钮文本颜色
                ),
              ),
            ),
        ],
      );
    },
  );
  await task(onCancel); // 执行任务
}
