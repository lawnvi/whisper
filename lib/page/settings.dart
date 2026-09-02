import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/helper/android_background.dart';
import 'package:whisper/helper/app_update.dart';
import 'package:whisper/helper/desktop_startup.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/notification.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/main.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/page/appList.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/notification_app_registry.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_dialogs.dart';
import 'package:whisper/widget/glass_bottom_sheet.dart';
import 'package:whisper/widget/glass_dialog.dart';
import 'package:whisper/widget/glass_settings_slider.dart';

typedef SettingsPresentationLoader = Future<SettingsPresentation> Function();

enum SettingsOperationKind {
  startupLoad,
  startupUpdate,
  notificationUpdate,
  notificationRestore,
  notificationRead,
  updateCheck,
  updateInstall,
}

void _logSettingsFailure(SettingsOperationKind kind, Object error) {
  privacyLog.event(PrivacyEvent.settingsOperation, <PrivacyField, Object>{
    PrivacyField.kind: kind,
    PrivacyField.success: false,
    PrivacyField.errorType: privacyLog.errorType(error),
  });
}

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
    this.clipboardAutoSync = false,
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
  final bool clipboardAutoSync;
  final bool isAndroid;
  final bool isDesktop;
  final bool isMobile;
  final int notificationAppCount;
}

class SettingsSectionSurface extends StatelessWidget {
  const SettingsSectionSurface({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return WhisperGlassSurface(
      borderRadius: BorderRadius.circular(14),
      showTopHighlight: false,
      showShadow: false,
      neutral: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
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
    this.writeNotificationForwarding,
    this.readNotificationForwarding,
    this.syncNotificationForwardingListener,
    this.refreshNotificationRegistry,
    this.openNotificationApps,
    this.showMessage,
    this.updateManager,
    this.exitForUpdate,
    this.autoCheckForUpdates = true,
  });

  final SettingsPresentationLoader? presentationLoader;
  final Future<String?> Function()? changeDirectory;
  final Future<void> Function(String path)? openDirectory;
  final Future<void> Function(String nickname)? updateNickname;
  final Future<void> Function(int port)? updateServerPort;
  final Future<void> Function(bool enabled)? updateNotificationForwarding;
  final Future<void> Function(bool enabled)? writeNotificationForwarding;
  final Future<bool> Function()? readNotificationForwarding;
  final Future<void> Function(bool enabled)? syncNotificationForwardingListener;
  final Future<void> Function()? refreshNotificationRegistry;
  final Future<void> Function()? openNotificationApps;
  final void Function(String message)? showMessage;
  final AppUpdateManager? updateManager;
  final Future<void> Function()? exitForUpdate;
  final bool autoCheckForUpdates;

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
  bool _clipboardAutoSync = false;
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
  bool _checkingForUpdates = false;
  bool _downloadingUpdate = false;
  double _updateDownloadProgress = 0;
  AppUpdateCheckResult? _updateResult;
  int _presentationLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  AppUpdateManager get _updateManager =>
      widget.updateManager ?? AppUpdateService.shared;

  Future<void> _initialize() async {
    await _refreshDevice(showLoading: true);
    if (widget.autoCheckForUpdates &&
        (widget.presentationLoader == null || widget.updateManager != null)) {
      unawaited(_checkForUpdates(silent: true));
    }
  }

  Future<bool> _loadLaunchAtStartup() async {
    if (!isDesktop()) {
      return false;
    }
    try {
      return await DesktopStartupManager().isEnabled();
    } catch (error) {
      _logSettingsFailure(SettingsOperationKind.startupLoad, error);
      return false;
    }
  }

  Future<SettingsPresentation> _loadDefaultPresentation() async {
    final temp = await LocalSetting().instance();
    final path = await downloadDir();
    final packageInfo = await PackageInfo.fromPlatform();
    final closeToTray = await LocalSetting().isClose2Tray();
    final copyVerify = await LocalSetting().copyVerify();
    var listenAndroid = await LocalSetting().isListenAndroid();
    if (Platform.isAndroid && listenAndroid) {
      final hasListenerAccess =
          await hasAndroidNotificationListenerPermission();
      if (!hasListenerAccess) {
        listenAndroid = false;
        await LocalSetting().setAndroidListen(false);
      }
    }
    final ignoreAndroid = await LocalSetting().ignoreAndroidNotification();
    final autoConnect = await LocalSetting().autoConnectEnabled();
    final clipboardAutoSync = await LocalSetting().clipboardAutoSync();
    final launchAtStartup = await _loadLaunchAtStartup();
    final androidBackgroundKeepAlive = await LocalSetting()
        .androidBackgroundKeepAlive();
    final audioSharePlaybackGain = await LocalSetting()
        .audioSharePlaybackGain();
    final remoteInputScrollMultiplier = await LocalSetting()
        .remoteInputScrollMultiplier();
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
      clipboardAutoSync: clipboardAutoSync,
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

  Future<void> _refreshDevice({bool showLoading = false}) async {
    final generation = ++_presentationLoadGeneration;
    if (mounted && showLoading) {
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
        _clipboardAutoSync = presentation.clipboardAutoSync;
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
    final horizontalPagePadding = _isMobilePlatform ? 10.0 : 14.0;

    return Scaffold(
      backgroundColor: palette.surfaceCanvas,
      appBar: AppBar(
        backgroundColor: palette.surfaceCanvas,
        leading: MediaQuery.withNoTextScaling(
          child: CupertinoNavigationBarBackButton(
            previousPageTitle: '',
            onPressed: () => Navigator.of(context).pop(),
            color: colorScheme.onSurface,
          ),
        ),
        title: Text(
          l10n.setting,
          style: TextStyle(color: colorScheme.onSurface),
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: WhisperUi.settingsMaxWidth,
            ),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                horizontalPagePadding,
                12,
                horizontalPagePadding,
                16,
              ),
              children: [
                if (_isLoading)
                  const SizedBox(
                    height: 240,
                    child: Center(child: CupertinoActivityIndicator()),
                  )
                else if (_loadFailed)
                  SizedBox(
                    height: 240,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(l10n.settingsLoadFailedTitle),
                          CupertinoButton(
                            onPressed: () => _refreshDevice(showLoading: true),
                            child: Text(l10n.retry),
                          ),
                        ],
                      ),
                    ),
                  )
                else ...<Widget>[
                  _buildSettingsSection(
                    l10n.settingsSectionDeviceAppearance,
                    l10n.settingsSectionDeviceAppearanceDesc,
                    [
                      _buildSettingItem(
                        l10n.themeMode,
                        Icon(
                          Icons.dark_mode,
                          size: 20,
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.systemGrey,
                        ),
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
                            await WsSvrManager().setAutoConnectPolicy(value);
                            if (!mounted) {
                              return;
                            }
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
                                  await DesktopStartupManager().setEnabled(
                                    value,
                                  );
                                } catch (error) {
                                  _logSettingsFailure(
                                    SettingsOperationKind.startupUpdate,
                                    error,
                                  );
                                  if (mounted) {
                                    setState(() {
                                      _launchAtStartup = previous;
                                    });
                                  }
                                  showAppToast(
                                    l10n.launchAtStartupFailed(
                                      l10n.connectFailed,
                                    ),
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
                        l10n.clipboardAutoSync,
                        Icon(
                          Icons.sync_alt_rounded,
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.systemGrey,
                        ),
                        desc: l10n.clipboardAutoSyncDesc,
                        trailing: CupertinoSwitch(
                          value: _clipboardAutoSync,
                          onChanged: (bool value) async {
                            await LocalSetting().updateClipboardAutoSync(value);
                            if (mounted) {
                              setState(() => _clipboardAutoSync = value);
                            }
                          },
                        ),
                      ),
                      _buildSettingItem(
                        l10n.audioSharePlaybackGainSetting(
                          _audioSharePlaybackGainLabel(_audioSharePlaybackGain),
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
                              await AndroidBackgroundKeepAliveCoordinator.shared
                                  .setEnabled(
                                    value,
                                    notification: AndroidKeepAliveNotification(
                                      title: l10n
                                          .androidBackgroundKeepAliveActiveTitle,
                                      description: l10n
                                          .androidBackgroundKeepAliveActiveDesc,
                                    ),
                                  );
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
                        if (_listenAndroid)
                          _buildSettingItem(
                            l10n.notificationApps,
                            Icon(
                              Icons.apps_rounded,
                              color: isDark
                                  ? Colors.grey[400]
                                  : CupertinoColors.systemGrey,
                            ),
                            desc: l10n.notificationAppsSelected(
                              _notificationAppCount,
                            ),
                            enabled: !_notificationForwardingBusy,
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
                    ],
                  ),
                  _buildSettingsSection(
                    l10n.settingsSectionAbout,
                    l10n.settingsSectionAboutDesc,
                    [
                      _buildSettingItem(
                        l10n.checkForUpdates,
                        _buildUpdateLeading(isDark),
                        desc: _updateStatusLabel(l10n),
                        subtitle: _buildUpdateStatus(l10n),
                        enabled: !_checkingForUpdates && !_downloadingUpdate,
                        onTap: _handleUpdateTap,
                        trailing: _buildUpdateTrailing(palette),
                      ),
                      _buildSettingItem(
                        l10n.aboutWhisper,
                        Icon(
                          Icons.info_outline_rounded,
                          color: isDark
                              ? Colors.grey[400]
                              : CupertinoColors.systemGrey,
                        ),
                        desc: l10n.aboutWhisperDescription,
                        onTap: () => _showAboutDialog(l10n, locale),
                        trailing: Icon(
                          Icons.arrow_forward_ios,
                          size: 14,
                          color: palette.textMuted,
                        ),
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

  String _updateStatusLabel(AppLocalizations l10n) {
    if (_downloadingUpdate) {
      return l10n.downloadingUpdate((_updateDownloadProgress * 100).round());
    }
    if (_checkingForUpdates) {
      return l10n.checkingForUpdates;
    }
    final release = _updateResult?.release;
    if (_updateResult?.hasUpdate == true && release != null) {
      return l10n.updateAvailableVersion(release.version);
    }
    return l10n.currentVersion(_version);
  }

  Widget _buildUpdateStatus(AppLocalizations l10n) {
    final label = _updateStatusLabel(l10n);
    if (_updateResult?.hasUpdate != true ||
        _checkingForUpdates ||
        _downloadingUpdate) {
      return Text(label, softWrap: true);
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(label, softWrap: true),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: DecoratedBox(
              key: const ValueKey<String>('update-available-badge'),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.error,
              ),
              child: const SizedBox.square(dimension: 7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateTrailing(WhisperPalette palette) {
    if (_checkingForUpdates || _downloadingUpdate) {
      final progress = _downloadingUpdate
          ? _updateDownloadProgress.clamp(0.0, 1.0)
          : null;
      return SizedBox.square(
        dimension: 22,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: progress ?? 0),
          duration: const Duration(milliseconds: 180),
          builder: (context, value, child) => CircularProgressIndicator(
            key: const ValueKey<String>('update-progress-indicator'),
            value: progress == null ? null : value,
            strokeWidth: 2.2,
            strokeCap: StrokeCap.round,
            color: Theme.of(context).colorScheme.primary,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.12),
          ),
        ),
      );
    }
    if (_updateResult?.hasUpdate == true) {
      return const SizedBox.shrink();
    }
    return Icon(Icons.arrow_forward_ios, size: 14, color: palette.textMuted);
  }

  Widget _buildUpdateLeading(bool isDark) {
    final hasUpdate = _updateResult?.hasUpdate == true;
    return Icon(
      hasUpdate ? Icons.system_update_rounded : Icons.update_rounded,
      color: isDark ? Colors.grey[400] : CupertinoColors.systemGrey,
    );
  }

  Future<void> _handleUpdateTap() async {
    final result = _updateResult?.hasUpdate == true
        ? _updateResult
        : await _checkForUpdates(silent: false, force: true);
    if (!mounted || result?.hasUpdate != true || result?.release == null) {
      return;
    }
    await _showUpdateAvailableDialog(result!.release!);
  }

  Future<AppUpdateCheckResult?> _checkForUpdates({
    required bool silent,
    bool force = false,
  }) async {
    if (_checkingForUpdates || _downloadingUpdate || _version.isEmpty) {
      return _updateResult;
    }
    setState(() {
      _checkingForUpdates = true;
    });
    try {
      final result = await _updateManager.checkForUpdate(
        currentVersion: _version,
        force: force,
      );
      if (!mounted) {
        return result;
      }
      setState(() {
        _checkingForUpdates = false;
        _updateResult = result;
      });
      if (!silent && !result.hasUpdate) {
        showAppToast(AppLocalizations.of(context)!.updateUpToDate);
      }
      return result;
    } catch (error) {
      _logSettingsFailure(SettingsOperationKind.updateCheck, error);
      if (!mounted) {
        return null;
      }
      setState(() {
        _checkingForUpdates = false;
      });
      if (!silent) {
        showAppToast(AppLocalizations.of(context)!.updateCheckFailed);
      }
      return null;
    }
  }

  Future<void> _showUpdateAvailableDialog(AppUpdateRelease release) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed =
        await showWhisperDialog<bool>(
          context,
          builder: (dialogContext) {
            final notes = release.notes.trim();
            return WhisperGlassDialog(
              constraints: const BoxConstraints(
                minWidth: 300,
                maxWidth: 500,
                maxHeight: 680,
              ),
              title: Text(
                l10n.updateAvailableTitle(release.version),
                style: Theme.of(
                  dialogContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 440,
                  maxHeight: 320,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(l10n.updateAvailableBody(_version, release.version)),
                      if (notes.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 14),
                        Text(
                          notes.length > 2000
                              ? '${notes.substring(0, 2000)}…'
                              : notes,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                WhisperDialogButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  label: l10n.cancel,
                ),
                WhisperDialogButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  label: release.asset == null
                      ? l10n.viewRelease
                      : l10n.downloadAndInstallUpdate,
                  prominent: true,
                ),
              ],
            );
          },
        ) ??
        false;
    if (!confirmed || !mounted) {
      return;
    }
    if (release.asset == null) {
      await _launchInBrowser(release.releaseUrl);
      return;
    }
    await _downloadAndInstallUpdate(release);
  }

  Future<void> _downloadAndInstallUpdate(AppUpdateRelease release) async {
    setState(() {
      _downloadingUpdate = true;
      _updateDownloadProgress = 0;
    });
    try {
      final download = await _updateManager.downloadUpdate(
        release,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _updateDownloadProgress = progress;
          });
        },
      );
      final disposition = await _updateManager.openInstaller(download);
      if (!mounted) {
        return;
      }
      setState(() {
        _downloadingUpdate = false;
      });
      if (disposition == AppUpdateInstallDisposition.exitApplication &&
          widget.exitForUpdate != null) {
        await widget.exitForUpdate!();
        return;
      }
      showAppToast(AppLocalizations.of(context)!.updateInstallerOpened);
    } catch (error) {
      _logSettingsFailure(SettingsOperationKind.updateInstall, error);
      if (!mounted) {
        return;
      }
      setState(() {
        _downloadingUpdate = false;
      });
      showAppToast(AppLocalizations.of(context)!.updateInstallFailed);
    }
  }

  void _showAboutDialog(AppLocalizations l10n, Locale locale) {
    _showCompactAboutDialog(l10n, locale);
  }

  void _showCompactAboutDialog(AppLocalizations l10n, Locale locale) {
    showWhisperDialog<void>(
      context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).colorScheme;
        final materialL10n = MaterialLocalizations.of(dialogContext);
        return WhisperGlassDialog(
          key: const ValueKey<String>('compact-about-dialog'),
          constraints: const BoxConstraints(
            minWidth: 300,
            maxWidth: 440,
            maxHeight: 680,
          ),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          titlePadding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
          contentPadding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
          actionsPadding: const EdgeInsets.only(top: 12),
          title: Row(
            children: <Widget>[
              _buildAboutIcon(44),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Whisper',
                      style: Theme.of(dialogContext).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.currentVersion(_version),
                      style: Theme.of(dialogContext).textTheme.bodyMedium
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(l10n.aboutWhisperDescription),
                  const SizedBox(height: 10),
                  Text(
                    'Copyright © 2026 lawnvi',
                    style: Theme.of(dialogContext).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  _buildAboutLink(
                    label: l10n.officialWebsite,
                    icon: Icons.language_rounded,
                    onPressed: () => _launchInBrowser(
                      Uri.https(
                        'whisper.127014.xyz',
                        '/${locale.languageCode}',
                      ),
                    ),
                  ),
                  _buildAboutLink(
                    label: l10n.sourceCode,
                    icon: Icons.code_rounded,
                    onPressed: () => _launchInBrowser(
                      Uri.https('github.com', '/lawnvi/whisper'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            WhisperDialogButton(
              onPressed: () => showLicensePage(
                context: dialogContext,
                applicationName: 'Whisper',
                applicationVersion: l10n.currentVersion(_version),
                applicationIcon: _buildAboutIcon(48),
                applicationLegalese: 'Copyright © 2026 lawnvi',
              ),
              label: materialL10n.viewLicensesButtonLabel,
            ),
            WhisperDialogButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: materialL10n.closeButtonLabel,
              prominent: true,
            ),
          ],
        );
      },
    );
  }

  Widget _buildAboutIcon(double size) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: Image.asset(
        'assets/app_icon_round.png',
        width: size,
        height: size,
      ),
    );
  }

  Widget _buildAboutLink({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return TextButton.icon(
      style: ButtonStyle(
        alignment: Alignment.centerLeft,
        minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 42)),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.pressed)) {
            return colors.primary.withValues(alpha: isDark ? 0.22 : 0.16);
          }
          if (states.contains(WidgetState.hovered)) {
            return colors.primary.withValues(alpha: isDark ? 0.16 : 0.10);
          }
          if (states.contains(WidgetState.focused)) {
            return colors.primary.withValues(alpha: isDark ? 0.13 : 0.08);
          }
          return Colors.transparent;
        }),
        overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
        animationDuration: const Duration(milliseconds: 150),
        foregroundColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.pressed)) {
            return Color.lerp(colors.primary, colors.onSurface, 0.16)!;
          }
          return colors.primary;
        }),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
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
    } catch (error) {
      var trustedValue = previous;
      if (update == null) {
        _logSettingsFailure(SettingsOperationKind.notificationUpdate, error);
        trustedValue = await _restoreNotificationForwarding(previous);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _listenAndroid = trustedValue;
        _notificationForwardingBusy = false;
      });
      final message = AppLocalizations.of(
        context,
      )!.notificationForwardingUpdateFailed;
      final showMessage = widget.showMessage;
      if (showMessage != null) {
        showMessage(message);
      } else {
        showAppToast(message);
      }
    }
  }

  Future<void> _applyNotificationForwarding(bool enabled) async {
    final write =
        widget.writeNotificationForwarding ?? LocalSetting().setAndroidListen;
    final sync =
        widget.syncNotificationForwardingListener ??
        _syncAndroidNotificationListener;
    final refresh =
        widget.refreshNotificationRegistry ??
        NotificationAppRegistry.instance.refresh;
    if (enabled) {
      await sync(true);
      await write(true);
    } else {
      await write(false);
      await sync(false);
    }
    await refresh();
  }

  Future<bool> _restoreNotificationForwarding(bool previous) async {
    try {
      await _applyNotificationForwarding(previous);
    } catch (error) {
      _logSettingsFailure(SettingsOperationKind.notificationRestore, error);
    }
    try {
      final read =
          widget.readNotificationForwarding ?? LocalSetting().isListenAndroid;
      return await read();
    } catch (error) {
      _logSettingsFailure(SettingsOperationKind.notificationRead, error);
      return previous;
    }
  }

  Future<void> _syncAndroidNotificationListener(bool enabled) async {
    if (!Platform.isAndroid) {
      return;
    }
    if (enabled) {
      if (!await startAndroidListening()) {
        throw StateError('Notification listener permission was not granted');
      }
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
      MaterialPageRoute<void>(builder: (context) => const AppListScreen()),
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
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
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
    final l10n = AppLocalizations.of(context)!;
    unawaited(
      showWhisperGlassBottomSheet<void>(
        context,
        builder: (sheetContext) => WhisperGlassActionSheet(
          title: Text(l10n.selectThemeMode),
          actions: <Widget>[
            for (final option in <(ThemeMode, String)>[
              (ThemeMode.system, l10n.followSystem),
              (ThemeMode.light, l10n.lightMode),
              (ThemeMode.dark, l10n.darkMode),
            ])
              WhisperGlassActionSheetAction(
                label: option.$2,
                onPressed: () {
                  Navigator.pop(sheetContext);
                  unawaited(_updateThemeMode(option.$1));
                },
              ),
          ],
          cancelButton: WhisperGlassActionSheetAction(
            label: l10n.cancel,
            destructive: true,
            onPressed: () => Navigator.pop(sheetContext),
          ),
        ),
      ),
    );
  }

  void _showLanguageSheet() {
    final l10n = AppLocalizations.of(context)!;
    unawaited(
      showWhisperGlassBottomSheet<void>(
        context,
        builder: (sheetContext) => WhisperGlassActionSheet(
          title: Text(l10n.selectLanguage),
          actions: <Widget>[
            for (final locale in _supportedLocales)
              WhisperGlassActionSheetAction(
                label: _localeLabel(sheetContext, locale.languageCode),
                onPressed: () {
                  Navigator.pop(sheetContext);
                  MyApp.setLocale(context, locale);
                  unawaited(
                    LocalSetting().setLocalization(locale.languageCode),
                  );
                },
              ),
          ],
          cancelButton: WhisperGlassActionSheetAction(
            label: l10n.cancel,
            destructive: true,
            onPressed: () => Navigator.pop(sheetContext),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsSection(
    String title,
    String subtitle,
    List<Widget> children,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildSettingsSectionHeader(title),
          SettingsSectionSurface(children: children),
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
    Widget icon, {
    Widget? trailing,
    GestureTapCallback? onTap,
    String desc = '',
    Widget? subtitle,
    bool enabled = true,
    GestureTapCallback? onLongPress,
  }) {
    final toggle = trailing is CupertinoSwitch ? trailing : null;
    final activate =
        onTap ??
        (toggle?.onChanged == null
            ? null
            : () => toggle!.onChanged!.call(!toggle.value));
    final resolvedSubtitle =
        subtitle ?? (desc.isEmpty ? null : Text(desc, softWrap: true));
    final palette = context.whisperPalette;
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: desc.isEmpty ? title : '$title, $desc',
      button: activate != null,
      enabled: enabled && activate != null,
      toggled: toggle?.value,
      onTap: enabled ? activate : null,
      child: FocusableActionDetector(
        enabled: enabled && activate != null,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              activate?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: enabled ? activate : null,
          onLongPress: enabled ? onLongPress : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: icon is Icon
                        ? Icon(icon.icon, color: palette.textMuted)
                        : IconTheme.merge(
                            data: IconThemeData(color: palette.textMuted),
                            child: icon,
                          ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16.5,
                            color: colorScheme.onSurface,
                            fontWeight: Platform.isWindows
                                ? null
                                : FontWeight.w500,
                            fontFamily: Platform.isWindows
                                ? null
                                : 'SF Pro Display',
                          ),
                        ),
                        if (resolvedSubtitle != null) ...<Widget>[
                          const SizedBox(height: 4),
                          DefaultTextStyle(
                            style: TextStyle(
                              fontSize: 12.5,
                              color: palette.textMuted,
                              fontWeight: Platform.isWindows
                                  ? null
                                  : FontWeight.w400,
                              fontFamily: Platform.isWindows
                                  ? null
                                  : 'SF Pro Display',
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            child: resolvedSubtitle,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...<Widget>[
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: ExcludeFocus(
                        child: ExcludeSemantics(child: trailing),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSaveDirectoryItem(AppLocalizations l10n) {
    return _buildSettingItem(
      l10n.settingsSaveDirectory,
      const Icon(Icons.file_download_outlined),
      desc: _path,
      onTap: _pickSaveDir,
      onLongPress: _openSaveDirectory,
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
    return '${gain.toStringAsFixed(1)}×';
  }

  String _remoteInputScrollMultiplierLabel(double multiplier) {
    return '${multiplier.toStringAsFixed(1)}×';
  }

  Future<void> _showAudioSharePlaybackGainSheet() async {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    var selectedGain = _audioSharePlaybackGain;
    await showWhisperGlassBottomSheet<void>(
      context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return WhisperGlassBottomSheet(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.volume_up_rounded, color: colorScheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    l10n.audioSharePlaybackGainTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  WhisperSettingsSlider(
                    value: selectedGain,
                    min: 1,
                    max: 3,
                    divisions: 20,
                    valueLabel: _audioSharePlaybackGainLabel(selectedGain),
                    minLabel: _audioSharePlaybackGainLabel(1),
                    maxLabel: _audioSharePlaybackGainLabel(3),
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
                  const SizedBox(height: 12),
                  Text(
                    l10n.audioSharePlaybackGainDesc,
                    style: TextStyle(color: context.whisperPalette.textMuted),
                  ),
                ],
              ),
              actions: <Widget>[
                WhisperDialogButton(
                  label: l10n.confirm,
                  prominent: true,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
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
    await showWhisperGlassBottomSheet<void>(
      context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return WhisperGlassBottomSheet(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.mouse_rounded, color: colorScheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    l10n.remoteInputScrollMultiplierTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  WhisperSettingsSlider(
                    value: selectedMultiplier,
                    min: 0.5,
                    max: 3,
                    divisions: 25,
                    valueLabel: _remoteInputScrollMultiplierLabel(
                      selectedMultiplier,
                    ),
                    minLabel: _remoteInputScrollMultiplierLabel(0.5),
                    maxLabel: _remoteInputScrollMultiplierLabel(3),
                    anchorValue: 1,
                    anchorLabel: _remoteInputScrollMultiplierLabel(1),
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
                  const SizedBox(height: 12),
                  Text(
                    l10n.remoteInputScrollMultiplierDesc,
                    style: TextStyle(color: context.whisperPalette.textMuted),
                  ),
                ],
              ),
              actions: <Widget>[
                WhisperDialogButton(
                  label: l10n.confirm,
                  prominent: true,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
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
    this.deleteDevice,
  });

  final DeviceData device;
  final Future<DeviceData?> Function(String uid)? deviceLoader;
  final bool? isConnected;
  final Future<void> Function(String uid)? deleteDevice;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    final isConnected =
        widget.isConnected ?? WsSvrManager().isConnectedTo(device.uid);
    final horizontalPagePadding = isMobile() ? 10.0 : 14.0;

    return Scaffold(
      backgroundColor: palette.surfaceCanvas,
      appBar: AppBar(
        backgroundColor: palette.surfaceCanvas,
        leading: MediaQuery.withNoTextScaling(
          child: CupertinoNavigationBarBackButton(
            previousPageTitle: '',
            onPressed: () => Navigator.of(context).pop(),
            color: colorScheme.onSurface,
          ),
        ),
        title: Text(
          l10n.setting,
          style: TextStyle(color: colorScheme.onSurface),
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: WhisperUi.settingsMaxWidth,
            ),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                horizontalPagePadding,
                12,
                horizontalPagePadding,
                16,
              ),
              children: [
                _buildClientSettingsSection(
                  l10n.settingsSectionPermissionsSharing,
                  l10n.settingsSectionPermissionsSharingDesc,
                  [
                    _DeviceSettingTile(
                      title: l10n.trust,
                      icon: Icon(Icons.wifi_rounded, color: palette.textMuted),
                      trailing: CupertinoSwitch(
                        value: device.auth,
                        onChanged: (bool value) async {
                          await WsSvrManager().setPeerTrust(device.uid, value);
                          await ConnectionCoordinator().refreshTrustState();
                          _refreshDevice();
                        },
                      ),
                    ),
                    _DeviceSettingTile(
                      title: l10n.writeClipboard,
                      icon: Icon(Icons.copy, color: palette.textMuted),
                      trailing: CupertinoSwitch(
                        value: device.clipboard,
                        onChanged: (bool value) async {
                          await LocalDatabase().clipboardDevice(
                            device.uid,
                            value,
                          );
                          _refreshDevice();
                        },
                      ),
                    ),
                  ],
                ),
                if (!isConnected)
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
                            await WsSvrManager().deletePeer(device.uid);
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: SettingsSectionSurface(children: children),
    );
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
    final trailingWidget = trailing;
    final CupertinoSwitch? toggle = trailingWidget is CupertinoSwitch
        ? trailingWidget
        : null;
    final activate =
        onTap ??
        (toggle?.onChanged == null
            ? null
            : () => toggle!.onChanged!.call(!toggle.value));

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: title,
      button: activate != null,
      enabled: activate != null,
      toggled: toggle?.value,
      onTap: activate,
      child: FocusableActionDetector(
        enabled: activate != null,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              activate?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: activate,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            constraints: const BoxConstraints(minHeight: 56),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                icon,
                const SizedBox(width: 12),
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
                if (trailingWidget != null) ...<Widget>[
                  const SizedBox(width: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ExcludeFocus(
                      child: ExcludeSemantics(child: trailingWidget),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
