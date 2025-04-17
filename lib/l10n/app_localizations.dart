import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh')
  ];

  /// No description provided for @connectDeviceTitle.
  ///
  /// In zh, this message translates to:
  /// **'连接设备'**
  String get connectDeviceTitle;

  /// No description provided for @connectDeviceDesc.
  ///
  /// In zh, this message translates to:
  /// **'输入对方局域网地址与端口'**
  String get connectDeviceDesc;

  /// No description provided for @connectTo.
  ///
  /// In zh, this message translates to:
  /// **'连接到'**
  String get connectTo;

  /// No description provided for @connectRequest.
  ///
  /// In zh, this message translates to:
  /// **'连接请求'**
  String get connectRequest;

  /// 接入设备描述
  ///
  /// In zh, this message translates to:
  /// **'接入设备：{device}?'**
  String connectRequestDesc(String device);

  /// No description provided for @connect.
  ///
  /// In zh, this message translates to:
  /// **'连接'**
  String get connect;

  /// No description provided for @confirm.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get confirm;

  /// No description provided for @allow.
  ///
  /// In zh, this message translates to:
  /// **'同意'**
  String get allow;

  /// No description provided for @refuse.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get refuse;

  /// No description provided for @cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancel;

  /// No description provided for @setting.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get setting;

  /// No description provided for @sendTips.
  ///
  /// In zh, this message translates to:
  /// **'发点什么...'**
  String get sendTips;

  /// No description provided for @trust.
  ///
  /// In zh, this message translates to:
  /// **'自动接入'**
  String get trust;

  /// No description provided for @writeClipboard.
  ///
  /// In zh, this message translates to:
  /// **'写入剪切板'**
  String get writeClipboard;

  /// No description provided for @deleteDevice.
  ///
  /// In zh, this message translates to:
  /// **'删除设备'**
  String get deleteDevice;

  /// No description provided for @serverPort.
  ///
  /// In zh, this message translates to:
  /// **'服务端口 {port}'**
  String serverPort(Object port);

  /// No description provided for @serverPortTitle.
  ///
  /// In zh, this message translates to:
  /// **'服务端口'**
  String get serverPortTitle;

  /// No description provided for @trustNewDevice.
  ///
  /// In zh, this message translates to:
  /// **'自动通过新设备'**
  String get trustNewDevice;

  /// No description provided for @accessClipboard.
  ///
  /// In zh, this message translates to:
  /// **'允许访问剪切板'**
  String get accessClipboard;

  /// No description provided for @doubleClickRmMessage.
  ///
  /// In zh, this message translates to:
  /// **'双击消息删除'**
  String get doubleClickRmMessage;

  /// No description provided for @close2tray.
  ///
  /// In zh, this message translates to:
  /// **'关闭时隐藏到托盘'**
  String get close2tray;

  /// No description provided for @nickname.
  ///
  /// In zh, this message translates to:
  /// **'昵称'**
  String get nickname;

  /// No description provided for @nicknameDesc.
  ///
  /// In zh, this message translates to:
  /// **'请输入昵称'**
  String get nicknameDesc;

  /// No description provided for @port.
  ///
  /// In zh, this message translates to:
  /// **'服务端口'**
  String get port;

  /// No description provided for @portDesc.
  ///
  /// In zh, this message translates to:
  /// **'请输入服务端口：[1000, 65535]'**
  String get portDesc;

  /// No description provided for @timeoutTitle.
  ///
  /// In zh, this message translates to:
  /// **'连接超时'**
  String get timeoutTitle;

  /// No description provided for @disconnect.
  ///
  /// In zh, this message translates to:
  /// **'断开'**
  String get disconnect;

  /// No description provided for @keepConnect.
  ///
  /// In zh, this message translates to:
  /// **'保持'**
  String get keepConnect;

  /// No description provided for @menuShow.
  ///
  /// In zh, this message translates to:
  /// **'显示'**
  String get menuShow;

  /// No description provided for @menuHide.
  ///
  /// In zh, this message translates to:
  /// **'隐藏'**
  String get menuHide;

  /// No description provided for @menuClipboard.
  ///
  /// In zh, this message translates to:
  /// **'发送剪切板'**
  String get menuClipboard;

  /// No description provided for @menuSendFile.
  ///
  /// In zh, this message translates to:
  /// **'发送文件'**
  String get menuSendFile;

  /// No description provided for @exit.
  ///
  /// In zh, this message translates to:
  /// **'退出'**
  String get exit;

  /// No description provided for @delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get delete;

  /// No description provided for @deleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认删除'**
  String get deleteConfirm;

  /// No description provided for @warning.
  ///
  /// In zh, this message translates to:
  /// **'警告'**
  String get warning;

  /// No description provided for @deleteWarningText.
  ///
  /// In zh, this message translates to:
  /// **'连接正在使用，禁止快速删除'**
  String get deleteWarningText;

  /// No description provided for @close.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get close;

  /// 删除设备描述
  ///
  /// In zh, this message translates to:
  /// **'删除 {device}'**
  String deleteDeviceTitle(String device);

  /// No description provided for @deleteDeviceDesc.
  ///
  /// In zh, this message translates to:
  /// **'删除与此设备的所有消息，不可恢复'**
  String get deleteDeviceDesc;

  /// No description provided for @brokeConnectTitle.
  ///
  /// In zh, this message translates to:
  /// **'断开连接'**
  String get brokeConnectTitle;

  /// 断开设备描述
  ///
  /// In zh, this message translates to:
  /// **'断开 {device}'**
  String brokeConnectDesc(String device);

  /// No description provided for @connectFailed.
  ///
  /// In zh, this message translates to:
  /// **'连接失败'**
  String get connectFailed;

  /// No description provided for @deviceBusy.
  ///
  /// In zh, this message translates to:
  /// **'服务占线'**
  String get deviceBusy;

  /// No description provided for @startServerFailed.
  ///
  /// In zh, this message translates to:
  /// **'服务启动失败'**
  String get startServerFailed;

  /// No description provided for @deleteMessageTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除消息'**
  String get deleteMessageTitle;

  /// No description provided for @deleteMessageDesc.
  ///
  /// In zh, this message translates to:
  /// **'确定删除此消息吗？'**
  String get deleteMessageDesc;

  /// No description provided for @language.
  ///
  /// In zh, this message translates to:
  /// **'语言 {language}'**
  String language(Object language);

  /// No description provided for @pushNotification.
  ///
  /// In zh, this message translates to:
  /// **'推送安卓通知'**
  String get pushNotification;

  /// No description provided for @ignoreNotification.
  ///
  /// In zh, this message translates to:
  /// **'忽略安卓通知'**
  String get ignoreNotification;

  /// No description provided for @ftpService.
  ///
  /// In zh, this message translates to:
  /// **'FTP服务'**
  String get ftpService;

  /// No description provided for @back.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get back;

  /// No description provided for @selectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get selectAll;

  /// No description provided for @clearAll.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get clearAll;

  /// No description provided for @selectNotifyApp.
  ///
  /// In zh, this message translates to:
  /// **'监听APP通知'**
  String get selectNotifyApp;

  /// No description provided for @copyVerifyCode.
  ///
  /// In zh, this message translates to:
  /// **'验证码写入剪切板'**
  String get copyVerifyCode;

  /// No description provided for @open.
  ///
  /// In zh, this message translates to:
  /// **'打开'**
  String get open;

  /// No description provided for @openInFinder.
  ///
  /// In zh, this message translates to:
  /// **'在Finder中显示'**
  String get openInFinder;

  /// No description provided for @openInDir.
  ///
  /// In zh, this message translates to:
  /// **'所在文件夹'**
  String get openInDir;

  /// No description provided for @keepFile.
  ///
  /// In zh, this message translates to:
  /// **'保留文件'**
  String get keepFile;

  /// No description provided for @deleteFile.
  ///
  /// In zh, this message translates to:
  /// **'删除文件'**
  String get deleteFile;

  /// No description provided for @copyMessage.
  ///
  /// In zh, this message translates to:
  /// **'复制消息'**
  String get copyMessage;

  /// No description provided for @themeMode.
  ///
  /// In zh, this message translates to:
  /// **'主题模式'**
  String get themeMode;

  /// No description provided for @followSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get followSystem;

  /// No description provided for @lightMode.
  ///
  /// In zh, this message translates to:
  /// **'明亮'**
  String get lightMode;

  /// No description provided for @darkMode.
  ///
  /// In zh, this message translates to:
  /// **'暗黑'**
  String get darkMode;

  /// No description provided for @selectThemeMode.
  ///
  /// In zh, this message translates to:
  /// **'选择主题模式'**
  String get selectThemeMode;

  /// No description provided for @selectLanguage.
  ///
  /// In zh, this message translates to:
  /// **'选择语言'**
  String get selectLanguage;
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {


  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en': return AppLocalizationsEn();
    case 'zh': return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.'
  );
}
