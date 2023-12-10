// 假设你有一个名为 Device 的类用于存储设备信息
class Device {
  final int id;
  final String uid;
  final String name;
  final String ipAddress;
  final bool clipboardAccessible;
  final DateTime lastConnection;

  Device({
    required this.id,
    required this.uid,
    required this.name,
    required this.ipAddress,
    required this.clipboardAccessible,
    required this.lastConnection,
  });
}