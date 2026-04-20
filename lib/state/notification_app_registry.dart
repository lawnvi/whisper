import 'package:flutter/foundation.dart';
import 'package:whisper/helper/local.dart';

class NotificationAppRegistry extends ChangeNotifier {
  NotificationAppRegistry._();

  static final NotificationAppRegistry instance = NotificationAppRegistry._();

  Map<String, int> _packages = const {};

  Map<String, int> get packages => Map.unmodifiable(_packages);

  bool containsPackage(String? packageName) {
    if (packageName == null || packageName.isEmpty) {
      return false;
    }
    return _packages.containsKey(packageName);
  }

  Future<void> refresh() async {
    final nextPackages = await LocalSetting().listenAppNotifyList();
    if (mapEquals(_packages, nextPackages)) {
      return;
    }
    _packages = nextPackages;
    notifyListeners();
  }
}
