import 'dart:async';
import 'dart:io';

import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_media_session.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sodium/sodium.dart';
import 'package:whisper/helper/connection_request_notifications.dart';
import 'package:whisper/helper/folder_transfer_stager.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/helper/transfer_notifications.dart';
import 'package:whisper/page/deviceList.dart';
import 'package:whisper/state/desktop_quick_send_inbox.dart';
import 'package:whisper/socket/aead_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:toastification/toastification.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:window_manager/window_manager.dart';

import 'helper/helper.dart';
import 'helper/notification.dart';
import 'helper/toast.dart';
import 'l10n/app_localizations.dart';

const MethodChannel _windowThemeChannel = MethodChannel(
  'com.vireen.whisper/window_theme',
);

enum AppDiagnosticKind { desktopWindowTheme }

void main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final sodium = await SodiumInit.init();
  WhisperAead.installNativeAcceleration(sodium);
  StreamingChecksum.installNativeSha256Acceleration();

  if (!isMobile()) {
    await DesktopQuickSendInbox.shared.initialize(initialArguments: arguments);
  }

  try {
    await const LegacyFolderTransferCleanup(
      activeTransferPathsProvider: recoverableFolderTransferPaths,
    ).cleanup();
  } catch (_) {
    // Staging cleanup is best-effort and must not prevent app startup.
  }

  if (isMobile()) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  if (!isMobile()) {
    // 必须加上这一行。
    await windowManager.ensureInitialized();
    var width = await LocalSetting().windowWidth();
    var height = await LocalSetting().windowHeight();
    final themeMode = await LocalSetting().themeMode();
    final brightness = _brightnessForThemeMode(themeMode);
    await _applyDesktopWindowTheme(themeMode);

    WindowOptions windowOptions = WindowOptions(
      size: Size(width, height),
      center: true,
      backgroundColor: brightness == Brightness.dark
          ? Colors.black
          : Colors.white,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      // WindowOptions applies native frame values after the first theme sync.
      await _applyDesktopWindowTheme(themeMode);
      if (Platform.isWindows) {
        await windowManager.setMinimizable(true);
      }
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // 初始化通知帮助类
  NotificationHelper notificationHelper = NotificationHelper();
  await notificationHelper.initialize();
  await ConnectionRequestNotifier().initialize(notificationHelper.plugin);
  TransferNotificationBridge().attach();
  AudioMediaSessionBridge().attach(
    coordinator: AudioGroupCoordinator.shared,
    platform: AudioPlatform.shared,
  );
  runApp(MyApp());
}

Brightness _brightnessForThemeMode(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.dark:
      return Brightness.dark;
    case ThemeMode.light:
      return Brightness.light;
    case ThemeMode.system:
      return WidgetsBinding.instance.platformDispatcher.platformBrightness;
  }
}

Future<void> _applyDesktopWindowTheme(ThemeMode mode) async {
  if (isMobile()) {
    return;
  }

  final brightness = _brightnessForThemeMode(mode);
  try {
    await windowManager.setBrightness(brightness);
    if (Platform.isWindows || Platform.isMacOS) {
      await _windowThemeChannel.invokeMethod<void>('setBrightness', {
        'brightness': brightness.name,
      });
    }
  } catch (error) {
    privacyLog.event(PrivacyEvent.localOperation, <PrivacyField, Object>{
      PrivacyField.kind: AppDiagnosticKind.desktopWindowTheme,
      PrivacyField.success: false,
      PrivacyField.errorType: privacyLog.errorType(error),
    });
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();

  static void setLocale(BuildContext context, Locale newLocale) {
    _MyAppState? state = context.findAncestorStateOfType<_MyAppState>();
    state?.setLocale(newLocale);
  }

  static void setTheme(BuildContext context, ThemeMode mode) {
    _MyAppState? state = context.findAncestorStateOfType<_MyAppState>();
    state?.setTheme(mode);
  }
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  Locale? _locale;
  ThemeMode _themeMode = ThemeMode.light;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadThemeMode();
    _loadLocale();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    if (_themeMode == ThemeMode.system) {
      unawaited(_applyDesktopWindowTheme(_themeMode));
    }
  }

  Future<void> _loadThemeMode() async {
    final mode = await LocalSetting().themeMode();
    if (!mounted) {
      return;
    }
    setState(() {
      _themeMode = mode;
    });
    unawaited(_applyDesktopWindowTheme(mode));
  }

  Future<void> _loadLocale() async {
    final languageCode = await LocalSetting().localization();
    const supportedLanguageCodes = {'en', 'zh', 'es'};
    final nextLocale = supportedLanguageCodes.contains(languageCode)
        ? Locale(languageCode)
        : null;
    if (!mounted) {
      return;
    }
    setState(() {
      _locale = nextLocale;
    });
  }

  void setLocale(Locale locale) {
    setState(() {
      _locale = locale;
    });
  }

  void setTheme(ThemeMode mode) {
    setState(() {
      _themeMode = mode;
    });
    unawaited(_applyDesktopWindowTheme(mode));
  }

  @override
  Widget build(BuildContext context) {
    return ToastificationWrapper(
      child: MaterialApp(
        title: 'Whisper',
        navigatorKey: appNavigatorKey,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: _themeMode,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: _locale,
        home: const DeviceListScreen(),
      ),
    );
  }
}
