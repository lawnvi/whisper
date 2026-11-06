import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show BoxWidthStyle, PlatformDispatcher;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:whisper/new_ui/shell/shell_diagnostics.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/helper/android_background.dart';
import 'package:whisper/helper/android_privacy_permission.dart';
import 'package:whisper/helper/app_update.dart';
import 'package:whisper/helper/desktop_startup.dart';
import 'package:whisper/helper/desktop_screenshot.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/notification.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/helper/windows_input_service.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/main.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/settings/settings_controls.dart';
import 'package:whisper/page/appList.dart';
import 'package:whisper/page/window_stream/android_service/android_service_page.dart';
import 'package:whisper/helper/macos_permissions.dart';
import 'package:whisper/page/remote_files/files_copy_island.dart';
import 'package:whisper/page/remote_files/files_icons.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/remote_files/mount/remote_mounts.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/share_links/share_link_store.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/notification_app_registry.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/whisper_window.dart';
import 'package:whisper/widget/app_dialogs.dart';
import 'package:whisper/cast_receiver/cast_receiver_manager.dart';
import 'package:whisper/widget/glass_dialog.dart';
import 'package:whisper/widget/island/island_overlay_setting.dart';
import 'package:whisper/widget/release_notes.dart';
import 'package:whisper/widget/windows_input_service_setting.dart';
import 'package:whisper/window_stream/linux/gnome_helper_tile.dart';
import 'package:whisper/window_stream/linux/gnome_shell_helper.dart';
import 'package:whisper/window_stream/remote/window_stream_host.dart';
import 'package:whisper/new_ui/shell/shell_touch.dart' show shellPageShowsBack;
import 'package:whisper/helper/screenshot_shortcut.dart';

part '../new_ui/settings/settings_layout.dart';

/// How the settings are drawn. [classic] is the page of the old UI; the other
/// two are docs/design/surfaces.md「设置」.
enum SettingsLayout { panel, page }

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
    this.isMacOS = false,
    this.languageCode,
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

  /// Shows the permissions macOS asks about. Only the new layouts read it.
  final bool isMacOS;

  /// The language picked here; null follows the system.
  final String? languageCode;
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
      // These cards cover a solid page, so backdrop sampling adds no detail
      // and repaints every visible group throughout the iOS slide transition.
      blurBackground: false,
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
    this.windowsInputService,
    this.layout = SettingsLayout.page,
    this.openPairing,
    this.openShareLinks,
    this.macPermissions,
    this.gnomeHelper,
    this.screenshotController,
    this.shareLinks,
    this.readIslandOverlay,
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
  final WindowsInputServiceController? windowsInputService;
  final SettingsLayout layout;

  /// The two rows at the top of the phone's page.
  final VoidCallback? openPairing, openShareLinks;

  final MacPermissions? macPermissions;
  final GnomeShellHelperController? gnomeHelper;
  final DesktopScreenshotController? screenshotController;
  final ShareLinkStore? shareLinks;
  final Future<({bool needed, bool allowed})> Function()? readIslandOverlay;

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
  Animation<double>? _openingAnimation;
  Completer<void>? _openingTransition;
  int _panelSection = 0;
  bool _pageScrolled = false;
  bool _isMacPlatform = false;
  String? _pickedLanguage;

  /// For the layout in the part file, which is an extension and so cannot call
  /// the protected method itself.
  void _update(VoidCallback change) => setState(change);

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
    // Listening is what makes it ask the system, which only macOS can answer.
    if (_watchesMacPermissions) {
      _macPermissions.addListener(_onMacPermissions);
    }
  }

  MacPermissions get _macPermissions =>
      widget.macPermissions ?? MacPermissions.shared;

  bool get _watchesMacPermissions =>
      widget.macPermissions != null || MacPermissions.supported;

  void _onMacPermissions() {
    if (mounted) setState(() {});
  }

  AppUpdateManager get _updateManager =>
      widget.updateManager ?? AppUpdateService.shared;

  WindowsInputServiceController get _windowsInputService =>
      widget.windowsInputService ?? WindowsInputServiceController.shared;

  void _handleOpeningTransition(AnimationStatus status) {
    if (status == AnimationStatus.forward) return;
    _openingAnimation?.removeStatusListener(_handleOpeningTransition);
    _openingAnimation = null;
    if (_openingTransition?.isCompleted == false) {
      _openingTransition!.complete();
    }
  }

  @override
  void dispose() {
    if (_watchesMacPermissions) {
      _macPermissions.removeListener(_onMacPermissions);
    }
    _handleOpeningTransition(AnimationStatus.dismissed);
    super.dispose();
  }

  Future<void> _initialize() async {
    unawaited(_windowsInputService.refresh());
    if (widget.layout == SettingsLayout.page) {
      unawaited(_shareLinks.initialize());
    }
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
      isMacOS: MacPermissions.supported,
      languageCode: await LocalSetting().pickedLocalization(),
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
      // Load data during the push, then lay out the settings after the slide
      // finishes instead of replacing the whole list halfway through a frame.
      // The new layouts open on a spring and would sit empty for all of it;
      // their data is there within the first few frames.

      if (!mounted || generation != _presentationLoadGeneration) return;
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
        _isMacPlatform = presentation.isMacOS;
        _pickedLanguage = presentation.languageCode;
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
    return _buildRedesigned(context);
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
        showAppToast(
          AppLocalizations.of(context)!.updateUpToDate,
          tone: AppToastTone.success,
        );
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
        showAppToast(
          AppLocalizations.of(context)!.updateCheckFailed,
          tone: AppToastTone.error,
        );
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
                        ReleaseNotes(
                          markdown: notes,
                          onOpen: (uri) => unawaited(
                            launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            ),
                          ),
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
    AppUpdateDownload? downloaded;
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
      downloaded = download;
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
      final l10n = AppLocalizations.of(context)!;
      final installed = disposition == AppUpdateInstallDisposition.installed;
      showAppToast(
        installed ? l10n.updateInstalledRestart : l10n.updateInstallerOpened,
        tone: installed ? AppToastTone.success : AppToastTone.info,
      );
    } catch (error) {
      _logSettingsFailure(SettingsOperationKind.updateInstall, error);
      if (!mounted) {
        return;
      }
      setState(() {
        _downloadingUpdate = false;
      });
      final l10n = AppLocalizations.of(context)!;
      if (downloaded != null) {
        await showWhisperDialog<void>(
          context,
          builder: (dialogContext) => WhisperGlassDialog(
            title: Text(l10n.updateInstallFailed),
            content: SelectableText(
              l10n.updatePackageSaved(downloaded!.file.path),
              selectionWidthStyle: BoxWidthStyle.tight,
            ),
            actions: [
              WhisperDialogButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                label: MaterialLocalizations.of(dialogContext).closeButtonLabel,
              ),
            ],
          ),
        );
      } else {
        showAppToast(l10n.updateInstallFailed, tone: AppToastTone.error);
      }
    }
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
        showAppToast(message, tone: AppToastTone.error);
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

  Future<void> _commitNickname(String nickname) async {
    final updateNickname = widget.updateNickname;
    if (updateNickname != null) {
      await updateNickname(nickname);
    } else {
      await LocalSetting().updateNickname(nickname);
      await CastReceiverManager.shared.updateName();
      await WsSvrManager().broadcastLocalProfileUpdate();
    }
    await _refreshDevice();
  }

  /// Saved here. Whoever opened the settings refreshes when they close, and
  /// that restarts the service on the new port.
  Future<void> _commitServerPort(int port) async {
    final updateServerPort = widget.updateServerPort;
    if (updateServerPort != null) {
      await updateServerPort(port);
    } else {
      await LocalSetting().updatePort(port);
    }
    await _refreshDevice();
  }

  Future<void> _setAutoConnect(bool value) async {
    await WsSvrManager().setAutoConnectPolicy(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _autoConnect = value;
    });
  }

  Future<void> _setLaunchAtStartup(bool value) async {
    final l10n = AppLocalizations.of(context)!;
    final previous = _launchAtStartup;
    setState(() {
      _launchAtStartup = value;
    });
    try {
      await DesktopStartupManager().setEnabled(value);
    } catch (error) {
      _logSettingsFailure(SettingsOperationKind.startupUpdate, error);
      if (mounted) {
        setState(() {
          _launchAtStartup = previous;
        });
      }
      showAppToast(l10n.launchAtStartupFailed, tone: AppToastTone.error);
    }
  }

  Future<void> _setClose2Tray(bool value) async {
    await LocalSetting().updateClose2Tray(value);
    setState(() {
      _close2tray = value;
    });
  }

  Future<void> _setWindowSharing(bool value) async {
    await WindowStreamHost.shared.setSharingAllowed(value);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _setClipboard(bool value) async {
    await LocalSetting().updateClipboard(value);
    await _refreshDevice();
  }

  Future<void> _setClipboardAutoSync(bool value) async {
    await LocalSetting().updateClipboardAutoSync(value);
    if (mounted) {
      setState(() => _clipboardAutoSync = value);
    }
  }

  Future<void> _setBackgroundKeepAlive(bool value) async {
    final l10n = AppLocalizations.of(context)!;
    await LocalSetting().setAndroidBackgroundKeepAlive(value);
    setState(() {
      _androidBackgroundKeepAlive = value;
    });
    await AndroidBackgroundKeepAliveCoordinator.shared.setEnabled(
      value,
      notification: AndroidKeepAliveNotification(
        title: l10n.androidBackgroundKeepAliveActiveTitle,
        description: l10n.androidBackgroundKeepAliveActiveDesc,
      ),
    );
  }

  Future<void> _setIgnoreAndroid(bool value) async {
    await LocalSetting().setAndroidNotification(value);
    setState(() {
      _ignoreAndroid = value;
    });
  }

  Future<void> _setCopyVerifyCode(bool value) async {
    await LocalSetting().setCopyVerify(value);
    setState(() {
      _copyVerifyCode = value;
    });
  }

  Future<void> _commitScrollMultiplier(double value) async {
    await LocalSetting().setRemoteInputScrollMultiplier(value);
    RemoteInputCoordinator.shared.updateScrollMultiplier(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _remoteInputScrollMultiplier = value;
    });
  }

  Future<void> _commitPlaybackGain(double value) async {
    await LocalSetting().setAudioSharePlaybackGain(value);
    AudioShareCoordinator.shared.updatePlaybackGain(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _audioSharePlaybackGain = value;
    });
  }

  Future<void> _pickSaveDir() async {
    final changeDirectory = widget.changeDirectory;
    final selectDir = changeDirectory != null
        ? await changeDirectory()
        : await FilePicker.getDirectoryPath();
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
}

/// Something this device can do, as a row on its page (流转, 文件, …).
class DeviceFeature {
  const DeviceFeature({
    required this.icon,
    required this.title,
    required this.onOpen,
    this.unavailable,
  });

  final IconData icon;
  final String title;
  final VoidCallback onOpen;

  /// Why it cannot be used now (not connected, say); the row is dimmed.
  final String? unavailable;
}

/// A device's own page: what it can do (流转, 文件, 设备控制, 搜索) on
/// top, then how it is shared with, then removing it.
class ClientSettingsScreen extends StatefulWidget {
  const ClientSettingsScreen({
    super.key,
    required this.device,
    this.deviceLoader,
    this.isConnected,
    this.deleteDevice,
    this.onSearchHistory,
    this.features = const [],
  });

  final DeviceData device;
  final Future<DeviceData?> Function(String uid)? deviceLoader;
  final bool? isConnected;
  final Future<void> Function(String uid)? deleteDevice;
  final VoidCallback? onSearchHistory;
  final List<DeviceFeature> features;

  @override
  State<ClientSettingsScreen> createState() => _ClientSettingsScreenState();
}

class _ClientSettingsScreenState extends State<ClientSettingsScreen> {
  late DeviceData device;

  /// Whether this device browses my files without asking; null until read.
  bool? _filesAlwaysAllowed;

  /// Whether it may also change them ("允许修改我的文件"); null until read.
  bool? _filesChangesAllowed;

  @override
  void initState() {
    super.initState();
    device = widget.device;
    _refreshDevice();
    unawaited(_loadFilesAlwaysAllowed());
  }

  Future<void> _loadFilesAlwaysAllowed() async {
    final permissions = FileBrowseHost.shared.permissions;
    final allowed = await permissions.isAlways(device.uid);
    final readOnly = await permissions.isReadOnly(device.uid);
    if (mounted) {
      setState(() {
        _filesAlwaysAllowed = allowed;
        _filesChangesAllowed = !readOnly;
      });
    }
  }

  Future<void> _setFilesChangesAllowed(bool allowed) async {
    setState(() => _filesChangesAllowed = allowed);
    await FileBrowseHost.shared.setReadOnly(device.uid, !allowed);
  }

  Future<void> _setFilesAlwaysAllowed(bool allowed) async {
    final host = FileBrowseHost.shared;
    if (allowed) {
      await host.permissions.setAlways(device.uid, true);
    } else {
      await host.revokeAlways(device.uid);
    }
    if (mounted) {
      setState(() => _filesAlwaysAllowed = allowed);
    }
  }

  /// "挂载到本机": on mounts it now (opening it in the file manager) when it
  /// is connected, else once it connects.
  Future<void> _setMountHere(bool wanted) async {
    final l10n = AppLocalizations.of(context)!;
    final app = systemFileManagerName(l10n);
    try {
      final mount = await RemoteMounts.shared.setWanted(
        device.uid,
        device.name,
        wanted,
      );
      if (mount != null) {
        await openDir(mount.path);
      }
    } on MountFailed catch (failed) {
      if (failed.failure != MountFailure.offline) {
        showAppToast(
          mountFailureText(l10n, failed.failure, device.name, app),
          tone: AppToastTone.error,
        );
      }
    }
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
    final palette = context.wc;
    final l10n = AppLocalizations.of(context)!;
    final isConnected =
        widget.isConnected ?? WsSvrManager().isConnectedTo(device.uid);
    final horizontalPagePadding = isMobile() ? 10.0 : 14.0;

    final page = Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        backgroundColor: palette.canvas,
        leading: MediaQuery.withNoTextScaling(
          child: CupertinoNavigationBarBackButton(
            previousPageTitle: '',
            onPressed: () => Navigator.of(context).pop(),
            color: colorScheme.onSurface,
          ),
        ),
        title: Text(
          device.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
                if (widget.features.isNotEmpty ||
                    widget.onSearchHistory != null)
                  _buildClientSettingsSection(l10n.deviceFeaturesSection, '', [
                    for (final feature in widget.features)
                      _featureTile(feature, palette),
                    if (widget.onSearchHistory != null)
                      _DeviceSettingTile(
                        title: l10n.transferAssistantTitle,
                        icon: Icon(Icons.search_rounded, color: palette.ink2),
                        trailing: Icon(
                          Icons.chevron_right_rounded,
                          color: palette.ink2,
                        ),
                        onTap: widget.onSearchHistory,
                      ),
                  ]),
                _buildClientSettingsSection(
                  l10n.settingsSectionPermissionsSharing,
                  l10n.settingsSectionPermissionsSharingDesc,
                  [
                    _DeviceSettingTile(
                      title: l10n.trust,
                      icon: Icon(Icons.wifi_rounded, color: palette.ink2),
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
                      icon: Icon(Icons.copy, color: palette.ink2),
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
                    if (_filesAlwaysAllowed case final allowed?)
                      _DeviceSettingTile(
                        title: l10n.deviceFilesAlwaysAllowed,
                        icon: Icon(Icons.folder_outlined, color: palette.ink2),
                        trailing: CupertinoSwitch(
                          value: allowed,
                          onChanged: (value) =>
                              unawaited(_setFilesAlwaysAllowed(value)),
                        ),
                      ),
                    if (_filesChangesAllowed case final allowed?)
                      _DeviceSettingTile(
                        title: l10n.deviceFilesAllowChanges,
                        icon: Icon(
                          Icons.edit_note_rounded,
                          color: palette.ink2,
                        ),
                        trailing: CupertinoSwitch(
                          value: allowed,
                          onChanged: (value) =>
                              unawaited(_setFilesChangesAllowed(value)),
                        ),
                      ),
                    if (RemoteMounts.supported)
                      ListenableBuilder(
                        listenable: RemoteMounts.shared,
                        builder: (context, _) => _DeviceSettingTile(
                          title: l10n.deviceMountHere,
                          icon: Icon(
                            Icons.drive_file_move_outline,
                            color: palette.ink2,
                          ),
                          trailing: RemoteMounts.shared.isMounting(device.uid)
                              ? const CupertinoActivityIndicator(radius: 9)
                              : CupertinoSwitch(
                                  value: RemoteMounts.shared.wants(device.uid),
                                  onChanged: (value) =>
                                      unawaited(_setMountHere(value)),
                                ),
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
                        icon: Icon(Icons.delete_rounded, color: context.wc.bad),
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
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: page,
    );
  }

  Widget _featureTile(DeviceFeature feature, WhisperColors palette) {
    final reason = feature.unavailable;
    return Opacity(
      opacity: reason == null ? 1 : 0.5,
      child: _DeviceSettingTile(
        title: feature.title,
        icon: Icon(feature.icon, color: palette.ink2),
        trailing: reason == null
            ? Icon(Icons.chevron_right_rounded, color: palette.ink2)
            : Text(reason, style: TextStyle(fontSize: 13, color: palette.ink2)),
        onTap: reason == null ? feature.onOpen : null,
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
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontSize: 16,
                      height: 1.5,
                      letterSpacing: 0,
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
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
