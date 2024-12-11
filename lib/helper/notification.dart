// 导入包
import 'dart:io';

import 'package:device_apps/device_apps.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_notification_listener/flutter_notification_listener.dart';

class NotificationHelper {
  // 使用单例模式进行初始化
  static final NotificationHelper _instance = NotificationHelper._internal();

  factory NotificationHelper() => _instance;

  NotificationHelper._internal();

  // FlutterLocalNotificationsPlugin是一个用于处理本地通知的插件，它提供了在Flutter应用程序中发送和接收本地通知的功能。
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // 初始化函数
  Future<void> initialize() async {
    // AndroidInitializationSettings是一个用于设置Android上的本地通知初始化的类
    // 使用了app_icon作为参数，这意味着在Android上，应用程序的图标将被用作本地通知的图标。
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    // 15.1是DarwinInitializationSettings，旧版本好像是IOSInitializationSettings（有些例子中就是这个）
    const DarwinInitializationSettings initializationSettingsIOS =
        DarwinInitializationSettings();
    // 初始化
    const InitializationSettings initializationSettings =
        InitializationSettings(
            android: initializationSettingsAndroid,
            iOS: initializationSettingsIOS,
            macOS: initializationSettingsIOS,
            linux: LinuxInitializationSettings(
              defaultActionName: 'open notification',
            ));
    await _notificationsPlugin.initialize(initializationSettings);
  }

//  显示通知
  Future<void> showNotification(
      {required String title, required String body}) async {
    // 安卓的通知
    // 'your channel id'：用于指定通知通道的ID。
    // 'your channel name'：用于指定通知通道的名称。
    // 'your channel description'：用于指定通知通道的描述。
    // Importance.max：用于指定通知的重要性，设置为最高级别。
    // Priority.high：用于指定通知的优先级，设置为高优先级。
    // 'ticker'：用于指定通知的提示文本，即通知出现在通知中心的文本内容。
    const AndroidNotificationDetails androidNotificationDetails =
        AndroidNotificationDetails('whisper.channel.id', 'whisper channel',
            channelDescription: 'whisper dispatcher channel',
            importance: Importance.max,
            priority: Priority.high,
            ticker: 'ticker');

    // ios的通知
    const String darwinNotificationCategoryPlain = 'plainCategory';
    const DarwinNotificationDetails iosNotificationDetails =
        DarwinNotificationDetails(
            categoryIdentifier: darwinNotificationCategoryPlain);

    // 创建跨平台通知
    const NotificationDetails platformChannelSpecifics = NotificationDetails(
        android: androidNotificationDetails,
        iOS: iosNotificationDetails,
        macOS: iosNotificationDetails);

    // 发起一个通知
    await _notificationsPlugin.show(
      1,
      title,
      body,
      platformChannelSpecifics,
    );
  }
}

void startAndroidListening() async {
  var hasPermission = (await NotificationsListener.hasPermission) ?? false;
  if (!hasPermission) {
    NotificationsListener.openPermissionSettings();
    return;
  }
  var isRunning = (await NotificationsListener.isRunning) ?? false;

  if (!isRunning) {
    await NotificationsListener.startService(
        foreground: false,
        title: "Listener Running",
        description: "Welcome to having me");
  }
}

void stopAndroidListening() async {
  await NotificationsListener.stopService();
}

bool filterNotification(NotificationEvent event) {
  if (event.packageName == null && event.title == null && event.text == null) {
    return false;
  }
  switch(event.packageName) {
    case "com.vireen.whisper": {
      return false;
    }
    case "android": {
      return !["选择输入法"].contains(event.title);
    }
  }
  return true;
}

bool supportNotification() {
  return Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isLinux;
}

String pkg2name(String? pkg) {
  if (pkg == null) {
    return "通知";
  }
  return androidPackage[pkg]?? "通知";
}

var androidPackage = {'android': '系统', 'com.tencent.mm': '微信', 'com.tencent.mobileqq': 'QQ', 'com.eg.android.AlipayGphone': '支付宝', 'com.taobao.taobao': '淘宝', 'com.jingdong.app.mall': '京东', 'com.ss.android.ugc.aweme': '抖音', 'com.smile.gifmaker': '快手', 'com.sina.weibo': '微博', 'tv.danmaku.bili': '哔哩哔哩', 'com.netease.cloudmusic': '网易云音乐', 'com.tencent.qqlive': '腾讯视频', 'com.youku.phone': '优酷', 'com.qiyi.video': '爱奇艺', 'com.sankuai.meituan': '美团', 'com.sdu.didi.psnger': '滴滴出行', 'com.ss.android.lark': '飞书', 'com.android.mms': '短信', 'com.coolapk.market': '酷安', 'com.sankuai.meituan.takeoutnew': '美团外卖', 'com.taobao.idlefish': '闲鱼'};

Future<String> appName(String? package) async {
  if (package == null) {
    return "通知";
  }

  if (Platform.isAndroid) {
    // 好像可以获取到app的apk路径
    List<Application> apps = await DeviceApps.getInstalledApplications();
    for (var item in apps) {
      if (item.packageName == package) {
        return item.appName;
      }
    }
  }

  return pkg2name(package);
}