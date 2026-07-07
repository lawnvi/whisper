import 'dart:async';
import 'dart:io';

import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_media_session.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:whisper/helper/connection_request_notifications.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/transfer_notifications.dart';
import 'package:whisper/page/deviceList.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:toastification/toastification.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:window_manager/window_manager.dart';

import 'helper/helper.dart';
import 'helper/notification.dart';
import 'helper/toast.dart';
import 'l10n/app_localizations.dart';

const MethodChannel _windowThemeChannel =
    MethodChannel('com.vireen.whisper/window_theme');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!isMobile()) {
    // 必须加上这一行。
    await windowManager.ensureInitialized();
    var width = await LocalSetting().windowWidth();
    var height = await LocalSetting().windowHeight();
    final themeMode = await LocalSetting().themeMode();
    await _applyDesktopWindowTheme(themeMode);

    WindowOptions windowOptions = WindowOptions(
      size: Size(width, height),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
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
    if (Platform.isWindows) {
      await _windowThemeChannel.invokeMethod<void>('setBrightness', {
        'brightness': brightness.name,
      });
    }
  } catch (error) {
    logger.i('Failed to apply desktop window theme: $error');
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
