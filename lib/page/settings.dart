import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/helper/android_background.dart';
import 'package:whisper/helper/desktop_startup.dart';
import 'package:whisper/helper/file.dart';
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
import 'package:whisper/widget/app_empty_state.dart';
import 'package:whisper/widget/app_interactive_tile.dart';

typedef SettingsPresentationLoader = Future<SettingsPresentation> Function();

@immutable
class SettingsPresentation {
  const SettingsPresentation({
    required this.device,
    required this.saveDirectoryPath,
    required this.version,
    required this.closeToTray,
    required this.copyVerificationCode,
    required this.listenAndroidNotifications,
    required this.ignoreAndroidNotifications,
    required this.autoConnect,
    required this.launchAtStartup,
    required this.androidBackgroundKeepAlive,
    required this.audioSharePlaybackGain,
    required this.remoteInputScrollMultiplier,
    required this.themeMode,
    this.isAndroid = false,
    this.isDesktop = true,
    this.isMobile = false,
    this.notificationAppCount = 0,
  });

  final DeviceData device;
  final String saveDirectoryPath;
  final String version;
  final bool closeToTray;
  final bool copyVerificationCode;
  final bool listenAndroidNotifications;
  final bool ignoreAndroidNotifications;
  final bool autoConnect;
  final bool launchAtStartup;
  final bool androidBackgroundKeepAlive;
  final double audioSharePlaybackGain;
  final double remoteInputScrollMultiplier;
  final ThemeMode themeMode;
  final bool isAndroid;
  final bool isDesktop;
  final bool isMobile;
  final int notificationAppCount;
}

class SettingsSectionSurface extends StatelessWidget {
  const SettingsSectionSurface({
    super.key,
    required this.children,
  });

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        border: Border.all(color: palette.borderSubtle),
        borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var index = 0; index < children.length; index += 1) ...<Widget>[
            children[index],
            if (index < children.length - 1)
              Divider(
                height: 1,
                thickness: 1,
                indent: 56,
                endIndent: 12,
                color: palette.borderSubtle,
              ),
          ],
        ],
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.presentationLoader,
    this.changeDirectory,
    this.openDirectory,
    this.updateNickname,
    this.updateServerPort,
    this.updateNotificationForwarding,
    this.openNotificationApps,
  });

  final SettingsPresentationLoader? presentationLoader;
  final Future<String?> Function()? changeDirectory;
  final Future<void> Function(String path)? openDirectory;
  final Future<void> Function(String nickname)? updateNickname;
  final Future<void> Function(int port)? updateServerPort;
  final Future<void> Function(bool enabled)? updateNotificationForwarding;
  final Future<void> Function()? openNotificationApps;

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
  String _path = '';
  String _version = '';
  bool _close2tray = true;
  bool _listenAndroid = true;
  bool _ignoreAndroid = false;
  bool _copyVerifyCode = true;
  bool _autoConnect = true;
  bool _launchAtStartup = false;
  bool _androidBackgroundKeepAlive = true;
  double _audioSharePlaybackGain = 1.0;
  double _remoteInputScrollMultiplier = 1.0;
  ThemeMode _themeMode = ThemeMode.system;
  bool _isLoading = true;
  bool _loadFailed = false;
  bool _isAndroidPlatform = false;
  bool _isDesktopPlatform = true;
  bool _isMobilePlatform = false;
  int _notificationAppCount = 0;
  bool _notificationForwardingBusy = false;
  int _presentationLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _refreshDevice();
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

  Future<SettingsPresentation> _loadDefaultPresentation() async {
    final temp = await LocalSetting().instance();
    final path = await downloadDir();
    final packageInfo = await PackageInfo.fromPlatform();
    final closeToTray = await LocalSetting().isClose2Tray();
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
    final themeMode = await LocalSetting().themeMode();
    final notificationApps = await LocalSetting().listenAppNotifyList();
    return SettingsPresentation(
      device: temp,
      saveDirectoryPath: path.path,
      version: packageInfo.version,
      closeToTray: closeToTray,
      copyVerificationCode: copyVerify,
      listenAndroidNotifications: listenAndroid,
      ignoreAndroidNotifications: ignoreAndroid,
      autoConnect: autoConnect,
      launchAtStartup: launchAtStartup,
      androidBackgroundKeepAlive: androidBackgroundKeepAlive,
      audioSharePlaybackGain: audioSharePlaybackGain,
      remoteInputScrollMultiplier: remoteInputScrollMultiplier,
      themeMode: themeMode,
      isAndroid: Platform.isAndroid,
      isDesktop: isDesktop(),
      isMobile: isMobile(),
      notificationAppCount: notificationApps.length,
    );
  }

  Future<void> _refreshDevice() async {
    final generation = ++_presentationLoadGeneration;
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadFailed = false;
      });
    }
    try {
      final presentation =
          await (widget.presentationLoader ?? _loadDefaultPresentation).call();
      if (!mounted || generation != _presentationLoadGeneration) {
        return;
      }
      setState(() {
        device = presentation.device;
        _path = presentation.saveDirectoryPath;
        _version = presentation.version;
        _close2tray = presentation.closeToTray;
        _copyVerifyCode = presentation.copyVerificationCode;
        _ignoreAndroid = presentation.ignoreAndroidNotifications;
        _listenAndroid = presentation.listenAndroidNotifications;
        _autoConnect = presentation.autoConnect;
        _launchAtStartup = presentation.launchAtStartup;
        _androidBackgroundKeepAlive = presentation.androidBackgroundKeepAlive;
        _audioSharePlaybackGain = presentation.audioSharePlaybackGain;
        _remoteInputScrollMultiplier = presentation.remoteInputScrollMultiplier;
        _themeMode = presentation.themeMode;
        _isAndroidPlatform = presentation.isAndroid;
        _isDesktopPlatform = presentation.isDesktop;
        _isMobilePlatform = presentation.isMobile;
        _notificationAppCount = presentation.notificationAppCount;
        _isLoading = false;
        _loadFailed = false;
      });
    } catch (_) {
      if (!mounted || generation != _presentationLoadGeneration) {
        return;
      }
      setState(() {
        _isLoading = false;
        _loadFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context);

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(l10n.setting),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: WhisperUi.settingsMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
              children: [
                if (_isLoading)
                  const SizedBox(
                    height: 240,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_loadFailed)
                  AppEmptyState(
                    icon: Icons.error_outline,
                    title: l10n.settingsLoadFailedTitle,
                    body: l10n.settingsLoadFailedBody,
                    actionLabel: l10n.retry,
                    onAction: _refreshDevice,
                  )
                else ...<Widget>[
                  _buildSettingsSection(
                    l10n.settingsSectionDeviceAppearance,
                    l10n.settingsSectionDeviceAppearanceDesc,
                    [
                      _buildSettingItem(
                        l10n.themeMode,
                        Icon(Icons.dark_mode,
                            size: 20,
                            color: isDark
                                ? Colors.grey[400]
                                : CupertinoColors.systemGrey),
                        desc: _themeMode == ThemeMode.system
                            ? l10n.followSystem
                            : _themeMode == ThemeMode.dark
                                ? l10n.darkMode
                                : l10n.lightMode,
                        onTap: _showThemeModeSheet,
                        trailing: Icon(
                          Icons.arrow_forward_ios,
                          size: 14,
                          color: palette.textMuted,
                        ),
                      ),
                      _buildSettingItem(
                        l10n.nickname,
                        Icon(
                          platformIcon(device?.platform ?? ""),
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.systemGrey,
                        ),
                        desc: device?.name ?? '',
                        onTap: _editNickname,
                      ),
                    ],
                  ),
                  _buildSettingsSection(
                    l10n.settingsSectionConnectionTransfer,
                    l10n.settingsSectionConnectionTransferDesc,
                    [
                      _buildSettingItem(
                        l10n.serverPortTitle,
                        Icon(
                          Icons.wifi_tethering,
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.systemGrey,
                        ),
                        desc: l10n.serverPort(device?.port ?? 10002),
                        onTap: _editServerPort,
                      ),
                      _buildSettingItem(
                        l10n.autoConnectTrustedDevices,
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
                  if (_isDesktopPlatform || !_isMobilePlatform)
                    _buildSettingsSection(
                      l10n.settingsSectionSystemBehavior,
                      l10n.settingsSectionSystemBehaviorDesc,
                      [
                        if (_isDesktopPlatform)
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
                                  await DesktopStartupManager()
                                      .setEnabled(value);
                                } catch (error) {
                                  if (mounted) {
                                    setState(() {
                                      _launchAtStartup = previous;
                                    });
                                  }
                                  showAppToast(
                                    l10n.launchAtStartupFailed(
                                        error.toString()),
                                  );
                                }
                              },
                            ),
                          ),
                        if (!_isMobilePlatform)
                          _buildSettingItem(
                            l10n.close2tray,
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
                    l10n.settingsSectionPermissionsSharing,
                    l10n.settingsSectionPermissionsSharingDesc,
                    [
                      _buildSettingItem(
                        l10n.accessClipboard,
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
                      if (_isDesktopPlatform)
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
                  if (_isAndroidPlatform)
                    _buildSettingsSection(
                      l10n.settingsSectionMobileIntegration,
                      l10n.settingsSectionMobileIntegrationDesc,
                      [
                        _buildSettingItem(
                          l10n.androidBackgroundKeepAlive,
                          Icon(
                            Icons.sync_alt_rounded,
                            color: isDark
                                ? Colors.grey[400]
                                : CupertinoColors.systemGrey,
                          ),
                          desc: l10n.androidBackgroundKeepAliveDesc,
                          trailing: CupertinoSwitch(
                            value: _androidBackgroundKeepAlive,
                            onChanged: (bool value) async {
                              await LocalSetting()
                                  .setAndroidBackgroundKeepAlive(value);
                              setState(() {
                                _androidBackgroundKeepAlive = value;
                              });
                              if (WsSvrManager().isConnected) {
                                if (value) {
                                  await startAndroidBackgroundKeepAlive(
                                    title: l10n
                                        .androidBackgroundKeepAliveActiveTitle,
                                    description: l10n
                                        .androidBackgroundKeepAliveActiveDesc,
                                  );
                                } else {
                                  await stopAndroidBackgroundKeepAlive();
                                }
                              }
                            },
                          ),
                        ),
                        _buildSettingItem(
                          l10n.androidBatteryOptimization,
                          Icon(
                            Icons.battery_saver_rounded,
                            color: isDark
                                ? Colors.grey[400]
                                : CupertinoColors.systemGrey,
                          ),
                          desc: l10n.androidBatteryOptimizationDesc,
                          onTap: () async {
                            await openAndroidBatteryOptimizationSettings();
                          },
                        ),
                        _buildSettingItem(
                          l10n.pushNotification,
                          Icon(
                            Icons.notifications,
                            color: isDark
                                ? Colors.grey[400]
                                : CupertinoColors.systemGrey,
                          ),
                          enabled: !_notificationForwardingBusy,
                          trailing: CupertinoSwitch(
                            value: _listenAndroid,
                            onChanged: _notificationForwardingBusy
                                ? null
                                : _updateNotificationForwarding,
                          ),
                        ),
                        _buildSettingItem(
                          l10n.notificationApps,
                          Icon(
                            Icons.apps_rounded,
                            color: isDark
                                ? Colors.grey[400]
                                : CupertinoColors.systemGrey,
                          ),
                          desc: _listenAndroid
                              ? l10n.notificationAppsSelected(
                                  _notificationAppCount,
                                )
                              : l10n.notificationAppsDisabled,
                          enabled:
                              _listenAndroid && !_notificationForwardingBusy,
                          onTap: _openNotificationApps,
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            color: palette.textMuted,
                          ),
                        ),
                      ],
                    ),
                  _buildSettingsSection(
                    l10n.settingsSectionNotificationForwarding,
                    l10n.settingsSectionNotificationForwardingDesc,
                    [
                      _buildSettingItem(
                        l10n.ignoreNotification,
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
                        l10n.copyVerifyCode,
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
                    l10n.settingsSectionLanguageFiles,
                    l10n.settingsSectionLanguageFilesDesc,
                    [
                      _buildSettingItem(
                        l10n.selectLanguage,
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
                      _buildSaveDirectoryItem(l10n),
                      _buildSettingItem(
                        l10n.settingsVersion,
                        Icon(
                          Icons.copyright,
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.systemGrey,
                        ),
                        desc: _version,
                        onTap: () async {
                          final toLaunch = Uri(
                            scheme: 'https',
                            host: 'whisper.127014.xyz',
                            path: '/${locale.languageCode}',
                          );
                          await _launchInBrowser(toLaunch);
                        },
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _updateNotificationForwarding(bool enabled) async {
    if (_notificationForwardingBusy || enabled == _listenAndroid) {
      return;
    }
    final previous = _listenAndroid;
    setState(() {
      _notificationForwardingBusy = true;
    });

    final update = widget.updateNotificationForwarding;
    try {
      if (update != null) {
        await update(enabled);
      } else {
        await _applyNotificationForwarding(enabled);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _listenAndroid = enabled;
        _notificationForwardingBusy = false;
      });
    } catch (error, stackTrace) {
      var trustedValue = previous;
      if (update == null) {
        logger.e(
          'Failed to update notification forwarding',
          error: error,
          stackTrace: stackTrace,
        );
        trustedValue = await _restoreNotificationForwarding(previous);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _listenAndroid = trustedValue;
        _notificationForwardingBusy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.notificationForwardingUpdateFailed,
          ),
        ),
      );
    }
  }

  Future<void> _applyNotificationForwarding(bool enabled) async {
    await LocalSetting().setAndroidListen(enabled);
    await _syncAndroidNotificationListener(enabled);
    await NotificationAppRegistry.instance.refresh();
  }

  Future<bool> _restoreNotificationForwarding(bool previous) async {
    try {
      await _applyNotificationForwarding(previous);
    } catch (error, stackTrace) {
      logger.e(
        'Failed to restore notification forwarding',
        error: error,
        stackTrace: stackTrace,
      );
    }
    try {
      return await LocalSetting().isListenAndroid();
    } catch (error, stackTrace) {
      logger.e(
        'Failed to read restored notification forwarding state',
        error: error,
        stackTrace: stackTrace,
      );
      return previous;
    }
  }

  Future<void> _syncAndroidNotificationListener(bool enabled) async {
    if (!Platform.isAndroid || !WsSvrManager().isConnected) {
      return;
    }
    if (enabled) {
      await startAndroidListening();
    } else {
      await stopAndroidListening();
    }
  }

  Future<void> _openNotificationApps() async {
    if (!_listenAndroid || _notificationForwardingBusy) {
      return;
    }
    final open = widget.openNotificationApps;
    if (open != null) {
      await open();
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (context) => const AppListScreen(),
      ),
    );
    await NotificationAppRegistry.instance.refresh();
    final selectedApps = await LocalSetting().listenAppNotifyList();
    if (!mounted) {
      return;
    }
    setState(() {
      _notificationAppCount = selectedApps.length;
    });
  }

  Future<void> _editNickname() async {
    final l10n = AppLocalizations.of(context)!;
    final values = await showValidatedInputDialog(
      context,
      title: l10n.nickname,
      description: l10n.nicknameDesc,
      fields: <InputDialogField>[
        InputDialogField(
          initialValue: device?.name ?? '',
          label: l10n.nickname,
          validator: (value) {
            if (value.trim().isEmpty) {
              return l10n.validationNicknameRequired;
            }
            if (value.trim().runes.length > 64) {
              return l10n.validationNicknameTooLong;
            }
            return null;
          },
        ),
      ],
      confirmButtonText: l10n.confirm,
      cancelButtonText: l10n.cancel,
    );
    if (values == null) {
      return;
    }
    final nickname = values.single.trim();
    final updateNickname = widget.updateNickname;
    if (updateNickname != null) {
      await updateNickname(nickname);
    } else {
      await LocalSetting().updateNickname(nickname);
      await WsSvrManager().broadcastLocalProfileUpdate();
    }
    await _refreshDevice();
  }

  Future<void> _editServerPort() async {
    final l10n = AppLocalizations.of(context)!;
    final values = await showValidatedInputDialog(
      context,
      title: l10n.serverPortTitle,
      description: l10n.portDesc,
      fields: <InputDialogField>[
        InputDialogField(
          initialValue: '${device?.port ?? 10002}',
          label: l10n.serverPortTitle,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          validator: (value) {
            final port = int.tryParse(value);
            if (port == null || port < 1001 || port > 65535) {
              return l10n.validationPortInvalid;
            }
            return null;
          },
        ),
      ],
      confirmButtonText: l10n.confirm,
      cancelButtonText: l10n.cancel,
    );
    if (values == null) {
      return;
    }
    final port = int.parse(values.single);
    final updateServerPort = widget.updateServerPort;
    if (updateServerPort != null) {
      await updateServerPort(port);
    } else {
      await LocalSetting().updatePort(port);
    }
    await _refreshDevice();
  }

  Future<void> _pickSaveDir() async {
    final changeDirectory = widget.changeDirectory;
    final selectDir = changeDirectory != null
        ? await changeDirectory()
        : await FilePicker.platform.getDirectoryPath();
    if (selectDir == null) {
      return;
    }
    if (changeDirectory == null) {
      await LocalSetting().modifySavePath(selectDir);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _path = selectDir;
    });
  }

  Future<void> _openSaveDirectory() async {
    final openDirectory = widget.openDirectory;
    if (openDirectory != null) {
      await openDirectory(_path);
      return;
    }
    openDir(_path);
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
    final l10n = AppLocalizations.of(context)!;
    showCupertinoModalPopup(
      context: context,
      builder: (BuildContext context) {
        return CupertinoActionSheet(
          title: Text(
            l10n.selectThemeMode,
            style: TextStyle(
              color: colorScheme.onSurface,
            ),
          ),
          actions: [
            CupertinoActionSheetAction(
              child: Text(
                l10n.followSystem,
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
                l10n.lightMode,
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
                l10n.darkMode,
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
              l10n.cancel,
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
    final l10n = AppLocalizations.of(context)!;
    showCupertinoModalPopup(
      context: context,
      builder: (BuildContext context) {
        return CupertinoActionSheet(
          title: Text(
            l10n.selectLanguage,
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
              l10n.cancel,
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

  Widget _buildSettingsSection(
    String title,
    String subtitle,
    List<Widget> children,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildSettingsSectionHeader(title, subtitle),
          SettingsSectionSurface(children: children),
        ],
      ),
    );
  }

  Widget _buildSettingsSectionHeader(String title, String subtitle) {
    final theme = Theme.of(context);
    final palette = context.whisperPalette;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingItem(
    String title,
    Icon icon, {
    Widget? trailing,
    GestureTapCallback? onTap,
    String desc = '',
    Widget? subtitle,
    bool enabled = true,
  }) {
    final toggle = trailing is CupertinoSwitch ? trailing : null;
    final activate = onTap ??
        (toggle?.onChanged == null
            ? null
            : () => toggle!.onChanged!.call(!toggle.value));
    final resolvedSubtitle = subtitle ??
        (desc.isEmpty
            ? null
            : Text(
                desc,
                softWrap: true,
              ));
    final semanticLabel = desc.isEmpty ? title : '$title, $desc';

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: AppInteractiveTile(
        semanticLabel: semanticLabel,
        toggled: toggle?.value,
        enabled: enabled,
        onActivate: activate,
        leading: icon,
        title: Text(title),
        subtitle: resolvedSubtitle,
        trailing: toggle == null
            ? trailing
            : IgnorePointer(
                ignoring: !enabled,
                child: ExcludeFocus(
                  child: ExcludeSemantics(child: toggle),
                ),
              ),
      ),
    );
  }

  Widget _buildSaveDirectoryItem(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: AppInteractiveTile(
            semanticLabel: '${l10n.settingsSaveDirectory}, $_path',
            onActivate: _pickSaveDir,
            leading: const Icon(Icons.file_download_outlined),
            title: Text(l10n.settingsSaveDirectory),
            subtitle: SelectableText(_path),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              Tooltip(
                message: l10n.settingsChangeDirectory,
                child: TextButton.icon(
                  onPressed: () async {
                    await _pickSaveDir();
                  },
                  icon: const Icon(Icons.drive_file_move_outline),
                  label: Text(l10n.settingsChangeDirectory),
                ),
              ),
              Tooltip(
                message: l10n.settingsOpenDirectory,
                child: TextButton.icon(
                  onPressed: () async {
                    await _openSaveDirectory();
                  },
                  icon: const Icon(Icons.folder_open_outlined),
                  label: Text(l10n.settingsOpenDirectory),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _localeLabel(BuildContext context, String languageCode) {
    final l10n = AppLocalizations.of(context)!;
    switch (languageCode) {
      case 'zh':
        return l10n.localeNameZhHans;
      case 'es':
        return l10n.localeNameSpanish;
      case 'en':
      default:
        return l10n.localeNameEnglish;
    }
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
  const ClientSettingsScreen({
    super.key,
    required this.device,
    this.deviceLoader,
    this.isConnected,
    this.canConfigureRemoteInput,
    this.deleteDevice,
  });

  final DeviceData device;
  final Future<DeviceData?> Function(String uid)? deviceLoader;
  final bool? isConnected;
  final bool? canConfigureRemoteInput;
  final Future<void> Function(String uid)? deleteDevice;

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
    if (_canConfigureRemoteInput) {
      _loadRemoteInputLayout();
    }
  }

  bool get _canConfigureRemoteInput {
    final override = widget.canConfigureRemoteInput;
    if (override != null) {
      return override;
    }
    final platform = device.platform.toLowerCase();
    final isDesktopPeer = platform.contains('mac') ||
        platform.contains('windows') ||
        platform.contains('linux');
    return isDesktop() &&
        supportsNativeRemoteInput() &&
        (isDesktopPeer || WsSvrManager().supportsRemoteInputFor(device.uid));
  }

  Future<void> _refreshDevice() async {
    final loader = widget.deviceLoader;
    final temp = loader == null
        ? await LocalDatabase().fetchDevice(device.uid)
        : await loader(device.uid);
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
    await _restartRemoteInputSharingIfActive(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    final showRemoteInputSettings = _canConfigureRemoteInput;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(l10n.setting),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: WhisperUi.settingsMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
              children: [
                _buildClientSettingsSection(
                  l10n.settingsSectionPermissionsSharing,
                  l10n.settingsSectionPermissionsSharingDesc,
                  [
                    _DeviceSettingTile(
                      title: l10n.trust,
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
                      title: l10n.writeClipboard,
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
                if (!(widget.isConnected ??
                    WsSvrManager().isConnectedTo(device.uid)))
                  _buildClientSettingsSection(
                    l10n.dangerousActions,
                    l10n.deleteDeviceDesc,
                    [
                      _DeviceSettingTile(
                        title: l10n.deleteDevice,
                        icon: Icon(
                          Icons.delete_rounded,
                          color: CupertinoColors.destructiveRed,
                        ),
                        onTap: () async {
                          final confirmed = await confirmAction(
                            context,
                            title: l10n.deleteDeviceTitle(device.name),
                            description: l10n.deleteDeviceDesc,
                            confirmButtonText: l10n.confirm,
                            cancelButtonText: l10n.cancel,
                            isDestructive: true,
                          );
                          if (!confirmed) {
                            return;
                          }
                          final deleteDevice = widget.deleteDevice;
                          if (deleteDevice == null) {
                            await LocalDatabase()
                                .clearDevices(<String>[device.uid]);
                          } else {
                            await deleteDevice(device.uid);
                          }
                          if (!mounted) {
                            return;
                          }
                          Navigator.popUntil(context, (route) => route.isFirst);
                        },
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildClientSettingsSection(
    String title,
    String subtitle,
    List<Widget> children,
  ) {
    final theme = Theme.of(context);
    final palette = context.whisperPalette;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.textMuted,
                  ),
                ),
              ],
            ),
          ),
          SettingsSectionSurface(children: children),
        ],
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
    if (WsSvrManager().isConnectedTo(device.uid)) {
      final self = await LocalSetting().instance();
      if (!WsSvrManager().remotePeerTrustsPeer(device.uid, self.uid)) {
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
          remoteTopologyLoader: () async {
            final refreshProfile = WsSvrManager().requestRemoteProfileRefresh;
            await refreshProfile();
            return WsSvrManager().remoteDisplayTopology;
          },
        ),
      ),
    );
    if (updated != null) {
      await _saveRemoteInputLayout(updated);
    }
  }

  Future<void> _restartRemoteInputSharingIfActive(
    RemoteInputLayoutData layout,
  ) async {
    final coordinator = RemoteInputCoordinator.shared;
    final state = coordinator.state;
    if (state.role != RemoteInputRuntimeRole.source ||
        !state.isForPeer(device.uid)) {
      return;
    }

    final socketManager = WsSvrManager();
    if (!socketManager.isConnected || !socketManager.supportsRemoteInput) {
      return;
    }

    final self = await LocalSetting().instance();
    final storedDevice = await LocalDatabase().fetchDevice(device.uid);
    final localTrustsRemote = storedDevice?.auth == true;
    final remoteTrustsLocal = socketManager.remoteTrustsPeer(self.uid);
    final isMutuallyTrusted = localTrustsRemote && remoteTrustsLocal;
    if (!isMutuallyTrusted) {
      return;
    }

    try {
      final sharingPlan = await _sharingPlanForLayout(
        layout,
        coordinator: coordinator,
        socketManager: socketManager,
      );
      if (sharingPlan == null) {
        return;
      }
      await coordinator.stopSharing(
        sendControl: socketManager.sendRemoteInputControl,
      );
      await coordinator.startSharingToConnectedPeer(
        sourcePeerId: self.uid,
        sinkPeerId: device.uid,
        sinkHost: device.host,
        sinkPort: device.port,
        layoutEdge: sharingPlan.layoutEdge,
        releaseHotkey: layout.releaseHotkey,
        isMutuallyTrusted: isMutuallyTrusted,
        remoteCanInject: socketManager.supportsRemoteInput,
        sendControl: socketManager.sendRemoteInputControl,
        sourceDisplayId: sharingPlan.sourceDisplayId,
        sourceEdge: sharingPlan.sourceEdge,
        sourceSegmentStart: sharingPlan.sourceSegmentStart,
        sourceSegmentEnd: sharingPlan.sourceSegmentEnd,
        sinkDisplayId: sharingPlan.sinkDisplayId,
        sinkEdge: sharingPlan.sinkEdge,
        sinkSegmentStart: sharingPlan.sinkSegmentStart,
        sinkSegmentEnd: sharingPlan.sinkSegmentEnd,
        edgeMappings: sharingPlan.edgeMappings,
      );
    } catch (error, stackTrace) {
      logger.e(
        'restart remote input sharing after layout save failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<_RemoteInputSharingPlan?> _sharingPlanForLayout(
    RemoteInputLayoutData layout, {
    required RemoteInputCoordinator coordinator,
    required WsSvrManager socketManager,
  }) async {
    final savedLayout = layout.savedLayout;
    RemoteInputResolvedLayout? resolvedTopologyLayout;
    if (savedLayout != null && socketManager.supportsRemoteInputTopology) {
      final remoteTopology = socketManager.remoteDisplayTopology;
      if (remoteTopology != null) {
        final localTopology = await coordinator.displayTopology();
        resolvedTopologyLayout = RemoteInputLayoutGeometry.resolveSavedLayout(
          savedLayout: savedLayout,
          sourceTopology: localTopology,
          sinkTopology: remoteTopology,
          edgeTolerance: layout.edgeThresholdPx,
        );
      }
    }

    final legacyEdge = RemoteInputLayoutGeometry.adjacentEdge(
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
    final edge = resolvedTopologyLayout?.sharedSegment.sourceEdge ?? legacyEdge;
    if (edge == null) {
      return null;
    }

    final topologyMappings = resolvedTopologyLayout?.edgeMappings ??
        const <RemoteInputEdgeMapping>[];
    final sourceSegmentStart = topologyMappings.isEmpty
        ? resolvedTopologyLayout?.sharedSegment.start ?? 0
        : topologyMappings
            .map((mapping) => mapping.sourceSegmentStart)
            .reduce(math.min);
    final sourceSegmentEnd = topologyMappings.isEmpty
        ? resolvedTopologyLayout?.sharedSegment.end ?? 0
        : topologyMappings
            .map((mapping) => mapping.sourceSegmentEnd)
            .reduce(math.max);

    return _RemoteInputSharingPlan(
      layoutEdge: resolvedTopologyLayout?.sharedSegment.sourceEdge ?? edge,
      sourceDisplayId: resolvedTopologyLayout?.sourceDisplay.displayId ?? '',
      sourceEdge: resolvedTopologyLayout?.sharedSegment.sourceEdge,
      sourceSegmentStart: sourceSegmentStart,
      sourceSegmentEnd: sourceSegmentEnd,
      sinkDisplayId: resolvedTopologyLayout?.sinkDisplay.displayId ?? '',
      sinkEdge: resolvedTopologyLayout?.sharedSegment.sinkEdge,
      sinkSegmentStart: resolvedTopologyLayout?.sinkSegmentStart ?? 0,
      sinkSegmentEnd: resolvedTopologyLayout?.sinkSegmentEnd ?? 0,
      edgeMappings: topologyMappings,
    );
  }
}

class _RemoteInputSharingPlan {
  const _RemoteInputSharingPlan({
    required this.layoutEdge,
    required this.sourceDisplayId,
    required this.sourceEdge,
    required this.sourceSegmentStart,
    required this.sourceSegmentEnd,
    required this.sinkDisplayId,
    required this.sinkEdge,
    required this.sinkSegmentStart,
    required this.sinkSegmentEnd,
    required this.edgeMappings,
  });

  final RemoteInputEdge layoutEdge;
  final String sourceDisplayId;
  final RemoteInputEdge? sourceEdge;
  final int sourceSegmentStart;
  final int sourceSegmentEnd;
  final String sinkDisplayId;
  final RemoteInputEdge? sinkEdge;
  final int sinkSegmentStart;
  final int sinkSegmentEnd;
  final List<RemoteInputEdgeMapping> edgeMappings;
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
    final trailingWidget = trailing;
    final CupertinoSwitch? toggle =
        trailingWidget is CupertinoSwitch ? trailingWidget : null;
    final activate = onTap ??
        (toggle?.onChanged == null
            ? null
            : () => toggle!.onChanged!.call(!toggle.value));

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: AppInteractiveTile(
        semanticLabel: title,
        toggled: toggle?.value,
        onActivate: activate,
        leading: icon,
        title: Text(title),
        trailing: toggle == null
            ? trailingWidget
            : ExcludeFocus(child: ExcludeSemantics(child: toggle)),
      ),
    );
  }
}
