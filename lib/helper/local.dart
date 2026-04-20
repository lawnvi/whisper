import 'dart:io';

import 'package:flutter/material.dart';
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
  final String _themeMode = "_theme_mode";
  final String _autoConnectEnabled = "_auto_connect_enabled";
  final String _lastManualPeerId = "_last_manual_peer_id";

  SharedPreferences? _cachedPreferences;

  Future<SharedPreferences> _preferences() async {
    _cachedPreferences ??= await SharedPreferences.getInstance();
    return _cachedPreferences!;
  }

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
    final SharedPreferences sp = await _preferences();
    var temp = sp.get(key);
    if (temp == null) {
      if (value is String) {
        await sp.setString(key, value);
      } else if (value is bool) {
        await sp.setBool(key, value);
      } else if (value is double) {
        await sp.setDouble(key, value);
      } else if (value is int) {
        await sp.setInt(key, value);
      } else if (value is List<String>) {
        await sp.setStringList(key, value);
      }
    } else {
      value = temp as T;
    }
    return value;
  }

  Future<void> _setSP<T>(String key, T value) async {
    final SharedPreferences sp = await _preferences();
    if (value is String) {
      await sp.setString(key, value);
    } else if (value is bool) {
      await sp.setBool(key, value);
    } else if (value is double) {
      await sp.setDouble(key, value);
    } else if (value is int) {
      await sp.setInt(key, value);
    } else if (value is List<String>) {
      await sp.setStringList(key, value);
    }
  }

  Future<void> updateNickname(String nickname) async {
    await _setSP(_name, nickname);
  }

  Future<void> updatePort(int port) async {
    await _setSP(_port, port);
  }

  Future<void> updateServer(bool server) async {
    await _setSP(_isServer, server);
  }

  Future<void> updateClipboard(bool allow) async {
    await _setSP(_clipboard, allow);
  }

  Future<void> updateNoAuth(bool allow) async {
    await _setSP(_noAuth, allow);
  }

  Future<void> updatePassword(String password) async {
    await _setSP(_password, password);
  }

  Future<void> updateDoubleClickDelete(bool delete) async {
    await _setSP(_doubleClickDelete, delete);
  }

  Future<bool> isDoubleClickDelete() async {
    return await getSPDefault(_doubleClickDelete, false);
  }

  Future<void> updateClose2Tray(bool delete) async {
    await _setSP(_close2tray, delete);
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
    await _setSP(_windowHeight, height);
  }

  Future<void> setWindowWidth(double width) async {
    await _setSP(_windowWidth, width);
  }

  Future<String> localization() async {
    return await getSPDefault(_localization, 'zh');
  }

  Future<void> setLocalization(String local) async {
    await _setSP(_localization, local);
  }

  Future<String> ftpDir() async {
    return await getSPDefault(_ftpDir, '');
  }

  Future<void> setFTPDir(String local) async {
    await _setSP(_ftpDir, local);
  }

  Future<int> ftpPort() async {
    return await getSPDefault(_ftpPort, 8021);
  }

  Future<void> setFTPPort(int port) async {
    await _setSP(_ftpPort, port);
  }

  Future<Map<String, int>> listenAppNotifyList() async {
    final raw = await getSPDefault(_notifyAppMap, "");
    final uniquePackages =
        raw.split(":").where((item) => item.isNotEmpty).toSet();
    return {
      for (final packageName in uniquePackages) packageName: 1,
    };
  }

  Future<void> modifyListenNotifyApp(
      {List<String> packages = const [],
      bool add = true,
      bool clear = false}) async {
    if (clear) {
      await _setSP(_notifyAppMap, "");
      return;
    }
    if (packages.isEmpty) {
      return;
    }
    final currentPackages = (await listenAppNotifyList()).keys.toSet();
    if (add) {
      currentPackages.addAll(packages.where((item) => item.isNotEmpty));
    } else {
      currentPackages.removeAll(packages);
    }
    await _setSP(_notifyAppMap, currentPackages.join(":"));
  }

  Future<String> savePath() async {
    return await getSPDefault(_savePath, '');
  }

  Future<void> modifySavePath(String path) async {
    await _setSP(_savePath, path);
  }

  Future<void> setCopyVerify(bool copy) async {
    await _setSP(_copyVerifyCode, copy);
  }

  Future<bool> copyVerify() async {
    return await getSPDefault(_copyVerifyCode, false);
  }

  Future<void> setAndroidNotification(bool ignore) async {
    await _setSP(_ignoreAndroidNotify, ignore);
  }

  Future<bool> ignoreAndroidNotification() async {
    return await getSPDefault(_ignoreAndroidNotify, false);
  }

  Future<void> setAndroidListen(bool listen) async {
    await _setSP(_listenAndroidNotify, listen);
  }

  Future<bool> isListenAndroid() async {
    return await getSPDefault(_listenAndroidNotify, false);
  }

  Future<bool> autoConnectEnabled() async {
    return await getSPDefault(_autoConnectEnabled, true);
  }

  Future<void> setAutoConnectEnabled(bool enabled) async {
    await _setSP(_autoConnectEnabled, enabled);
  }

  Future<String> lastManualPeerId() async {
    return await getSPDefault(_lastManualPeerId, "");
  }

  Future<void> setLastManualPeerId(String peerId) async {
    await _setSP(_lastManualPeerId, peerId);
  }

  Future<bool> autoApproveNewDevices() async {
    return await getSPDefault(_noAuth, false);
  }

  Future<bool> listenAndroidNotifications() async {
    return await isListenAndroid();
  }

  Future<bool> ignoreAndroidNotifications() async {
    return await ignoreAndroidNotification();
  }

  Future<ThemeMode> themeMode() async {
    final num = await getSPDefault(_themeMode, 0);
    switch (num) {
      case 0:
        return ThemeMode.system;
      case 1:
        return ThemeMode.light;
      case 2:
        return ThemeMode.dark;
    }

    return ThemeMode.light;
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    var num = 0;
    switch (mode) {
      case ThemeMode.system:
        num = 0;
        break;
      case ThemeMode.light:
        num = 1;
        break;
      case ThemeMode.dark:
        num = 2;
        break;
    }
    await _setSP(_themeMode, num);
  }
}
