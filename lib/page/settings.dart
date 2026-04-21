import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:whisper/global.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/ftp.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/notification.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/main.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/page/appList.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/notification_app_registry.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_dialogs.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const List<Locale> _supportedLocales = [
    Locale('zh'),
    Locale('en'),
    Locale('es'),
  ];

  DeviceData? device;
  String _path = "";
  PackageInfo? _packageInfo;
  bool _doubleClickDelete = false;
  bool _close2tray = true;
  bool _listenAndroid = true;
  bool _ignoreAndroid = false;
  bool _copyVerifyCode = true;
  bool _autoConnect = true;
  bool _ftpServer = SimpleFtpServer().isActive();
  int _ftpPort = 8021;
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _refreshDevice();
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    final themeMode = await LocalSetting().themeMode();
    if (!mounted) {
      return;
    }
    setState(() {
      _themeMode = themeMode;
    });
  }

  Future<void> _refreshDevice() async {
    final temp = await LocalSetting().instance();
    final path = await downloadDir();
    final packageInfo = await PackageInfo.fromPlatform();
    final doubleClick = await LocalSetting().isDoubleClickDelete();
    final closeToTray = await LocalSetting().isClose2Tray();
    final ftpPort = await LocalSetting().ftpPort();
    final copyVerify = await LocalSetting().copyVerify();
    final listenAndroid = await LocalSetting().isListenAndroid();
    final ignoreAndroid = await LocalSetting().ignoreAndroidNotification();
    final autoConnect = await LocalSetting().autoConnectEnabled();
    if (!mounted) {
      return;
    }
    setState(() {
      device = temp;
      _path = path.path;
      _packageInfo = packageInfo;
      _close2tray = closeToTray;
      _doubleClickDelete = doubleClick;
      _ftpPort = ftpPort;
      _copyVerifyCode = copyVerify;
      _ignoreAndroid = ignoreAndroid;
      _listenAndroid = listenAndroid;
      _autoConnect = autoConnect;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final locale = Localizations.localeOf(context);

    return Scaffold(
      backgroundColor: isDark ? Colors.grey[900] : Colors.white,
      appBar: AppBar(
        backgroundColor: isDark ? Colors.grey[900] : Colors.white,
        leading: CupertinoNavigationBarBackButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          color: isDark ? Colors.grey[400] : Colors.lightBlue,
        ),
        title: Text(
          AppLocalizations.of(context)?.setting ?? "设置",
          style: TextStyle(color: isDark ? Colors.white : Colors.black),
        ),
      ),
      body: SafeArea(
        child: Material(
          color: isDark ? Colors.grey[900] : Colors.white,
          child: ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              Card(
                elevation: 2.0,
                color: isDark ? Colors.grey[800] : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12.0),
                ),
                child: Column(
                  children: [
                    _buildSettingItem(
                      AppLocalizations.of(context)?.themeMode ?? '主题模式',
                      Icon(Icons.dark_mode,
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.systemGrey),
                      trailing: CupertinoButton(
                        padding: EdgeInsets.zero,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _themeMode == ThemeMode.system
                                  ? AppLocalizations.of(context)
                                          ?.followSystem ??
                                      '跟随系统'
                                  : _themeMode == ThemeMode.dark
                                      ? AppLocalizations.of(context)
                                              ?.darkMode ??
                                          '暗黑'
                                      : AppLocalizations.of(context)
                                              ?.lightMode ??
                                          '明亮',
                              style: TextStyle(
                                color: isDark
                                    ? Colors.grey[400]
                                    : CupertinoColors.systemGrey,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.arrow_forward_ios,
                              size: 14,
                              color: isDark
                                  ? Colors.grey[400]
                                  : CupertinoColors.systemGrey,
                            ),
                          ],
                        ),
                        onPressed: () {
                          showCupertinoModalPopup(
                            context: context,
                            builder: (BuildContext context) {
                              return CupertinoActionSheet(
                                title: Text(
                                  AppLocalizations.of(context)
                                          ?.selectThemeMode ??
                                      '选择主题模式',
                                  style: TextStyle(
                                    color: isDark ? Colors.white : Colors.black,
                                  ),
                                ),
                                actions: [
                                  CupertinoActionSheetAction(
                                    child: Text(
                                      AppLocalizations.of(context)
                                              ?.followSystem ??
                                          '跟随系统',
                                      style: TextStyle(
                                        color: isDark
                                            ? Colors.white
                                            : Colors.black,
                                      ),
                                    ),
                                    onPressed: () {
                                      Navigator.pop(context);
                                      _updateThemeMode(ThemeMode.system);
                                    },
                                  ),
                                  CupertinoActionSheetAction(
                                    child: Text(
                                      AppLocalizations.of(context)?.lightMode ??
                                          '明亮',
                                      style: TextStyle(
                                        color: isDark
                                            ? Colors.white
                                            : Colors.black,
                                      ),
                                    ),
                                    onPressed: () {
                                      Navigator.pop(context);
                                      _updateThemeMode(ThemeMode.light);
                                    },
                                  ),
                                  CupertinoActionSheetAction(
                                    child: Text(
                                      AppLocalizations.of(context)?.darkMode ??
                                          '暗黑',
                                      style: TextStyle(
                                        color: isDark
                                            ? Colors.white
                                            : Colors.black,
                                      ),
                                    ),
                                    onPressed: () {
                                      Navigator.pop(context);
                                      _updateThemeMode(ThemeMode.dark);
                                    },
                                  ),
                                ],
                                cancelButton: CupertinoActionSheetAction(
                                  child: Text(
                                    AppLocalizations.of(context)?.cancel ??
                                        '取消',
                                    style: const TextStyle(
                                        color: Colors.redAccent),
                                  ),
                                  onPressed: () {
                                    Navigator.pop(context);
                                  },
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                    _buildSettingItem(
                      device?.name ?? "",
                      Icon(
                        platformIcon(device?.platform ?? ""),
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey,
                      ),
                      onTap: () {
                        showInputAlertDialog(
                          context,
                          title: AppLocalizations.of(context)?.nickname ?? '昵称',
                          description:
                              AppLocalizations.of(context)?.nicknameDesc ??
                                  '请输入昵称',
                          inputHints: [
                            {device?.name ?? "localhost": false}
                          ],
                          confirmButtonText:
                              AppLocalizations.of(context)?.confirm ?? '确定',
                          cancelButtonText:
                              AppLocalizations.of(context)?.cancel ?? '取消',
                          onConfirm: (List<String> inputValues) async {
                            if (inputValues[0].isEmpty) {
                              inputValues[0] = await deviceName();
                            }
                            await LocalSetting().updateNickname(inputValues[0]);
                            await _refreshDevice();
                          },
                        );
                      },
                    ),
                    _buildSettingItem(
                      AppLocalizations.of(context)
                              ?.serverPort(device?.port ?? 10002) ??
                          '服务端口 ${device?.port}',
                      Icon(
                        Icons.wifi_tethering,
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey,
                      ),
                      onTap: () {
                        showInputAlertDialog(
                          context,
                          title:
                              AppLocalizations.of(context)?.serverPortTitle ??
                                  '服务端口',
                          description: AppLocalizations.of(context)?.portDesc ??
                              '请输入服务端口 [1000, 65535]',
                          inputHints: [
                            {'${device?.port ?? "10002"}': true}
                          ],
                          confirmButtonText:
                              AppLocalizations.of(context)?.confirm ?? '确定',
                          cancelButtonText:
                              AppLocalizations.of(context)?.cancel ?? '取消',
                          onConfirm: (List<String> inputValues) async {
                            try {
                              final port = int.parse(inputValues[0]);
                              if (port > 1000 && port <= 65535) {
                                await LocalSetting().updatePort(port);
                                await _refreshDevice();
                              }
                            } on Exception catch (_) {}
                          },
                        );
                      },
                    ),
                    _buildSettingItem(
                      '${AppLocalizations.of(context)?.ftpService ?? 'FTP服务'}$defaultFtpPort (alpha)',
                      Icon(
                        Icons.folder_shared_outlined,
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey,
                      ),
                      onTap: _pickFTPDir,
                      onLongPress: () {
                        if (_ftpServer) {
                          return;
                        }
                        showInputAlertDialog(
                          context,
                          title:
                              'FTP${AppLocalizations.of(context)?.serverPortTitle ?? '服务端口'}',
                          description: AppLocalizations.of(context)?.portDesc ??
                              '请输入服务端口 [1000, 65535]',
                          inputHints: [
                            {'$_ftpPort': true}
                          ],
                          confirmButtonText:
                              AppLocalizations.of(context)?.confirm ?? '确定',
                          cancelButtonText:
                              AppLocalizations.of(context)?.cancel ?? '取消',
                          onConfirm: (List<String> inputValues) async {
                            try {
                              final port = int.parse(inputValues[0]);
                              if (port > 1000 && port <= 65535) {
                                await LocalSetting().setFTPPort(port);
                                setState(() {
                                  _ftpPort = port;
                                });
                              }
                            } on Exception catch (_) {}
                          },
                        );
                      },
                      trailing: CupertinoSwitch(
                        value: _ftpServer,
                        onChanged: (bool value) async {
                          var path = await LocalSetting().ftpDir();
                          if (path.isEmpty) {
                            path = await _pickFTPDir();
                          }

                          if (path.isEmpty) {
                            return;
                          }

                          value
                              ? SimpleFtpServer().start(path, defaultFtpPort)
                              : SimpleFtpServer().stop();
                          setState(() {
                            _ftpServer = value;
                          });
                        },
                      ),
                    ),
                    _buildSettingItem(
                      '自动连接互信设备',
                      Icon(
                        Icons.auto_mode_rounded,
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey,
                      ),
                      trailing: CupertinoSwitch(
                        value: _autoConnect,
                        onChanged: (bool value) async {
                          await LocalSetting().setAutoConnectEnabled(value);
                          setState(() {
                            _autoConnect = value;
                          });
                        },
                      ),
                    ),
                    _buildSettingItem(
                      AppLocalizations.of(context)?.trustNewDevice ?? '自动通过新设备',
                      Icon(
                        Icons.lock_open,
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey,
                      ),
                      trailing: CupertinoSwitch(
                        value: device?.auth ?? false,
                        onChanged: (bool value) async {
                          await LocalSetting().updateNoAuth(value);
                          await _refreshDevice();
                        },
                      ),
                    ),
                    _buildSettingItem(
                      AppLocalizations.of(context)?.accessClipboard ??
                          '允许访问剪切板',
                      Icon(
                        Icons.copy,
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey,
                      ),
                      trailing: CupertinoSwitch(
                        value: device?.clipboard ?? false,
                        onChanged: (bool value) async {
                          await LocalSetting().updateClipboard(value);
                          await _refreshDevice();
                        },
                      ),
                    ),
                    if (!isMobile())
                      _buildSettingItem(
                        AppLocalizations.of(context)?.close2tray ?? '关闭时隐藏到托盘',
                        Icon(
                          Icons.close_rounded,
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.systemGrey,
                        ),
                        trailing: CupertinoSwitch(
                          value: _close2tray,
                          onChanged: (bool value) async {
                            await LocalSetting().updateClose2Tray(value);
                            setState(() {
                              _close2tray = value;
                            });
                          },
                        ),
                      ),
                    if (Platform.isAndroid)
                      _buildSettingItem(
                        AppLocalizations.of(context)?.pushNotification ??
                            '转发通知',
                        Icon(
                          Icons.notifications,
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.systemGrey,
                        ),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const AppListScreen(),
                            ),
                          );
                          await NotificationAppRegistry.instance.refresh();
                        },
                        trailing: CupertinoSwitch(
                          value: _listenAndroid,
                          onChanged: (bool value) async {
                            await LocalSetting().setAndroidListen(value);
                            setState(() {
                              _listenAndroid = value;
                            });
                            if (Platform.isAndroid &&
                                WsSvrManager().receiver.isNotEmpty) {
                              value
                                  ? startAndroidListening()
                                  : stopAndroidListening();
                            }
                            await NotificationAppRegistry.instance.refresh();
                            if (value &&
                                NotificationAppRegistry
                                    .instance.packages.isEmpty) {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => const AppListScreen(),
                                ),
                              );
                              await NotificationAppRegistry.instance.refresh();
                            }
                          },
                        ),
                      ),
                    _buildSettingItem(
                      AppLocalizations.of(context)?.ignoreNotification ??
                          '忽略安卓通知',
                      Icon(
                        Icons.notifications_off,
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey,
                      ),
                      trailing: CupertinoSwitch(
                        value: _ignoreAndroid,
                        onChanged: (bool value) async {
                          await LocalSetting().setAndroidNotification(value);
                          setState(() {
                            _ignoreAndroid = value;
                          });
                        },
                      ),
                    ),
                    if (Localizations.localeOf(context).languageCode == "zh")
                      _buildSettingItem(
                        AppLocalizations.of(context)?.copyVerifyCode ??
                            '提取短信验证码写入剪切板',
                        Icon(
                          Icons.verified_user_rounded,
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.systemGrey,
                        ),
                        trailing: CupertinoSwitch(
                          value: _copyVerifyCode,
                          onChanged: (bool value) async {
                            await LocalSetting().setCopyVerify(value);
                            setState(() {
                              _copyVerifyCode = value;
                            });
                          },
                        ),
                      ),
                    _buildSettingItem(
                      AppLocalizations.of(context)?.language(
                              Localizations.localeOf(context).languageCode) ??
                          'language ${Localizations.localeOf(context).languageCode}',
                      Icon(
                        Icons.language_rounded,
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey,
                      ),
                      trailing: CupertinoButton(
                        padding: EdgeInsets.zero,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _localeLabel(locale.languageCode),
                              style: TextStyle(
                                color: isDark
                                    ? Colors.grey[400]
                                    : CupertinoColors.systemGrey,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.arrow_forward_ios,
                              size: 14,
                              color: isDark
                                  ? Colors.grey[400]
                                  : CupertinoColors.systemGrey,
                            ),
                          ],
                        ),
                        onPressed: () {
                          showCupertinoModalPopup(
                            context: context,
                            builder: (BuildContext context) {
                              return CupertinoActionSheet(
                                title: Text(
                                  AppLocalizations.of(context)
                                          ?.selectLanguage ??
                                      '选择语言',
                                  style: TextStyle(
                                    color: isDark ? Colors.white : Colors.black,
                                  ),
                                ),
                                actions: [
                                  for (final supportedLocale
                                      in _supportedLocales)
                                    CupertinoActionSheetAction(
                                      child: Text(
                                        _localeLabel(
                                            supportedLocale.languageCode),
                                        style: TextStyle(
                                          color: isDark
                                              ? Colors.white
                                              : Colors.black,
                                        ),
                                      ),
                                      onPressed: () async {
                                        Navigator.pop(context);
                                        MyApp.setLocale(
                                            context, supportedLocale);
                                        await LocalSetting().setLocalization(
                                            supportedLocale.languageCode);
                                      },
                                    ),
                                ],
                                cancelButton: CupertinoActionSheetAction(
                                  child: Text(
                                    AppLocalizations.of(context)?.cancel ??
                                        '取消',
                                    style: const TextStyle(
                                        color: Colors.redAccent),
                                  ),
                                  onPressed: () {
                                    Navigator.pop(context);
                                  },
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                    _buildSettingItem(
                      _path,
                      Icon(
                        Icons.file_download_outlined,
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey,
                      ),
                      onLongPress: () async {
                        openDir((await downloadDir()).path);
                      },
                      onTap: _pickSaveDir,
                    ),
                    _buildSettingItem(
                      _packageInfo?.version ?? "UNKNOWN",
                      Icon(
                        Icons.copyright,
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey,
                      ),
                      onTap: () async {
                        final toLaunch = Uri(
                          scheme: 'https',
                          host: 'whisper.127014.xyz',
                          path: '/zh',
                        );
                        _launchInBrowser(toLaunch);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String> _pickFTPDir() async {
    final selectDir = await FilePicker.platform.getDirectoryPath();
    if (selectDir != null) {
      await LocalSetting().setFTPDir(selectDir);
    }
    return selectDir ?? "";
  }

  Future<String> _pickSaveDir() async {
    final selectDir = await FilePicker.platform.getDirectoryPath();
    if (selectDir != null) {
      await LocalSetting().modifySavePath(selectDir);
      if (!mounted) {
        return selectDir;
      }
      setState(() {
        _path = selectDir;
      });
    }
    return selectDir ?? "";
  }

  Future<void> _launchInBrowser(Uri url) async {
    if (!await launchUrl(
      url,
      mode: LaunchMode.externalApplication,
    )) {
      throw Exception('Could not launch $url');
    }
  }

  Future<void> _updateThemeMode(ThemeMode mode) async {
    MyApp.setTheme(context, mode);
    await LocalSetting().setThemeMode(mode);
    if (!mounted) {
      return;
    }
    setState(() {
      _themeMode = mode;
    });
  }

  Widget _buildSettingItem(
    String title,
    Icon icon, {
    Widget? trailing,
    bool showDivider = false,
    GestureTapCallback? onTap,
    String desc = "",
    GestureTapCallback? onLongPress,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          children: [
            Container(
              constraints: const BoxConstraints(minHeight: 52),
              child: Row(
                children: [
                  Icon(
                    icon.icon,
                    color:
                        isDark ? Colors.grey[400] : CupertinoColors.systemGrey,
                  ),
                  const SizedBox(width: 8.0),
                  Expanded(
                    child: Text(
                      title,
                      softWrap: true,
                      style: TextStyle(
                        fontSize: 17.0,
                        color: isDark ? Colors.white : CupertinoColors.black,
                        fontWeight: Platform.isWindows ? null : FontWeight.w500,
                        fontFamily:
                            Platform.isWindows ? null : 'SF Pro Display',
                      ),
                    ),
                  ),
                  if (trailing != null) trailing,
                ],
              ),
            ),
            if (desc.isNotEmpty)
              Text(
                desc,
                softWrap: true,
                style: TextStyle(
                  fontSize: 12.0,
                  color: isDark ? Colors.grey[400] : CupertinoColors.black,
                  fontWeight: Platform.isWindows ? null : FontWeight.w500,
                  fontFamily: Platform.isWindows ? null : 'SF Pro Display',
                ),
              ),
            if (showDivider)
              Divider(
                height: 0.5,
                thickness: 0.5,
                color: isDark ? Colors.grey[800]! : Colors.grey[200]!,
              ),
          ],
        ),
      ),
    );
  }

  String _localeLabel(String languageCode) {
    switch (languageCode) {
      case 'zh':
        return '简体中文';
      case 'es':
        return 'Español';
      case 'en':
      default:
        return 'English';
    }
  }
}

class ClientSettingsScreen extends StatefulWidget {
  final DeviceData device;

  const ClientSettingsScreen({super.key, required this.device});

  @override
  State<ClientSettingsScreen> createState() => _ClientSettingsScreenState();
}

class _ClientSettingsScreenState extends State<ClientSettingsScreen> {
  late DeviceData device;

  @override
  void initState() {
    super.initState();
    device = widget.device;
    _refreshDevice();
  }

  Future<void> _refreshDevice() async {
    final temp = await LocalDatabase().fetchDevice(device.uid);
    if (temp == null || !mounted) {
      return;
    }
    setState(() {
      device = temp;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final coordinator = ConnectionCoordinator();
    final presence = coordinator.peer(device.uid);
    final mutualTrust = (presence?.locallyTrusted ?? device.auth) &&
        (presence?.remotelyTrusted ?? false);

    return Scaffold(
      appBar: AppBar(
        leading: CupertinoNavigationBarBackButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          color: isDark ? Colors.grey[400] : Colors.lightBlue,
        ),
        title: Text(
          AppLocalizations.of(context)?.setting ?? '设置',
          style: TextStyle(color: isDark ? Colors.white : Colors.black),
        ),
      ),
      body: SafeArea(
        child: Material(
          child: ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              Card(
                elevation: 1.2,
                color: isDark ? Colors.grey[900] : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12.0),
                ),
                child: Column(
                  children: [
                    _DeviceSettingTile(
                      title: mutualTrust ? '双向互信已开启' : '尚未形成双向互信',
                      icon: Icon(
                        mutualTrust
                            ? Icons.verified_user_rounded
                            : Icons.shield_outlined,
                        color: mutualTrust
                            ? context.whisperPalette.trusted
                            : (isDark
                                ? Colors.grey[400]
                                : CupertinoColors.systemGrey),
                      ),
                      showDivider: false,
                    ),
                    _DeviceSettingTile(
                      title: AppLocalizations.of(context)?.trust ?? '自动接入',
                      icon: Icon(
                        Icons.wifi_rounded,
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey,
                      ),
                      trailing: CupertinoSwitch(
                        value: device.auth,
                        onChanged: (bool value) async {
                          await LocalDatabase().authDevice(device.uid, value);
                          await ConnectionCoordinator().refreshTrustState();
                          _refreshDevice();
                        },
                      ),
                    ),
                    _DeviceSettingTile(
                      title: AppLocalizations.of(context)?.writeClipboard ??
                          '写入剪切板',
                      icon: Icon(
                        Icons.copy,
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey,
                      ),
                      trailing: CupertinoSwitch(
                        value: device.clipboard,
                        onChanged: (bool value) async {
                          await LocalDatabase()
                              .clipboardDevice(device.uid, value);
                          _refreshDevice();
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (device.uid != WsSvrManager().receiver)
                Card(
                  elevation: 2.0,
                  color: isDark ? Colors.grey[900] : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12.0),
                  ),
                  child: Column(
                    children: [
                      _DeviceSettingTile(
                        title: AppLocalizations.of(context)?.deleteDevice ??
                            '删除设备',
                        icon: Icon(
                          Icons.delete_rounded,
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.destructiveRed,
                        ),
                        showDivider: false,
                        onTap: () {
                          showConfirmationDialog(
                            context,
                            title: AppLocalizations.of(context)
                                    ?.deleteDeviceTitle(device.name) ??
                                "删除${device.name}",
                            description: AppLocalizations.of(context)
                                    ?.deleteDeviceDesc ??
                                "删除与此设备的所有消息，不可恢复",
                            confirmButtonText:
                                AppLocalizations.of(context)?.confirm ?? "确定",
                            cancelButtonText:
                                AppLocalizations.of(context)?.cancel ?? "取消",
                            onConfirm: () {
                              LocalDatabase().clearDevices([device.uid]);
                              Navigator.popUntil(context, (route) {
                                return route.isFirst;
                              });
                            },
                          );
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceSettingTile extends StatelessWidget {
  final String title;
  final Icon icon;
  final Widget? trailing;
  final bool showDivider;
  final VoidCallback? onTap;

  const _DeviceSettingTile({
    required this.title,
    required this.icon,
    this.trailing,
    this.showDivider = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          children: [
            SizedBox(
              height: 56.0,
              child: Row(
                children: [
                  icon,
                  const SizedBox(width: 16.0),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 17.0,
                        color: isDark ? Colors.white : CupertinoColors.black,
                        fontWeight: FontWeight.w500,
                        fontFamily:
                            Platform.isWindows ? null : 'SF Pro Display',
                      ),
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
            if (showDivider)
              Divider(
                height: 1,
                color: isDark ? Colors.grey[800]! : Colors.white38,
              ),
          ],
        ),
      ),
    );
  }
}
