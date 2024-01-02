import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:whisper/model/LocalDatabase.dart';

import 'conversation.dart';

class DeviceListScreen extends StatefulWidget {
  @override
  _DeviceListScreen createState() => _DeviceListScreen();
}

class _DeviceListScreen extends State<DeviceListScreen> {
  final bool isServer = true;
  final db = LocalDatabase();
  List<DeviceData> devices = [];

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
                Text('Username'), // 替换为实际昵称
                Row(
                  children: [
                    Text(
                      '192.168.1.2', // 替换为实际 IP 地址
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    SizedBox(width: 2),
                    Icon(Icons.wifi_rounded,
                        size: isServer ? 14 : 0, color: Colors.lightBlue)
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
              color: Colors.black45,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SettingsScreen(),
                ),
              );
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
                    if (device.online == true) {
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
          showInputAlertDialog(
            context,
            title: 'Input',
            description: 'Please enter the following information:',
            inputHints: ['Username', 'Email'],
            confirmButtonText: 'Confirm',
            cancelButtonText: 'Cancel',
            onConfirm: (List<String> inputValues) async {
              // 处理输入框的内容
              print('Entered values: $inputValues');

              // await db.delete(db.device).go();

              await db.into(db.device).insert(DeviceCompanion.insert(name: '123' + DateTime.now().millisecond.toString()));

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
        child: Icon(Icons.add, size: 32),
        color: Colors.lightBlue,
        padding: EdgeInsets.all(16),
        borderRadius: BorderRadius.circular(50), // 调整圆角以获得更圆的按钮
      ),
    );
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

class SettingsScreen extends StatelessWidget {
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
          title: Text('Settings'),
        ),
        body: SafeArea(
          child: Material(
            child: ListView(
              padding: EdgeInsets.all(16.0), // 添加内边距以改善外观
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
                          '开启监听',
                          Icon(
                            Icons.wifi_rounded,
                            color: CupertinoColors.systemGrey,
                          ),
                          CupertinoSwitch(
                            value: true,
                            onChanged: (bool value) {},
                          ),
                        ),
                        _buildSettingItem(
                          '加密传输',
                          Icon(
                            Icons.lock,
                            color: CupertinoColors.systemGrey,
                          ),
                          CupertinoSwitch(
                            value: true,
                            onChanged: (bool value) {},
                          ),
                        ),
                        _buildSettingItem(
                          '自动通过新设备',
                          Icon(Icons.lock_open,
                              color: CupertinoColors.systemGrey),
                          CupertinoSwitch(
                            value: true,
                            onChanged: (bool value) {},
                          ),
                        ),
                        _buildSettingItem(
                          '允许读取剪切板',
                          Icon(Icons.copy, color: CupertinoColors.systemGrey),
                          CupertinoSwitch(
                            value: true,
                            onChanged: (bool value) {},
                          ),
                        ),
                        _buildSettingItem(
                            '允许写入剪切板',
                            Icon(
                              Icons.create_rounded,
                              color: CupertinoColors.systemGrey,
                            ),
                            CupertinoSwitch(
                              value: true,
                              onChanged: (bool value) {},
                            ),
                            showDivider: false),
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
  required List<String> inputHints,
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
            placeholder: inputHints[i],
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
            Text(description),
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
