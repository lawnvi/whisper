import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/global.dart';
import 'package:whisper/helper/android_background.dart';
import 'package:whisper/helper/desktop_startup.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/ftp.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/notification.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/main.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/page/appList.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_layout_editor.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
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
  bool _launchAtStartup = false;
  bool _androidBackgroundKeepAlive = true;
  bool _ftpServer = SimpleFtpServer().isActive();
  int _ftpPort = 8021;
  double _audioSharePlaybackGain = 1.0;
  double _remoteInputScrollMultiplier = 1.0;
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

  Future<bool> _loadLaunchAtStartup() async {
    if (!isDesktop()) {
      return false;
    }
    try {
      return await DesktopStartupManager().isEnabled();
    } catch (error) {
      logger.i('Failed to load desktop launch at startup: $error');
      return false;
    }
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
    final launchAtStartup = await _loadLaunchAtStartup();
    final androidBackgroundKeepAlive =
        await LocalSetting().androidBackgroundKeepAlive();
    final audioSharePlaybackGain =
        await LocalSetting().audioSharePlaybackGain();
    final remoteInputScrollMultiplier =
        await LocalSetting().remoteInputScrollMultiplier();
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
      _launchAtStartup = launchAtStartup;
      _androidBackgroundKeepAlive = androidBackgroundKeepAlive;
      _audioSharePlaybackGain = audioSharePlaybackGain;
      _remoteInputScrollMultiplier = remoteInputScrollMultiplier;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context);
    final horizontalPagePadding = isMobile() ? 10.0 : 14.0;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        leading: CupertinoNavigationBarBackButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          color: colorScheme.onSurface,
        ),
        title: Text(
          AppLocalizations.of(context)?.setting ?? "设置",
          style: TextStyle(color: colorScheme.onSurface),
        ),
      ),
      body: SafeArea(
        child: Material(
          color: colorScheme.surface,
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              horizontalPagePadding,
              12,
              horizontalPagePadding,
              16,
            ),
            children: [
              _buildSettingsSection(
                _settingsSectionText(locale, '设备与外观', 'Device & appearance'),
                _settingsSectionText(
                  locale,
                  '主题模式和本机昵称',
                  'Theme mode and local device name',
                ),
                [
                  _buildSettingItem(
                    AppLocalizations.of(context)?.themeMode ?? '主题模式',
                    Icon(Icons.dark_mode,
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey),
                    desc: _themeMode == ThemeMode.system
                        ? AppLocalizations.of(context)?.followSystem ?? '跟随系统'
                        : _themeMode == ThemeMode.dark
                            ? AppLocalizations.of(context)?.darkMode ?? '暗黑'
                            : AppLocalizations.of(context)?.lightMode ?? '明亮',
                    onTap: _showThemeModeSheet,
                    trailing: Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: palette.textMuted,
                    ),
                  ),
                  _buildSettingItem(
                    AppLocalizations.of(context)?.nickname ?? '昵称',
                    Icon(
                      platformIcon(device?.platform ?? ""),
                      color: isDark
                          ? Colors.grey[400]
                          : CupertinoColors.systemGrey,
                    ),
                    desc: device?.name ?? "",
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
                ],
              ),
              _buildSettingsSection(
                _settingsSectionText(locale, '连接与传输', 'Connection & transfer'),
                _settingsSectionText(
                  locale,
                  '端口、FTP 和可信设备自动连接',
                  'Ports, FTP, and trusted device auto-connect',
                ),
                [
                  _buildSettingItem(
                    AppLocalizations.of(context)?.serverPortTitle ?? '服务端口',
                    Icon(
                      Icons.wifi_tethering,
                      color: isDark
                          ? Colors.grey[400]
                          : CupertinoColors.systemGrey,
                    ),
                    desc: AppLocalizations.of(context)
                            ?.serverPort(device?.port ?? 10002) ??
                        '服务端口 ${device?.port}',
                    onTap: () {
                      showInputAlertDialog(
                        context,
                        title: AppLocalizations.of(context)?.serverPortTitle ??
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
                    AppLocalizations.of(context)?.ftpService ?? 'FTP服务',
                    Icon(
                      Icons.folder_shared_outlined,
                      color: isDark
                          ? Colors.grey[400]
                          : CupertinoColors.systemGrey,
                    ),
                    desc: 'Port $_ftpPort',
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
                    _autoConnectLabel(context),
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
                ],
              ),
              if (isDesktop() || !isMobile())
                _buildSettingsSection(
                  _settingsSectionText(locale, '系统行为', 'System behavior'),
                  _settingsSectionText(
                    locale,
                    '启动和窗口相关偏好',
                    'Startup and window preferences',
                  ),
                  [
                    if (isDesktop())
                      _buildSettingItem(
                        l10n.launchAtStartup,
                        Icon(
                          Icons.rocket_launch_rounded,
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.systemGrey,
                        ),
                        desc: l10n.launchAtStartupDesc,
                        trailing: CupertinoSwitch(
                          value: _launchAtStartup,
                          onChanged: (bool value) async {
                            final previous = _launchAtStartup;
                            setState(() {
                              _launchAtStartup = value;
                            });
                            try {
                              await DesktopStartupManager().setEnabled(value);
                            } catch (error) {
                              if (mounted) {
                                setState(() {
                                  _launchAtStartup = previous;
                                });
                              }
                              showAppToast(
                                l10n.launchAtStartupFailed(error.toString()),
                              );
                            }
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
                  ],
                ),
              _buildSettingsSection(
                _settingsSectionText(locale, '权限与共享', 'Permissions & sharing'),
                _settingsSectionText(
                  locale,
                  '新设备信任、剪贴板、音频和键鼠共享',
                  'Device trust, clipboard, audio, and input sharing',
                ),
                [
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
                    AppLocalizations.of(context)?.accessClipboard ?? '允许访问剪切板',
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
                  _buildSettingItem(
                    l10n.audioSharePlaybackGainSetting(
                      _audioSharePlaybackGainLabel(
                        _audioSharePlaybackGain,
                      ),
                    ),
                    Icon(
                      Icons.graphic_eq_rounded,
                      color: isDark
                          ? Colors.grey[400]
                          : CupertinoColors.systemGrey,
                    ),
                    desc: l10n.audioSharePlaybackGainDesc,
                    onTap: _showAudioSharePlaybackGainSheet,
                    trailing: Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: palette.textMuted,
                    ),
                  ),
                  if (isDesktop())
                    _buildSettingItem(
                      l10n.remoteInputScrollMultiplierSetting(
                        _remoteInputScrollMultiplierLabel(
                          _remoteInputScrollMultiplier,
                        ),
                      ),
                      Icon(
                        Icons.mouse_rounded,
                        color: isDark
                            ? Colors.grey[400]
                            : CupertinoColors.systemGrey,
                      ),
                      desc: l10n.remoteInputScrollMultiplierDesc,
                      onTap: _showRemoteInputScrollMultiplierSheet,
                      trailing: Icon(
                        Icons.arrow_forward_ios,
                        size: 14,
                        color: palette.textMuted,
                      ),
                    ),
                ],
              ),
              if (Platform.isAndroid)
                _buildSettingsSection(
                  _settingsSectionText(locale, '移动端集成', 'Mobile integration'),
                  _settingsSectionText(
                    locale,
                    '后台保活、电池优化和系统通知',
                    'Background keep-alive, battery optimization, and notifications',
                  ),
                  [
                    if (Platform.isAndroid)
                      _buildSettingItem(
                        AppLocalizations.of(context)
                                ?.androidBackgroundKeepAlive ??
                            '后台保活连接',
                        Icon(
                          Icons.sync_alt_rounded,
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.systemGrey,
                        ),
                        desc: AppLocalizations.of(context)
                                ?.androidBackgroundKeepAliveDesc ??
                            '连接期间启用前台服务，降低选文件、切后台时被系统断开的概率',
                        trailing: CupertinoSwitch(
                          value: _androidBackgroundKeepAlive,
                          onChanged: (bool value) async {
                            await LocalSetting()
                                .setAndroidBackgroundKeepAlive(value);
                            setState(() {
                              _androidBackgroundKeepAlive = value;
                            });
                            if (WsSvrManager().receiver.isNotEmpty) {
                              if (value) {
                                await startAndroidBackgroundKeepAlive(
                                  title: AppLocalizations.of(context)
                                          ?.androidBackgroundKeepAliveActiveTitle ??
                                      'Whisper 正在保持连接',
                                  description: AppLocalizations.of(context)
                                          ?.androidBackgroundKeepAliveActiveDesc ??
                                      '有活动会话时保持前台服务运行',
                                );
                              } else {
                                await stopAndroidBackgroundKeepAlive();
                              }
                            }
                          },
                        ),
                      ),
                    if (Platform.isAndroid)
                      _buildSettingItem(
                        AppLocalizations.of(context)
                                ?.androidBatteryOptimization ??
                            '电池优化白名单',
                        Icon(
                          Icons.battery_saver_rounded,
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.systemGrey,
                        ),
                        desc: AppLocalizations.of(context)
                                ?.androidBatteryOptimizationDesc ??
                            '建议允许后台运行并关闭电池优化，尤其是小米、OPPO、vivo、华为设备',
                        onTap: () async {
                          await openAndroidBatteryOptimizationSettings();
                        },
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
                  ],
                ),
              _buildSettingsSection(
                _settingsSectionText(
                    locale, '通知与安全', 'Notifications & security'),
                _settingsSectionText(
                  locale,
                  '安卓通知处理和验证码辅助',
                  'Android notification handling and verification helpers',
                ),
                [
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
                ],
              ),
              _buildSettingsSection(
                _settingsSectionText(locale, '语言与文件', 'Language & files'),
                _settingsSectionText(
                  locale,
                  '界面语言、保存位置和版本信息',
                  'Interface language, save location, and version',
                ),
                [
                  _buildSettingItem(
                    AppLocalizations.of(context)?.selectLanguage ?? '选择语言',
                    Icon(
                      Icons.language_rounded,
                      color: isDark
                          ? Colors.grey[400]
                          : CupertinoColors.systemGrey,
                    ),
                    desc: _localeLabel(context, locale.languageCode),
                    onTap: _showLanguageSheet,
                    trailing: Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: palette.textMuted,
                    ),
                  ),
                  _buildSettingItem(
                    'Save directory',
                    Icon(
                      Icons.file_download_outlined,
                      color: isDark
                          ? Colors.grey[400]
                          : CupertinoColors.systemGrey,
                    ),
                    desc: _path,
                    onLongPress: () async {
                      openDir((await downloadDir()).path);
                    },
                    onTap: _pickSaveDir,
                  ),
                  _buildSettingItem(
                    'Version',
                    Icon(
                      Icons.copyright,
                      color: isDark
                          ? Colors.grey[400]
                          : CupertinoColors.systemGrey,
                    ),
                    desc: _packageInfo?.version ?? "UNKNOWN",
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

  void _showThemeModeSheet() {
    final colorScheme = Theme.of(context).colorScheme;
    showCupertinoModalPopup(
      context: context,
      builder: (BuildContext context) {
        return CupertinoActionSheet(
          title: Text(
            AppLocalizations.of(context)?.selectThemeMode ?? '选择主题模式',
            style: TextStyle(
              color: colorScheme.onSurface,
            ),
          ),
          actions: [
            CupertinoActionSheetAction(
              child: Text(
                AppLocalizations.of(context)?.followSystem ?? '跟随系统',
                style: TextStyle(
                  color: colorScheme.onSurface,
                ),
              ),
              onPressed: () {
                Navigator.pop(context);
                _updateThemeMode(ThemeMode.system);
              },
            ),
            CupertinoActionSheetAction(
              child: Text(
                AppLocalizations.of(context)?.lightMode ?? '明亮',
                style: TextStyle(
                  color: colorScheme.onSurface,
                ),
              ),
              onPressed: () {
                Navigator.pop(context);
                _updateThemeMode(ThemeMode.light);
              },
            ),
            CupertinoActionSheetAction(
              child: Text(
                AppLocalizations.of(context)?.darkMode ?? '暗黑',
                style: TextStyle(
                  color: colorScheme.onSurface,
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
              AppLocalizations.of(context)?.cancel ?? '取消',
              style: const TextStyle(color: Colors.redAccent),
            ),
            onPressed: () {
              Navigator.pop(context);
            },
          ),
        );
      },
    );
  }

  void _showLanguageSheet() {
    final colorScheme = Theme.of(context).colorScheme;
    showCupertinoModalPopup(
      context: context,
      builder: (BuildContext context) {
        return CupertinoActionSheet(
          title: Text(
            AppLocalizations.of(context)?.selectLanguage ?? '选择语言',
            style: TextStyle(
              color: colorScheme.onSurface,
            ),
          ),
          actions: [
            for (final supportedLocale in _supportedLocales)
              CupertinoActionSheetAction(
                child: Text(
                  _localeLabel(
                    context,
                    supportedLocale.languageCode,
                  ),
                  style: TextStyle(
                    color: colorScheme.onSurface,
                  ),
                ),
                onPressed: () async {
                  Navigator.pop(context);
                  MyApp.setLocale(context, supportedLocale);
                  await LocalSetting()
                      .setLocalization(supportedLocale.languageCode);
                },
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            child: Text(
              AppLocalizations.of(context)?.cancel ?? '取消',
              style: const TextStyle(color: Colors.redAccent),
            ),
            onPressed: () {
              Navigator.pop(context);
            },
          ),
        );
      },
    );
  }

  String _settingsSectionText(Locale locale, String zhHans, String english) {
    return locale.languageCode == 'zh' ? zhHans : english;
  }

  Widget _buildSettingsSection(
    String title,
    String subtitle,
    List<Widget> children,
  ) {
    final palette = context.whisperPalette;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSettingsSectionHeader(title),
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            color: palette.surfaceElevated,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14.0),
              side: BorderSide(color: palette.borderSubtle),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsSectionHeader(String title) {
    final palette = context.whisperPalette;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: palette.textMuted,
        ),
      ),
    );
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
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12.0),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      icon.icon,
                      color: palette.textMuted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          softWrap: true,
                          style: TextStyle(
                            fontSize: 16.5,
                            color: colorScheme.onSurface,
                            fontWeight:
                                Platform.isWindows ? null : FontWeight.w500,
                            fontFamily:
                                Platform.isWindows ? null : 'SF Pro Display',
                          ),
                        ),
                        if (desc.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            desc,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            softWrap: true,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: palette.textMuted,
                              fontWeight:
                                  Platform.isWindows ? null : FontWeight.w400,
                              fontFamily:
                                  Platform.isWindows ? null : 'SF Pro Display',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: trailing,
                    ),
                  ],
                ],
              ),
            ),
            if (showDivider)
              Divider(
                height: 0.5,
                thickness: 0.5,
                color: palette.borderSubtle,
              ),
          ],
        ),
      ),
    );
  }

  String _localeLabel(BuildContext context, String languageCode) {
    final l10n = AppLocalizations.of(context);
    switch (languageCode) {
      case 'zh':
        return l10n?.localeNameZhHans ?? '简体中文';
      case 'es':
        return l10n?.localeNameSpanish ?? 'Español';
      case 'en':
      default:
        return l10n?.localeNameEnglish ?? 'English';
    }
  }

  String _autoConnectLabel(BuildContext context) {
    return AppLocalizations.of(context)?.autoConnectTrustedDevices ??
        'Auto-connect mutually trusted devices';
  }

  String _audioSharePlaybackGainLabel(double gain) {
    return 'x${gain.toStringAsFixed(1)}';
  }

  String _remoteInputScrollMultiplierLabel(double multiplier) {
    return 'x${multiplier.toStringAsFixed(1)}';
  }

  Future<void> _showAudioSharePlaybackGainSheet() async {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    var selectedGain = _audioSharePlaybackGain;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return CupertinoActionSheet(
              title: Text(
                l10n.audioSharePlaybackGainTitle,
                style: TextStyle(color: colorScheme.onSurface),
              ),
              message: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _audioSharePlaybackGainLabel(selectedGain),
                    style: TextStyle(
                      color: colorScheme.onSurface,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  CupertinoSlider(
                    value: selectedGain,
                    min: 1.0,
                    max: 3.0,
                    divisions: 20,
                    onChanged: (value) {
                      setModalState(() {
                        selectedGain = value;
                      });
                    },
                    onChangeEnd: (value) async {
                      await LocalSetting().setAudioSharePlaybackGain(value);
                      AudioShareCoordinator.shared.updatePlaybackGain(value);
                      if (!mounted) {
                        return;
                      }
                      setState(() {
                        _audioSharePlaybackGain = value;
                      });
                    },
                  ),
                ],
              ),
              cancelButton: CupertinoActionSheetAction(
                child: Text(
                  l10n.confirm,
                  style: TextStyle(color: colorScheme.onSurface),
                ),
                onPressed: () {
                  Navigator.pop(context);
                },
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showRemoteInputScrollMultiplierSheet() async {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    var selectedMultiplier = _remoteInputScrollMultiplier;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return CupertinoActionSheet(
              title: Text(
                l10n.remoteInputScrollMultiplierTitle,
                style: TextStyle(color: colorScheme.onSurface),
              ),
              message: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _remoteInputScrollMultiplierLabel(selectedMultiplier),
                    style: TextStyle(
                      color: colorScheme.onSurface,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  CupertinoSlider(
                    value: selectedMultiplier,
                    min: 0.5,
                    max: 3.0,
                    divisions: 25,
                    onChanged: (value) {
                      setModalState(() {
                        selectedMultiplier = value;
                      });
                    },
                    onChangeEnd: (value) async {
                      await LocalSetting().setRemoteInputScrollMultiplier(
                        value,
                      );
                      RemoteInputCoordinator.shared.updateScrollMultiplier(
                        value,
                      );
                      if (!mounted) {
                        return;
                      }
                      setState(() {
                        _remoteInputScrollMultiplier = value;
                      });
                    },
                  ),
                ],
              ),
              cancelButton: CupertinoActionSheetAction(
                child: Text(
                  l10n.confirm,
                  style: TextStyle(color: colorScheme.onSurface),
                ),
                onPressed: () {
                  Navigator.pop(context);
                },
              ),
            );
          },
        );
      },
    );
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
  RemoteInputLayoutData? _remoteInputLayout;

  @override
  void initState() {
    super.initState();
    device = widget.device;
    _refreshDevice();
    if (isDesktop()) {
      _loadRemoteInputLayout();
    }
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

  Future<void> _loadRemoteInputLayout() async {
    final layout = await _ensureRemoteInputLayout();
    if (!mounted) {
      return;
    }
    setState(() {
      _remoteInputLayout = layout;
    });
  }

  Future<RemoteInputLayoutData> _ensureRemoteInputLayout() async {
    final saved = await LocalDatabase().fetchRemoteInputLayout(device.uid);
    if (saved != null) {
      return saved;
    }
    final layout = RemoteInputLayoutData(
      peerId: device.uid,
      peerName: device.name,
      x: 1000,
      y: 0,
      width: 900,
      height: 600,
      enabled: true,
      autoActivate: false,
      autoRole: RemoteInputAutoRole.source.name,
      layoutVersion: 1,
      layoutJson: '',
      edgeThresholdPx: 6,
      releaseHotkey: 'ctrl+alt+esc',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await LocalDatabase().upsertRemoteInputLayout(layout);
    return layout;
  }

  Future<void> _saveRemoteInputLayout(RemoteInputLayoutData layout) async {
    final next = layout.copyWith(
      peerName: device.name,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await LocalDatabase().upsertRemoteInputLayout(next);
    if (!mounted) {
      return;
    }
    setState(() {
      _remoteInputLayout = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    final horizontalPagePadding = isMobile() ? 10.0 : 14.0;
    final showRemoteInputSettings = isDesktop();

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        leading: CupertinoNavigationBarBackButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          color: colorScheme.onSurface,
        ),
        title: Text(
          AppLocalizations.of(context)?.setting ?? '设置',
          style: TextStyle(color: colorScheme.onSurface),
        ),
      ),
      body: SafeArea(
        child: Material(
          color: colorScheme.surface,
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              horizontalPagePadding,
              12,
              horizontalPagePadding,
              16,
            ),
            children: [
              _buildClientSettingsCard(
                [
                  _DeviceSettingTile(
                    title: AppLocalizations.of(context)?.trust ?? '自动接入',
                    icon: Icon(
                      Icons.wifi_rounded,
                      color: palette.textMuted,
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
                    title:
                        AppLocalizations.of(context)?.writeClipboard ?? '写入剪切板',
                    icon: Icon(
                      Icons.copy,
                      color: palette.textMuted,
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
                  if (showRemoteInputSettings)
                    _DeviceSettingTile(
                      title: l10n.remoteInputAutoModeSetting(
                        _remoteInputAutoModeLabel(l10n, _remoteInputLayout),
                      ),
                      icon: Icon(
                        Icons.keyboard_option_key_rounded,
                        color: palette.textMuted,
                      ),
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        color: palette.textMuted,
                      ),
                      onTap: _openRemoteInputAutoModePickerWithTrustPrompt,
                    ),
                  if (showRemoteInputSettings)
                    _DeviceSettingTile(
                      title: l10n.remoteInputLayoutSetting(
                        _remoteInputEdgeLabel(l10n, _remoteInputLayout),
                      ),
                      icon: Icon(
                        Icons.splitscreen_rounded,
                        color: palette.textMuted,
                      ),
                      onTap: () async {
                        await _openRemoteInputLayoutEditor();
                      },
                    ),
                ],
              ),
              if (device.uid != WsSvrManager().receiver)
                _buildClientSettingsCard(
                  [
                    _DeviceSettingTile(
                      title:
                          AppLocalizations.of(context)?.deleteDevice ?? '删除设备',
                      icon: Icon(
                        Icons.delete_rounded,
                        color: CupertinoColors.destructiveRed,
                      ),
                      onTap: () {
                        showConfirmationDialog(
                          context,
                          title: AppLocalizations.of(context)
                                  ?.deleteDeviceTitle(device.name) ??
                              "删除${device.name}",
                          description:
                              AppLocalizations.of(context)?.deleteDeviceDesc ??
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClientSettingsCard(List<Widget> children) {
    final palette = context.whisperPalette;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        color: palette.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14.0),
          side: BorderSide(color: palette.borderSubtle),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }

  String _remoteInputEdgeLabel(
    AppLocalizations l10n,
    RemoteInputLayoutData? layout,
  ) {
    if (layout == null) {
      return l10n.remoteInputEdgeRight;
    }
    final edge = RemoteInputLayoutGeometry.adjacentEdge(
      local: const RemoteInputScreenRect(
        x: 0,
        y: 0,
        width: 1000,
        height: 800,
      ),
      peer: RemoteInputScreenRect(
        x: layout.x,
        y: layout.y,
        width: layout.width,
        height: layout.height,
      ),
    );
    switch (edge) {
      case RemoteInputEdge.left:
        return l10n.remoteInputEdgeLeft;
      case RemoteInputEdge.right:
        return l10n.remoteInputEdgeRight;
      case RemoteInputEdge.top:
        return l10n.remoteInputEdgeTop;
      case RemoteInputEdge.bottom:
        return l10n.remoteInputEdgeBottom;
      case null:
        return l10n.remoteInputEdgeNotAdjacent;
    }
  }

  String _remoteInputAutoModeLabel(
    AppLocalizations l10n,
    RemoteInputLayoutData? layout,
  ) {
    if (layout?.autoActivate != true) {
      return l10n.remoteInputAutoModeOff;
    }
    switch (layout!.autoRoleValue) {
      case RemoteInputAutoRole.source:
        return l10n.remoteInputAutoModeSource;
      case RemoteInputAutoRole.sink:
        return l10n.remoteInputAutoModeSink;
    }
  }

  Future<void> _openRemoteInputAutoModePickerWithTrustPrompt() async {
    final l10n = AppLocalizations.of(context)!;
    if (!device.auth) {
      showAppToast(l10n.remoteInputRequiresMutualTrust);
      return;
    }
    if (device.uid == WsSvrManager().receiver) {
      final self = await LocalSetting().instance();
      if (!WsSvrManager().remoteTrustsPeer(self.uid)) {
        showAppToast(l10n.remoteInputPeerMustTrustThisDevice);
        return;
      }
    }
    await _openRemoteInputAutoModePicker();
  }

  Future<void> _openRemoteInputAutoModePicker() async {
    final layout = await _ensureRemoteInputLayout();
    if (!mounted) {
      return;
    }
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final choice = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(
          l10n.remoteInputAutoModeTitle,
          style: TextStyle(color: colorScheme.onSurface),
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop('off'),
            child: Text(
              l10n.remoteInputAutoModeOff,
              style: TextStyle(color: colorScheme.onSurface),
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop('source'),
            child: Text(
              l10n.remoteInputAutoModeSource,
              style: TextStyle(color: colorScheme.onSurface),
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop('sink'),
            child: Text(
              l10n.remoteInputAutoModeSink,
              style: TextStyle(color: colorScheme.onSurface),
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            l10n.cancel,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
      ),
    );
    if (choice == null) {
      return;
    }
    final role = choice == 'sink'
        ? RemoteInputAutoRole.sink
        : RemoteInputAutoRole.source;
    await _saveRemoteInputLayout(
      layout.copyWith(
        autoActivate: choice != 'off',
        autoRole: role.name,
      ),
    );
  }

  Future<void> _openRemoteInputLayoutEditor() async {
    final layout = await _ensureRemoteInputLayout();
    if (!mounted) {
      return;
    }
    final updated = await Navigator.of(context).push<RemoteInputLayoutData>(
      MaterialPageRoute(
        builder: (context) => RemoteInputLayoutEditorScreen(
          initialLayout: layout,
          peerName: device.name,
          remoteTopology: WsSvrManager().remoteDisplayTopology,
        ),
      ),
    );
    if (updated != null) {
      await _saveRemoteInputLayout(updated);
    }
  }
}

class _DeviceSettingTile extends StatelessWidget {
  final String title;
  final Icon icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _DeviceSettingTile({
    required this.title,
    required this.icon,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12.0),
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            icon,
            const SizedBox(width: 12.0),
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16.5,
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w500,
                  fontFamily: Platform.isWindows ? null : 'SF Pro Display',
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              Align(
                alignment: Alignment.centerRight,
                child: trailing!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
