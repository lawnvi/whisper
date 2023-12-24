// 假设你有一个名为 Device 的类用于存储设备信息
// class Device {
//   final int id;
//   final String uid;
//   final String name;
//   final String ipAddress;
//   final bool clipboardAccessible;
//   final DateTime lastConnection;
//
//   Device({
//     required this.id,
//     required this.uid,
//     required this.name,
//     required this.ipAddress,
//     required this.clipboardAccessible,
//     required this.lastConnection,
//   });
// }

import 'message.dart';

class Device {
  String uid = "";
  String name = "";
  String host = "";
  int port = 0;
  bool isServer = false;
  String platform = "";
  int lastTime = 0;
  List<Message>? messageList;
}