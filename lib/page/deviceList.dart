import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/model/LocalDatabase.dart';

import '../helper/local.dart';
import '../socket/svrmanager.dart';
import 'conversation.dart';

class DeviceListScreen extends StatefulWidget {
  @override
  _DeviceListScreen createState() => _DeviceListScreen();
}

class _DeviceListScreen extends State<DeviceListScreen> {
  final db = LocalDatabase();
  final socketManager = WsSvrManager();
  DeviceData? device;
  List<DeviceData> devices = [];

  @override
  void initState() {
    _initializeData();
    _refreshDevice();
    super.initState();
  }

  Future<void> _initializeData() async {
    // 数据加载完成后更新状态
    var arr = await db.fetchAllDevice();
    setState(() {
      devices = arr;
    });
  }

  Future<void> _refreshDevice() async {
    // 数据加载完成后更新状态
    var temp = await LocalSetting().instance();
    setState(() {
      device = temp;
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
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    SizedBox(width: 4),
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
            child: Icon(
              Icons.send_rounded,
              size: 30,
              color: Colors.black45,
            ),
            onPressed: () async {
              socketManager.sendMessage("hello");
            },
          ),
          CupertinoButton(
            // 使用CupertinoButton
            padding: EdgeInsets.zero,
            child: Icon(
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
          final device = devices[index];
          return ListTile(
            title: Text(device.name.toString()),
            subtitle: Row(
              children: [
                Text(device.host.toString()),
                SizedBox(
                  width: 4,
                ),
                device.isServer as bool
                    ? Icon(Icons.desktop_mac,
                        size: 18,
                        color: device.online == true
                            ? Colors.lightBlue
                            : Colors.grey) // Server 图标
                    : Icon(Icons.phone_android,
                        size: 18,
                        color: device.online == true
                            ? Colors.lightBlue
                            : Colors.grey),
                // Client 图标
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: device.online == true
                      ? Icon(
                          Icons.wifi_rounded,
                          color: Colors.lightBlue,
                        )
                      : Icon(Icons.wifi_off_rounded), // 连接/断开 图标
                  onPressed: () {
                    // 处理连接/断开按钮点击事件
                    if (device.online == null) {
                      showConfirmationDialog(
                        context,
                        title: 'Confirmation',
                        description: 'Are you sure you want to proceed?',
                        confirmButtonText: 'Confirm',
                        cancelButtonText: 'Cancel',
                        onConfirm: () {
                          // 在确认后执行的逻辑

                          showLoadingDialog(
                            context,
                            title: 'Loading',
                            description: 'Please wait...',
                            isLoading: true,
                            // 是否显示加载指示器
                            icon: CupertinoActivityIndicator(),
                            cancelButtonText: 'Cancel',
                            onCancel: () {
                              // 处理取消操作
                              Navigator.of(context).pop(); // 关闭对话框
                              showLoadingDialog(
                                context,
                                title: 'Loading',
                                description: 'Please wait...',
                                isLoading: true,
                                // 是否显示加载指示器
                                showCancel: false,
                                icon: Icon(
                                  Icons.error_rounded,
                                  color: Colors.red,
                                ),
                                cancelButtonText: 'Cancel',
                                onCancel: () {
                                  // 处理取消操作
                                  Navigator.of(context).pop(); // 关闭对话框
                                },
                                task: (VoidCallback onCancel) async {
                                  // 执行需要进行的任务
                                  await Future.delayed(
                                      Duration(seconds: 1)); // 模拟加载过程
                                  onCancel(); // 任务完成后关闭对话框
                                  // 点击跳转到详情页面
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => SendMessageScreen(),
                                    ),
                                  );
                                },
                              );
                            },
                            task: (VoidCallback onCancel) async {
                              // 执行需要进行的任务
                              await Future.delayed(
                                  Duration(seconds: 1)); // 模拟加载过程
                              onCancel(); // 任务完成后关闭对话框
                            },
                          );
                        },
                      );
                    }
                  },
                ),
              ],
            ),
            onTap: () {
              showConfirmationDialog(
                context,
                title: 'Confirmation',
                description: 'Are you sure you want to proceed?',
                confirmButtonText: 'Confirm',
                cancelButtonText: 'Cancel',
                onConfirm: () {
                  // 在确认后执行的逻辑

                  showLoadingDialog(
                    context,
                    title: 'Loading',
                    description: 'Please wait...',
                    isLoading: true,
                    // 是否显示加载指示器
                    icon: CupertinoActivityIndicator(),
                    cancelButtonText: 'Cancel',
                    onCancel: () {
                      // 处理取消操作
                      Navigator.of(context).pop(); // 关闭对话框
                    },
                    task: (VoidCallback onCancel) async {
                      // 执行需要进行的任务
                      await Future.delayed(Duration(seconds: 1)); // 模拟加载过程
                      onCancel(); // 任务完成后关闭对话框
                      // 点击跳转到详情页面
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              DeviceDetailsScreen(device: device),
                        ),
                      );
                    },
                  );

                  // // 点击跳转到详情页面
                  // Navigator.push(
                  //   context,
                  //   MaterialPageRoute(
                  //     builder: (context) => DeviceDetailsScreen(device: device),
                  //   ),
                  // );
                },
              );
            },
          );
        },
      ),
      floatingActionButton: CupertinoButton(
        onPressed: () {
          // 处理悬浮按钮点击事件
          // 作为服务端
          if (device?.isServer == true) {
            if (socketManager.started) {
              socketManager.close();
              setState(() {
                socketManager.started = false;
              });
            }else {
              _startServer();
            }
            return;
          }
          // 作为客户端
          showInputAlertDialog(
            context,
            title: '连接主机',
            description: '输入对方局域网地址与端口',
            inputHints: [{"host": false}, {"port": true}],
            confirmButtonText: '连接',
            cancelButtonText: '取消',
            onConfirm: (List<String> inputValues) async {
              // 处理输入框的内容
              print('Entered values: $inputValues');
              // var host

              socketManager.connectToServer("${inputValues[0]}:${inputValues[1]}", (ok, message) {
                // _showToast(message);
                if (!ok) {
                  showLoadingDialog(
                    context,
                    title: '连接失败',
                    description: "$message",
                    isLoading: true,
                    // 是否显示加载指示器
                    icon: Icon(Icons.warning_rounded, color: Colors.red,),
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

              // await db.delete(db.device).go();

              // await db.into(db.device).insert(DeviceCompanion.insert(name: '123' + DateTime.now().millisecond.toString()));

              var arr = await db.fetchAllDevice();
              print("object");
              print(arr.length);
              print(arr);

              setState(() {
                devices = arr;
              });
            },
          );
        },
        child: Icon(device?.isServer==true?Icons.wifi_rounded:Icons.add, size: 32),
        color: device?.isServer==true && socketManager.started?Colors.lightBlue: Colors.grey,
        padding: EdgeInsets.all(16),
        borderRadius: BorderRadius.circular(50), // 调整圆角以获得更圆的按钮
      ),
    );
  }

  void _startServer() {
    socketManager.startServer(device?.port?? 10002, (ok, msg) {
      setState(() {
        socketManager.started = ok;
        if (!ok) {
          showLoadingDialog(
            context,
            title: '服务启动失败',
            description: "error: $msg",
            isLoading: true,
            // 是否显示加载指示器
            icon: Icon(Icons.warning_rounded, color: Colors.red,),
            cancelButtonText: 'Cancel',
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

  @override
  void initState() {
    _refreshDevice();
    super.initState();
  }

  Future<void> _refreshDevice() async {
    // 数据加载完成后更新状态
    var temp = await LocalSetting().instance();
    setState(() {
      device = temp;
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
          title: const Text('设置'),
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
                          '本机名称 ${device?.name??""}',
                          const Icon(
                            Icons.verified_user,
                            color: CupertinoColors.systemGrey,
                          ),
                          IconButton(
                              icon: const Icon(
                                Icons.send_rounded,
                                color: Colors.lightBlue,
                              ),
                              onPressed: () {
                                showInputAlertDialog(
                                  context,
                                  title: '昵称',
                                  description: '请输入昵称',
                                  inputHints: [{device?.name ?? "localhost": false}],
                                  confirmButtonText: '确定',
                                  cancelButtonText: '取消',
                                  onConfirm: (List<String> inputValues) async {
                                    // 处理输入框的内容
                                    if (inputValues[0].isNotEmpty) {
                                      LocalSetting().updateNickname(inputValues[0]);
                                      _refreshDevice();
                                    }
                                  },
                                );
                              }),
                        ),
                        _buildSettingItem(
                          '服务端口 ${device?.port}',
                          const Icon(
                            Icons.verified_user,
                            color: CupertinoColors.systemGrey,
                          ),
                          IconButton(
                              icon: const Icon(
                                Icons.send_rounded,
                                color: Colors.lightBlue,
                              ),
                              onPressed: () {
                                showInputAlertDialog(
                                  context,
                                  title: '服务端口',
                                  description: '请输入服务端口 [1000, 65535]',
                                  inputHints: [{'${device?.port ?? "10002"}': true}],
                                  confirmButtonText: '确定',
                                  cancelButtonText: '取消',
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
                              }),
                        ),
                        _buildSettingItem(
                          '作为服务端',
                          const Icon(
                            Icons.wifi_rounded,
                            color: CupertinoColors.systemGrey,
                          ),
                          CupertinoSwitch(
                            value: device?.isServer ?? false,
                            onChanged: (bool value) {
                              LocalSetting().updateServer(value);
                              WsSvrManager().close();
                              _refreshDevice();
                            },
                          ),
                        ),
                        _buildSettingItem(
                          '自动通过新设备',
                          const Icon(Icons.lock_open,
                              color: CupertinoColors.systemGrey),
                          CupertinoSwitch(
                            value: device?.auth ?? false,
                            onChanged: (bool value) {
                              LocalSetting().updateNoAuth(value);
                              _refreshDevice();
                            },
                          ),
                        ),
                        _buildSettingItem(
                          '允许访问剪切板',
                          const Icon(Icons.copy,
                              color: CupertinoColors.systemGrey),
                          CupertinoSwitch(
                            value: device?.clipboard ?? false,
                            onChanged: (bool value) {
                              LocalSetting().updateClipboard(value);
                              _refreshDevice();
                            },
                          ),
                        ),
                      ],
                    ))
              ],
            ),
          ),
        ));
  }

  Widget _buildSettingItem(String title, Icon icon, Widget trailing,
      {bool showDivider = true}) {
    return GestureDetector(
      onTap: () {
        // 处理点击设置项
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          children: [
            Container(
              height: 56.0, // 增加高度以适应 iOS 设置样式
              child: Row(
                children: [
                  icon, // 设置项的图标
                  SizedBox(width: 16.0), // 图标与文字之间的间距
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 17.0,
                        color: CupertinoColors.black,
                        fontWeight: FontWeight.w500, // 尝试更轻的字重
                        fontFamily:
                            'SF Pro Display', // 使用 iOS 默认字体（若有）), // 设置项的文字样式
                      ),
                      // style: TextStyle(fontSize: 17.0, color: CupertinoColors.black, fontWeight: FontWeight.bold), // 设置项的文字样式
                    ),
                  ),
                  trailing,
                ],
              ),
            ),
            if (showDivider) Divider(height: 1, color: Colors.white38), // 分割线
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
    TextEditingController controller = TextEditingController();
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
            SizedBox(height: 6),
            Text(description,
              style: TextStyle(
                color: Colors.grey, // 自定义取消按钮文本颜色
            ),),
            SizedBox(height: 8),
            ...inputFields,
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
            SizedBox(
              height: 12,
            ),
            if (isLoading) icon, // 显示加载指示器
            SizedBox(
              height: 8,
            ),
            Text(description),
          ],
        ),
        actions: <Widget>[
          if (isLoading && showCancel) // 如果正在加载，显示取消按钮
            CupertinoDialogAction(
              child: Text(
                cancelButtonText,
                style: TextStyle(
                  color: Colors.red, // 自定义取消按钮文本颜色
                ),
              ),
              onPressed: onCancel,
            ),
        ],
      );
    },
  );
  await task(onCancel); // 执行任务
}
