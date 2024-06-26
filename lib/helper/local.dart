import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:whisper/model/LocalDatabase.dart';

import 'helper.dart';

class LocalSetting {
  // 创建一个私有的静态实例变量
  static final LocalSetting _singleton = LocalSetting._internal();

  // 私有构造函数，阻止类被直接实例化
  LocalSetting._internal();

  // 工厂构造函数，返回单例实例
  factory LocalSetting() {
    return _singleton;
  }

  final String _uuid = "_uuid";
  final String _name = "_name";
  final String _port = "_port";
  final String _isServer = "_is_server";
  final String _clipboard = "_clipboard";
  final String _noAuth = "_no_auth";
  final String _password = "_password";
  final String _doubleClickDelete = "_double_click_delete";
  final String _close2tray = "_close_to_tray";
  final String _windowWidth = "_window_width";
  final String _windowHeight = "_window_height";
  final String _localization = "_localization";
  final String _ftpDir = "_ftpDir";
  final String _ftpPort = "_ftpPort";
  final String _notifyAppMap = "_notifyAppMap";
  final String _savePath = "_savePath";
  final String _copyVerifyCode = "_copyVerifyCode";
  final String _ignoreAndroidNotify = "_ignoreAndroidNotify";
  final String _listenAndroidNotify = "_listenAndroidNotify";

  Future<DeviceData> instance({bool online = false}) async {
    return DeviceData(
        id: 0,
        uid: await getSPDefault(_uuid, const Uuid().v4()),
        name: await getSPDefault(_name, await deviceName()),
        host: await getLocalIpAddress(),
        port: await getSPDefault(_port, 10002),
        platform: Platform.operatingSystem,
        isServer: await getSPDefault(_isServer, false),
        lastTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        online: online,
        password: await getSPDefault(_password, ""),
        clipboard: await getSPDefault(_clipboard, true),
        auth: await getSPDefault(_noAuth, false),
        around: false);
  }

  Future<T> getSPDefault<T>(String key, T value) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    var temp = sp.get(key);
    if (temp == null) {
      if (value is String) {
        sp.setString(key, value);
      } else if (value is bool) {
        sp.setBool(key, value);
      } else if (value is double) {
        sp.setDouble(key, value);
      } else if (value is int) {
        sp.setInt(key, value);
      } else if (value is List<String>) {
        sp.setStringList(key, value);
      }
    } else {
      value = temp as T;
    }
    return value;
  }

  Future<void> _setSP<T>(String key, T value) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    if (value is String) {
      sp.setString(key, value);
    } else if (value is bool) {
      sp.setBool(key, value);
    } else if (value is double) {
      sp.setDouble(key, value);
    } else if (value is int) {
      sp.setInt(key, value);
    } else if (value is List<String>) {
      sp.setStringList(key, value);
    }
  }

  void updateNickname(String nickname) async {
    _setSP(_name, nickname);
  }

  void updatePort(int port) async {
    _setSP(_port, port);
  }

  void updateServer(bool server) async {
    _setSP(_isServer, server);
  }

  void updateClipboard(bool allow) async {
    _setSP(_clipboard, allow);
  }

  void updateNoAuth(bool allow) async {
    _setSP(_noAuth, allow);
  }

  void updatePassword(String password) async {
    _setSP(_password, password);
  }

  void updateDoubleClickDelete(bool delete) async {
    _setSP(_doubleClickDelete, delete);
  }

  Future<bool> isDoubleClickDelete() async {
    return await getSPDefault(_doubleClickDelete, false);
  }

  void updateClose2Tray(bool delete) async {
    _setSP(_close2tray, delete);
  }

  Future<bool> isClose2Tray() async {
    return await getSPDefault(_close2tray, false);
  }

  Future<double> windowHeight() async {
    return await getSPDefault(_windowHeight, 800.00);
  }

  Future<double> windowWidth() async {
    return await getSPDefault(_windowWidth, 1200.00);
  }

  Future<void> setWindowHeight(double height) async {
    _setSP(_windowHeight, height);
  }

  Future<void> setWindowWidth(double width) async {
    _setSP(_windowWidth, width);
  }

  Future<String> localization() async {
    return await getSPDefault(_localization, 'zh');
  }

  Future<void> setLocalization(String local) async {
    _setSP(_localization, local);
  }

  Future<String> ftpDir() async {
    return await getSPDefault(_ftpDir, '');
  }

  Future<void> setFTPDir(String local) async {
    _setSP(_ftpDir, local);
  }

  Future<int> ftpPort() async {
    return await getSPDefault(_ftpPort, 8021);
  }

  Future<void> setFTPPort(int port) async {
    _setSP(_ftpPort, port);
  }

  Future<Map<String, int>> listenAppNotifyList() async {
    var str = await getSPDefault(_notifyAppMap, "");
    var map = <String, int>{};
    for (var item in str.split(":")) {
      if (item.isNotEmpty) {
        map[item] = 1;
      }
    }
    return map;
  }

  Future<void> modifyListenNotifyApp(
      {packages = List<String>, add = true, clear = false}) async {
    if (clear) {
      _setSP(_notifyAppMap, "");
      return;
    }
    if (packages.isEmpty) {
      return;
    }
    var str = await getSPDefault(_notifyAppMap, "");
    if (add) {
      packages.addAll(str.replaceAll("::", ":").split(":"));
      _setSP(_notifyAppMap, packages.join(":"));
    }else {
      Iterable<String> tempArr = str.replaceAll("::", ":").split(":");
      tempArr = tempArr.where((item) => !packages.contains(item));
      _setSP(_notifyAppMap, tempArr.join(":"));
    }
  }

  Future<String> savePath() async {
    return await getSPDefault(_savePath, '');
  }

  Future<void> modifySavePath(String path) async {
    _setSP(_savePath, path);
  }

  void setCopyVerify(bool copy) async {
    _setSP(_copyVerifyCode, copy);
  }

  Future<bool> copyVerify() async {
    return await getSPDefault(_copyVerifyCode, false);
  }

  void setAndroidNotification(bool ignore) async {
    _setSP(_close2tray, ignore);
  }

  Future<bool> ignoreAndroidNotification() async {
    return await getSPDefault(_ignoreAndroidNotify, false);
  }

  void setAndroidListen(bool listen) async {
    _setSP(_listenAndroidNotify, listen);
  }

  Future<bool> isListenAndroid() async {
    return await getSPDefault(_listenAndroidNotify, false);
  }
}
