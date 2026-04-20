import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/page/deviceList.dart';
import 'package:flutter/material.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:window_manager/window_manager.dart';

import 'helper/helper.dart';
import 'helper/notification.dart';
import 'l10n/app_localizations.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!isMobile()) {
    // 必须加上这一行。
    await windowManager.ensureInitialized();
    var width = await LocalSetting().windowWidth();
    var height = await LocalSetting().windowHeight();

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
  runApp(MyApp());
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

class _MyAppState extends State<MyApp> {
  Locale? _locale;
  ThemeMode _themeMode = ThemeMode.light;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    final mode = await LocalSetting().themeMode();
    setState(() {
      _themeMode = mode;
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
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Whisper',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: _themeMode,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', ''),
        Locale('zh', ''),
      ],
      locale: _locale,
      home: const DeviceListScreen(),
    );
  }
}
