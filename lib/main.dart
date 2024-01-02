import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
// import 'package:hive/hive.dart';
import 'package:system_tray/system_tray.dart';
import 'package:whisper/page/deviceList.dart';
import 'package:whisper/page/newMain.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:whisper/socket/svrmanager.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomeScreen(),
      builder: EasyLoading.init(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class SocketEvent extends ISocketEvent {
  @override
  void onClose() {
    // TODO: implement onClose
  }

  @override
  void onConnect() {
    // TODO: implement onConnect
  }

  @override
  void onError() {
    // TODO: implement onError
  }

  @override
  void onMessage(String message) {
    print(message);
  }
}

class _HomeScreenState extends State<HomeScreen> {
  bool isRotating = false; // 控制光团旋转的开关状态
  // final socketServer = SocketServerManager();
  // final socketClient = SocketClientManager();
  final socketManager = WsSvrManager();
  String _localhost = "";
  String _host = "192.168.4.87";
  String _pass = "";
  String _msg = "hhh";

  final TextEditingController _hostController =
      TextEditingController(text: "192.168.4.87");

  late PermissionStatus _status;

  @override
  void initState() {
    super.initState();
    _requestPermission();
    // ..registerAdapter(PersonAdapter());
    if (!kIsWeb &&
        (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
      initSystemTray();
    }



    var event = SocketEvent();

    socketManager.setEvent(event);
  }

  Future<void> initSystemTray() async {
    String path =
        Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png';

    final AppWindow appWindow = AppWindow();
    final SystemTray systemTray = SystemTray();

    // We first init the systray menu
    await systemTray.initSystemTray(
      title: "whisper",
      iconPath: "",
    );

    // create context menu
    final Menu menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: 'Show', onClicked: (menuItem) => appWindow.show()),
      MenuItemLabel(label: 'Hide', onClicked: (menuItem) => appWindow.hide()),
      MenuItemLabel(label: 'Exit', onClicked: (menuItem) => appWindow.close()),
    ]);

    // set context menu
    await systemTray.setContextMenu(menu);

    // handle system tray event
    systemTray.registerSystemTrayEventHandler((eventName) {
      debugPrint("eventName: $eventName");
      if (eventName == kSystemTrayEventClick) {
        Platform.isWindows ? appWindow.show() : systemTray.popUpContextMenu();
      } else if (eventName == kSystemTrayEventRightClick) {
        Platform.isWindows ? systemTray.popUpContextMenu() : appWindow.show();
      }
    });
  }

  Future<void> _requestPermission() async {
    if (Platform.isAndroid) {
      PermissionStatus status = await Permission.storage.request();
      setState(() {
        _status = status;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Socket通讯'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            // 在 onPressed 回调中添加以下代码：
            onPressed: () {
              showDialog(
                context: context,
                builder: (BuildContext context) {
                  return AlertDialog(
                    title: Text('输入设备信息'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          controller: _hostController,
                          decoration: InputDecoration(labelText: '设备IP地址'),
                          onChanged: (value) {
                            // TODO: 存储输入的IP地址
                            _host = value;
                          },
                        ),
                        TextField(
                          decoration: InputDecoration(labelText: '访问密码'),
                          onChanged: (value) {
                            // TODO: 存储输入的密码
                            _pass = value;
                          },
                          obscureText: true,
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                        },
                        child: Text('取消'),
                      ),
                      TextButton(
                        onPressed: () {
                          // TODO: 处理用户输入的IP地址和密码，建立socket连接
                          socketManager.connectToServer(_host, (message) {
                            // _showToast(message);
                            setState(() {
                              _msg = message;
                            });
                          });

                          Navigator.pop(context);
                        },
                        child: Text('确定'),
                      ),
                    ],
                  );
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => DeviceListScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.developer_mode),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => NewUI()),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_localhost),
            Text(_msg),
            Text(_host),
            GestureDetector(
              onTap: () {
                setState(() {
                  isRotating = !isRotating; // 切换光团旋转状态
                });
              },
              child: AnimatedContainer(
                duration: Duration(milliseconds: 100),
                width: 200,
                height: 200,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.lightBlue,
                ),
                child: isRotating
                    ? RotationTransition(
                        turns: const AlwaysStoppedAnimation(0.5),
                        child: Container(
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [Colors.green, Colors.lightBlue],
                            ),
                          ),
                        ),
                      )
                    : Container(),
              ),
            ),
            const SizedBox(height: 20),
            Switch(
              value: isRotating,
              onChanged: (value) async {
                // String localhost = await getLocalIpAddress();
                setState(() {
                  isRotating = value;
                  // _localhost = localhost;
                });
                if (value) {
                  socketManager.startServer(4567);
                  _showToast('开始监听');
                } else {
                  socketManager.close();
                  _showToast('停止监听');
                }
              },
            ),
            ElevatedButton(
              onPressed: () {
                // print("server is running: ${socketServer.isRunning}\n");
                socketManager.sendMessage(
                    'server Test message from button! ${DateTime.now().microsecond}'); // 按钮点击时发送消息
              },
              child: Text('server'),
            ),
            ElevatedButton(
              onPressed: () {
                print("client is running\n");
                socketManager.sendMessage(
                    'client Test message from button! ${DateTime.now().microsecond}'); // 按钮点击时发送消息
              },
              child: Text('client'),
            ),
            ElevatedButton(
              onPressed: () async {
                String copy = await _getClipboardData() ?? "NO COPY";
                print("copy: $copy\n");
                socketManager.sendMessage('COPY: $copy'); // 按钮点击时发送消息
              },
              child: const Text('client copy'),
            ),
            ElevatedButton(
              onPressed: () async {
                // socketClient.sendFile("/sdcard/test.zip"); // 按钮点击时发送消息
                pickFile();
              },
              child: const Text('pick file'),
            ),
          ],
        ),
      ),
    );
  }
}

// 添加一个辅助方法来显示 Toast
void _showToast(String message) {
  EasyLoading.showToast(message);
}

Future<String?> _getClipboardData() async {
  return await Clipboard.getData(Clipboard.kTextPlain).then((value) {
    if (value != null && value.text != null) {
      return value.text;
    } else {
      return null;
    }
  }).catchError((error) {
    print('Error getting clipboard data: $error');
    return null;
  });
}

void _copyToClipboard(String content) {
  Clipboard.setData(ClipboardData(text: content))
      .then((value) => print('Text copied to clipboard: $content'))
      .catchError((error) => print('Error copying to clipboard: $error'));
}

void pickFile() async {
  // 打开文件选择器
  FilePickerResult? result = await FilePicker.platform.pickFiles();

  if (result != null) {
    PlatformFile file = result.files.first;
    print('选择的文件路径: ${file.path}');
    print('选择的文件名: ${file.name}');
    print('选择的文件大小: ${file.size}');
  } else {
    // 用户取消了文件选择
    print('用户取消了文件选择');
  }
}