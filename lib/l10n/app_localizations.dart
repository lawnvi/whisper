import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
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
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

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
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
    Locale('zh'),
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

  /// No description provided for @connectRequestNotificationBody.
  ///
  /// In zh, this message translates to:
  /// **'{name}({host})请求连接'**
  String connectRequestNotificationBody(String name, String host);

  /// No description provided for @connectRequestExpired.
  ///
  /// In zh, this message translates to:
  /// **'连接请求已过期'**
  String get connectRequestExpired;

  /// No description provided for @transferNotificationTitle.
  ///
  /// In zh, this message translates to:
  /// **'正在传输 {count} 个文件'**
  String transferNotificationTitle(int count);

  /// No description provided for @transferNotificationBodySending.
  ///
  /// In zh, this message translates to:
  /// **'发送中 {percent}% · {speed} · 剩余 {remaining}'**
  String transferNotificationBodySending(
    int percent,
    String speed,
    String remaining,
  );

  /// No description provided for @transferNotificationBodyReceiving.
  ///
  /// In zh, this message translates to:
  /// **'接收中 {percent}% · {speed} · 剩余 {remaining}'**
  String transferNotificationBodyReceiving(
    int percent,
    String speed,
    String remaining,
  );

  /// No description provided for @transferNotificationBodyMixed.
  ///
  /// In zh, this message translates to:
  /// **'收发中 {percent}% · {speed} · 剩余 {remaining}'**
  String transferNotificationBodyMixed(
    int percent,
    String speed,
    String remaining,
  );

  /// No description provided for @transferNotificationCompleted.
  ///
  /// In zh, this message translates to:
  /// **'传输完成 · {count} 个文件'**
  String transferNotificationCompleted(int count);

  /// No description provided for @transferNotificationInterrupted.
  ///
  /// In zh, this message translates to:
  /// **'传输已中断,回到应用可恢复'**
  String get transferNotificationInterrupted;

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

  /// No description provided for @retry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get retry;

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

  /// No description provided for @sendFiles.
  ///
  /// In zh, this message translates to:
  /// **'发送文件'**
  String get sendFiles;

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

  /// No description provided for @accessClipboard.
  ///
  /// In zh, this message translates to:
  /// **'允许访问剪切板'**
  String get accessClipboard;

  /// No description provided for @clipboardAutoSync.
  ///
  /// In zh, this message translates to:
  /// **'自动同步剪切板'**
  String get clipboardAutoSync;

  /// No description provided for @clipboardAutoSyncDesc.
  ///
  /// In zh, this message translates to:
  /// **'关闭时仅手动发送；开启后只同步到当前可信设备'**
  String get clipboardAutoSyncDesc;

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
  /// **'请输入 1001 到 65535 之间的端口'**
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

  /// No description provided for @filePickerOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开文件选择器'**
  String get filePickerOpenFailed;

  /// No description provided for @clipboardImageSendFailed.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板图片发送失败'**
  String get clipboardImageSendFailed;

  /// No description provided for @clipboardFilesSendFailed.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板文件发送失败'**
  String get clipboardFilesSendFailed;

  /// No description provided for @messageSendFailed.
  ///
  /// In zh, this message translates to:
  /// **'消息发送失败，请重试'**
  String get messageSendFailed;

  /// No description provided for @clipboardFilesCount.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, =1{1 个文件} other{{count} 个文件}}'**
  String clipboardFilesCount(num count);

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
  /// **'断开连接并删除与此设备的所有消息，不可恢复'**
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

  /// No description provided for @connectAlreadyInProgress.
  ///
  /// In zh, this message translates to:
  /// **'连接正在进行中'**
  String get connectAlreadyInProgress;

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

  /// No description provided for @selectMessages.
  ///
  /// In zh, this message translates to:
  /// **'多选'**
  String get selectMessages;

  /// No description provided for @selectedMessageCount.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 条'**
  String selectedMessageCount(int count);

  /// No description provided for @deleteSelectedMessagesTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除 {count} 条消息'**
  String deleteSelectedMessagesTitle(int count);

  /// No description provided for @deleteSelectedMessagesDesc.
  ///
  /// In zh, this message translates to:
  /// **'将删除所选聊天记录，本地文件会保留。'**
  String get deleteSelectedMessagesDesc;

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
  /// **'选择通知应用'**
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

  /// No description provided for @copyFile.
  ///
  /// In zh, this message translates to:
  /// **'复制文件'**
  String get copyFile;

  /// No description provided for @fileCopied.
  ///
  /// In zh, this message translates to:
  /// **'文件已复制'**
  String get fileCopied;

  /// No description provided for @fileCopyFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法复制文件'**
  String get fileCopyFailed;

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

  /// No description provided for @searchChats.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get searchChats;

  /// No description provided for @selectConversationPlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'选择一个设备开始对话'**
  String get selectConversationPlaceholder;

  /// No description provided for @connectedNow.
  ///
  /// In zh, this message translates to:
  /// **'当前已连接'**
  String get connectedNow;

  /// No description provided for @nearbyAvailable.
  ///
  /// In zh, this message translates to:
  /// **'附近可连接'**
  String get nearbyAvailable;

  /// No description provided for @noMessagesYet.
  ///
  /// In zh, this message translates to:
  /// **'还没有消息'**
  String get noMessagesYet;

  /// No description provided for @sharedFile.
  ///
  /// In zh, this message translates to:
  /// **'发送了一个文件'**
  String get sharedFile;

  /// No description provided for @connectToSend.
  ///
  /// In zh, this message translates to:
  /// **'连接后即可发送消息'**
  String get connectToSend;

  /// No description provided for @localeNameZhHans.
  ///
  /// In zh, this message translates to:
  /// **'简体中文'**
  String get localeNameZhHans;

  /// No description provided for @localeNameEnglish.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get localeNameEnglish;

  /// No description provided for @localeNameSpanish.
  ///
  /// In zh, this message translates to:
  /// **'Español'**
  String get localeNameSpanish;

  /// No description provided for @autoConnectTrustedDevices.
  ///
  /// In zh, this message translates to:
  /// **'自动连接互信设备'**
  String get autoConnectTrustedDevices;

  /// No description provided for @mutualTrustEnabled.
  ///
  /// In zh, this message translates to:
  /// **'双向互信已开启'**
  String get mutualTrustEnabled;

  /// No description provided for @mutualTrustNotEstablished.
  ///
  /// In zh, this message translates to:
  /// **'尚未形成双向互信'**
  String get mutualTrustNotEstablished;

  /// No description provided for @launchAtStartup.
  ///
  /// In zh, this message translates to:
  /// **'开机自启动'**
  String get launchAtStartup;

  /// No description provided for @launchAtStartupDesc.
  ///
  /// In zh, this message translates to:
  /// **'登录桌面后自动启动 Whisper，便于自动连接互信设备'**
  String get launchAtStartupDesc;

  /// No description provided for @launchAtStartupFailed.
  ///
  /// In zh, this message translates to:
  /// **'开机自启动设置失败：{error}'**
  String launchAtStartupFailed(String error);

  /// No description provided for @androidBackgroundKeepAlive.
  ///
  /// In zh, this message translates to:
  /// **'后台保活连接'**
  String get androidBackgroundKeepAlive;

  /// No description provided for @androidBackgroundKeepAliveDesc.
  ///
  /// In zh, this message translates to:
  /// **'保持局域网接收服务运行，便于在后台或锁屏时收到连接请求'**
  String get androidBackgroundKeepAliveDesc;

  /// No description provided for @androidBackgroundKeepAliveActiveTitle.
  ///
  /// In zh, this message translates to:
  /// **'Whisper 正在监听局域网连接'**
  String get androidBackgroundKeepAliveActiveTitle;

  /// No description provided for @androidBackgroundKeepAliveActiveDesc.
  ///
  /// In zh, this message translates to:
  /// **'可在后台接收附近设备的连接请求'**
  String get androidBackgroundKeepAliveActiveDesc;

  /// No description provided for @androidBatteryOptimization.
  ///
  /// In zh, this message translates to:
  /// **'电池优化白名单'**
  String get androidBatteryOptimization;

  /// No description provided for @androidBatteryOptimizationDesc.
  ///
  /// In zh, this message translates to:
  /// **'建议允许后台运行，并把 Whisper 加入电池优化白名单，尤其是小米、OPPO、vivo、华为设备'**
  String get androidBatteryOptimizationDesc;

  /// No description provided for @fileTransferQueued.
  ///
  /// In zh, this message translates to:
  /// **'排队中'**
  String get fileTransferQueued;

  /// No description provided for @fileTransferPreparingResume.
  ///
  /// In zh, this message translates to:
  /// **'准备续传 {progress}%'**
  String fileTransferPreparingResume(String progress);

  /// No description provided for @fileTransferNegotiating.
  ///
  /// In zh, this message translates to:
  /// **'协商中'**
  String get fileTransferNegotiating;

  /// No description provided for @fileTransferWaitingReconnect.
  ///
  /// In zh, this message translates to:
  /// **'等待重连 {progress}%'**
  String fileTransferWaitingReconnect(String progress);

  /// No description provided for @fileTransferPaused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get fileTransferPaused;

  /// No description provided for @fileTransferVerifying.
  ///
  /// In zh, this message translates to:
  /// **'校验中'**
  String get fileTransferVerifying;

  /// No description provided for @fileTransferWaitingPeerVerification.
  ///
  /// In zh, this message translates to:
  /// **'等待对端校验'**
  String get fileTransferWaitingPeerVerification;

  /// No description provided for @fileTransferFailedRetryable.
  ///
  /// In zh, this message translates to:
  /// **'失败，可重试'**
  String get fileTransferFailedRetryable;

  /// No description provided for @fileTransferCanceled.
  ///
  /// In zh, this message translates to:
  /// **'已取消'**
  String get fileTransferCanceled;

  /// No description provided for @audioShareCaptureConnecting.
  ///
  /// In zh, this message translates to:
  /// **'采集端：正在连接远端扬声器'**
  String get audioShareCaptureConnecting;

  /// No description provided for @audioSharePlaybackPreparing.
  ///
  /// In zh, this message translates to:
  /// **'播放端：正在准备播放共享声音'**
  String get audioSharePlaybackPreparing;

  /// No description provided for @audioShareCaptureActiveStop.
  ///
  /// In zh, this message translates to:
  /// **'采集端：正在共享本机声音，点击停止'**
  String get audioShareCaptureActiveStop;

  /// No description provided for @audioSharePlaybackActiveStop.
  ///
  /// In zh, this message translates to:
  /// **'播放端：正在作为扬声器播放，点击停止'**
  String get audioSharePlaybackActiveStop;

  /// No description provided for @audioShareStart.
  ///
  /// In zh, this message translates to:
  /// **'把本机声音共享给对端'**
  String get audioShareStart;

  /// No description provided for @audioSharePlaybackStopped.
  ///
  /// In zh, this message translates to:
  /// **'已停止播放共享声音'**
  String get audioSharePlaybackStopped;

  /// No description provided for @audioShareCaptureStopped.
  ///
  /// In zh, this message translates to:
  /// **'已停止共享声音'**
  String get audioShareCaptureStopped;

  /// No description provided for @audioSharePlaybackGainTitle.
  ///
  /// In zh, this message translates to:
  /// **'共享扬声器增益'**
  String get audioSharePlaybackGainTitle;

  /// No description provided for @audioSharePlaybackGainSetting.
  ///
  /// In zh, this message translates to:
  /// **'共享扬声器增益：{gain}'**
  String audioSharePlaybackGainSetting(String gain);

  /// No description provided for @audioSharePlaybackGainDesc.
  ///
  /// In zh, this message translates to:
  /// **'只影响本机播放对端共享声音，过高可能产生削波'**
  String get audioSharePlaybackGainDesc;

  /// No description provided for @remoteInputScrollMultiplierTitle.
  ///
  /// In zh, this message translates to:
  /// **'键鼠共享滚轮速度'**
  String get remoteInputScrollMultiplierTitle;

  /// No description provided for @remoteInputScrollMultiplierSetting.
  ///
  /// In zh, this message translates to:
  /// **'键鼠共享滚轮速度：{multiplier}'**
  String remoteInputScrollMultiplierSetting(String multiplier);

  /// No description provided for @remoteInputScrollMultiplierDesc.
  ///
  /// In zh, this message translates to:
  /// **'只影响本机作为被控端时接收的远端滚轮事件'**
  String get remoteInputScrollMultiplierDesc;

  /// No description provided for @audioShareUnsupportedCapture.
  ///
  /// In zh, this message translates to:
  /// **'当前设备不支持系统音频采集'**
  String get audioShareUnsupportedCapture;

  /// No description provided for @audioShareRequestingPlayback.
  ///
  /// In zh, this message translates to:
  /// **'正在请求对端播放本机声音'**
  String get audioShareRequestingPlayback;

  /// No description provided for @audioGroupShareStart.
  ///
  /// In zh, this message translates to:
  /// **'同步到多台扬声器'**
  String get audioGroupShareStart;

  /// No description provided for @audioGroupAdjust.
  ///
  /// In zh, this message translates to:
  /// **'调整音频共享'**
  String get audioGroupAdjust;

  /// No description provided for @audioGroupSelectSinks.
  ///
  /// In zh, this message translates to:
  /// **'选择播放设备'**
  String get audioGroupSelectSinks;

  /// No description provided for @audioGroupStart.
  ///
  /// In zh, this message translates to:
  /// **'开始同步播放'**
  String get audioGroupStart;

  /// No description provided for @audioGroupApply.
  ///
  /// In zh, this message translates to:
  /// **'应用配置'**
  String get audioGroupApply;

  /// No description provided for @audioGroupStop.
  ///
  /// In zh, this message translates to:
  /// **'停止共享'**
  String get audioGroupStop;

  /// No description provided for @audioGroupRoleStereo.
  ///
  /// In zh, this message translates to:
  /// **'立体声'**
  String get audioGroupRoleStereo;

  /// No description provided for @audioGroupRoleLeft.
  ///
  /// In zh, this message translates to:
  /// **'左声道'**
  String get audioGroupRoleLeft;

  /// No description provided for @audioGroupRoleRight.
  ///
  /// In zh, this message translates to:
  /// **'右声道'**
  String get audioGroupRoleRight;

  /// No description provided for @audioGroupRoleMono.
  ///
  /// In zh, this message translates to:
  /// **'单声道'**
  String get audioGroupRoleMono;

  /// No description provided for @audioGroupRequestingPlayback.
  ///
  /// In zh, this message translates to:
  /// **'正在请求多台设备同步播放'**
  String get audioGroupRequestingPlayback;

  /// No description provided for @audioGroupSelectAtLeastOne.
  ///
  /// In zh, this message translates to:
  /// **'至少选择一台播放设备'**
  String get audioGroupSelectAtLeastOne;

  /// No description provided for @audioGroupSyncCalibrating.
  ///
  /// In zh, this message translates to:
  /// **'正在估算同步'**
  String get audioGroupSyncCalibrating;

  /// No description provided for @audioGroupSyncGood.
  ///
  /// In zh, this message translates to:
  /// **'同步良好'**
  String get audioGroupSyncGood;

  /// No description provided for @audioGroupSyncFair.
  ///
  /// In zh, this message translates to:
  /// **'同步一般'**
  String get audioGroupSyncFair;

  /// No description provided for @audioGroupSyncUnstable.
  ///
  /// In zh, this message translates to:
  /// **'同步波动'**
  String get audioGroupSyncUnstable;

  /// No description provided for @audioGroupDeviceIdle.
  ///
  /// In zh, this message translates to:
  /// **'未播放'**
  String get audioGroupDeviceIdle;

  /// No description provided for @audioGroupLatencyShortLabel.
  ///
  /// In zh, this message translates to:
  /// **'网络'**
  String get audioGroupLatencyShortLabel;

  /// No description provided for @audioGroupJitterShortLabel.
  ///
  /// In zh, this message translates to:
  /// **'抖动'**
  String get audioGroupJitterShortLabel;

  /// No description provided for @audioGroupBufferShortLabel.
  ///
  /// In zh, this message translates to:
  /// **'缓冲'**
  String get audioGroupBufferShortLabel;

  /// No description provided for @audioGroupRecentLatePacketShortLabel.
  ///
  /// In zh, this message translates to:
  /// **'晚包'**
  String get audioGroupRecentLatePacketShortLabel;

  /// No description provided for @audioGroupClockOffsetLabel.
  ///
  /// In zh, this message translates to:
  /// **'时钟偏移'**
  String get audioGroupClockOffsetLabel;

  /// No description provided for @audioGroupSyncEvidence.
  ///
  /// In zh, this message translates to:
  /// **'{quality} · {clockOffsetLabel} {offset}ms · RTT {rtt}ms · 抖动 {jitter}ms · 缓冲 {buffer}ms · 晚包 {latePackets}'**
  String audioGroupSyncEvidence(
    Object quality,
    Object clockOffsetLabel,
    Object offset,
    Object rtt,
    Object jitter,
    Object buffer,
    Object latePackets,
  );

  /// No description provided for @audioGroupSyncEvidenceCompact.
  ///
  /// In zh, this message translates to:
  /// **'{quality} · {latencyLabel}{rtt} · {jitterLabel}{jitter} · {bufferLabel}{buffer} · {latePacketLabel}{latePackets}'**
  String audioGroupSyncEvidenceCompact(
    Object quality,
    Object latencyLabel,
    Object rtt,
    Object jitterLabel,
    Object jitter,
    Object bufferLabel,
    Object buffer,
    Object latePacketLabel,
    Object latePackets,
  );

  /// No description provided for @audioShareFailed.
  ///
  /// In zh, this message translates to:
  /// **'共享声音失败：{error}'**
  String audioShareFailed(String error);

  /// No description provided for @remoteInputSourceConnecting.
  ///
  /// In zh, this message translates to:
  /// **'键鼠共享：正在连接对端'**
  String get remoteInputSourceConnecting;

  /// No description provided for @remoteInputSinkConnecting.
  ///
  /// In zh, this message translates to:
  /// **'键鼠共享：正在准备接收控制'**
  String get remoteInputSinkConnecting;

  /// No description provided for @remoteInputEdgeActiveStop.
  ///
  /// In zh, this message translates to:
  /// **'键鼠共享：边缘穿越已启用，点击停止'**
  String get remoteInputEdgeActiveStop;

  /// No description provided for @remoteInputSourceActiveStop.
  ///
  /// In zh, this message translates to:
  /// **'键鼠共享：正在控制对端，点击停止'**
  String get remoteInputSourceActiveStop;

  /// No description provided for @remoteInputSinkActiveStop.
  ///
  /// In zh, this message translates to:
  /// **'键鼠共享：正在接收控制，点击停止'**
  String get remoteInputSinkActiveStop;

  /// No description provided for @remoteInputStart.
  ///
  /// In zh, this message translates to:
  /// **'启用键鼠共享'**
  String get remoteInputStart;

  /// No description provided for @remoteInputStopped.
  ///
  /// In zh, this message translates to:
  /// **'已停止键鼠共享'**
  String get remoteInputStopped;

  /// No description provided for @remoteInputStopCurrentFirst.
  ///
  /// In zh, this message translates to:
  /// **'请先停止当前键鼠共享会话'**
  String get remoteInputStopCurrentFirst;

  /// No description provided for @remoteInputLocalUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'当前设备不支持键鼠共享'**
  String get remoteInputLocalUnsupported;

  /// No description provided for @remoteInputPeerUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'当前连接设备不支持键鼠共享'**
  String get remoteInputPeerUnsupported;

  /// No description provided for @remoteInputRequiresMutualTrust.
  ///
  /// In zh, this message translates to:
  /// **'键鼠共享需要互信设备'**
  String get remoteInputRequiresMutualTrust;

  /// No description provided for @remoteInputPeerMustTrustThisDevice.
  ///
  /// In zh, this message translates to:
  /// **'对端还没有信任本机，请先在对端信任本机后再共享键鼠'**
  String get remoteInputPeerMustTrustThisDevice;

  /// No description provided for @remoteInputLayoutRequired.
  ///
  /// In zh, this message translates to:
  /// **'请先在键鼠工作区把对端屏幕贴到本机边缘'**
  String get remoteInputLayoutRequired;

  /// No description provided for @remoteInputEnabledMoveToEdge.
  ///
  /// In zh, this message translates to:
  /// **'键鼠共享已启用，移动到屏幕边缘开始控制对端'**
  String get remoteInputEnabledMoveToEdge;

  /// No description provided for @remoteInputFailed.
  ///
  /// In zh, this message translates to:
  /// **'键鼠共享失败：{error}'**
  String remoteInputFailed(String error);

  /// No description provided for @remoteInputLayoutTitle.
  ///
  /// In zh, this message translates to:
  /// **'屏幕排列'**
  String get remoteInputLayoutTitle;

  /// No description provided for @remoteInputLocalScreen.
  ///
  /// In zh, this message translates to:
  /// **'本机'**
  String get remoteInputLocalScreen;

  /// No description provided for @remoteInputEdgeLeft.
  ///
  /// In zh, this message translates to:
  /// **'左侧'**
  String get remoteInputEdgeLeft;

  /// No description provided for @remoteInputEdgeRight.
  ///
  /// In zh, this message translates to:
  /// **'右侧'**
  String get remoteInputEdgeRight;

  /// No description provided for @remoteInputEdgeTop.
  ///
  /// In zh, this message translates to:
  /// **'上方'**
  String get remoteInputEdgeTop;

  /// No description provided for @remoteInputEdgeBottom.
  ///
  /// In zh, this message translates to:
  /// **'下方'**
  String get remoteInputEdgeBottom;

  /// No description provided for @remoteInputEdgeNotAdjacent.
  ///
  /// In zh, this message translates to:
  /// **'未贴边'**
  String get remoteInputEdgeNotAdjacent;

  /// No description provided for @remoteInputWorkspaceTitle.
  ///
  /// In zh, this message translates to:
  /// **'键鼠工作区'**
  String get remoteInputWorkspaceTitle;

  /// No description provided for @remoteInputWorkspaceTooltip.
  ///
  /// In zh, this message translates to:
  /// **'键鼠工作区'**
  String get remoteInputWorkspaceTooltip;

  /// No description provided for @remoteInputWorkspaceStart.
  ///
  /// In zh, this message translates to:
  /// **'启动'**
  String get remoteInputWorkspaceStart;

  /// No description provided for @remoteInputWorkspaceStop.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get remoteInputWorkspaceStop;

  /// No description provided for @remoteInputWorkspaceNoTargets.
  ///
  /// In zh, this message translates to:
  /// **'没有可用的桌面被控设备'**
  String get remoteInputWorkspaceNoTargets;

  /// No description provided for @remoteInputWorkspaceSelectTargets.
  ///
  /// In zh, this message translates to:
  /// **'被控设备'**
  String get remoteInputWorkspaceSelectTargets;

  /// No description provided for @remoteInputWorkspaceCanvasTitle.
  ///
  /// In zh, this message translates to:
  /// **'屏幕排列'**
  String get remoteInputWorkspaceCanvasTitle;

  /// No description provided for @remoteInputWorkspaceDetailsTitle.
  ///
  /// In zh, this message translates to:
  /// **'设备详情'**
  String get remoteInputWorkspaceDetailsTitle;

  /// No description provided for @remoteInputWorkspaceFocusTarget.
  ///
  /// In zh, this message translates to:
  /// **'查看设备'**
  String get remoteInputWorkspaceFocusTarget;

  /// No description provided for @remoteInputWorkspaceAddTarget.
  ///
  /// In zh, this message translates to:
  /// **'加入工作区'**
  String get remoteInputWorkspaceAddTarget;

  /// No description provided for @remoteInputWorkspaceRemoveTarget.
  ///
  /// In zh, this message translates to:
  /// **'移出工作区'**
  String get remoteInputWorkspaceRemoveTarget;

  /// No description provided for @remoteInputWorkspaceState.
  ///
  /// In zh, this message translates to:
  /// **'状态'**
  String get remoteInputWorkspaceState;

  /// No description provided for @remoteInputWorkspaceConflict.
  ///
  /// In zh, this message translates to:
  /// **'边缘重叠'**
  String get remoteInputWorkspaceConflict;

  /// No description provided for @remoteInputWorkspaceReachable.
  ///
  /// In zh, this message translates to:
  /// **'可达'**
  String get remoteInputWorkspaceReachable;

  /// No description provided for @remoteInputWorkspaceDisconnected.
  ///
  /// In zh, this message translates to:
  /// **'未连接到工作区'**
  String get remoteInputWorkspaceDisconnected;

  /// No description provided for @remoteInputWorkspaceUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'不支持工作区路由'**
  String get remoteInputWorkspaceUnsupported;

  /// No description provided for @remoteInputWorkspaceTargetIdle.
  ///
  /// In zh, this message translates to:
  /// **'未启用'**
  String get remoteInputWorkspaceTargetIdle;

  /// No description provided for @remoteInputWorkspaceStatusIdle.
  ///
  /// In zh, this message translates to:
  /// **'键鼠工作区未启用'**
  String get remoteInputWorkspaceStatusIdle;

  /// No description provided for @remoteInputWorkspaceStatusOffering.
  ///
  /// In zh, this message translates to:
  /// **'正在等待被控设备确认'**
  String get remoteInputWorkspaceStatusOffering;

  /// No description provided for @remoteInputWorkspaceStatusArmed.
  ///
  /// In zh, this message translates to:
  /// **'移动到屏幕边缘开始控制目标设备'**
  String get remoteInputWorkspaceStatusArmed;

  /// No description provided for @remoteInputWorkspaceStatusActive.
  ///
  /// In zh, this message translates to:
  /// **'正在控制 {peer}'**
  String remoteInputWorkspaceStatusActive(String peer);

  /// No description provided for @remoteInputWorkspaceStatusFailed.
  ///
  /// In zh, this message translates to:
  /// **'键鼠工作区失败：{error}'**
  String remoteInputWorkspaceStatusFailed(String error);

  /// No description provided for @audioPlaybackNotificationSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'正在播放系统音频'**
  String get audioPlaybackNotificationSubtitle;

  /// No description provided for @mediaActionPause.
  ///
  /// In zh, this message translates to:
  /// **'暂停'**
  String get mediaActionPause;

  /// No description provided for @mediaActionPlay.
  ///
  /// In zh, this message translates to:
  /// **'播放'**
  String get mediaActionPlay;

  /// No description provided for @mediaActionDisconnect.
  ///
  /// In zh, this message translates to:
  /// **'断开'**
  String get mediaActionDisconnect;

  /// No description provided for @notificationChannelKeepAlive.
  ///
  /// In zh, this message translates to:
  /// **'后台保活'**
  String get notificationChannelKeepAlive;

  /// No description provided for @notificationChannelKeepAliveDesc.
  ///
  /// In zh, this message translates to:
  /// **'在后台运行时保持 Whisper 连接'**
  String get notificationChannelKeepAliveDesc;

  /// No description provided for @notificationChannelMedia.
  ///
  /// In zh, this message translates to:
  /// **'媒体播放'**
  String get notificationChannelMedia;

  /// No description provided for @notificationChannelTransfer.
  ///
  /// In zh, this message translates to:
  /// **'文件传输'**
  String get notificationChannelTransfer;

  /// No description provided for @notificationChannelTransferDesc.
  ///
  /// In zh, this message translates to:
  /// **'文件传输进度'**
  String get notificationChannelTransferDesc;

  /// No description provided for @notificationChannelGeneral.
  ///
  /// In zh, this message translates to:
  /// **'消息'**
  String get notificationChannelGeneral;

  /// No description provided for @notificationChannelGeneralDesc.
  ///
  /// In zh, this message translates to:
  /// **'新消息与提醒'**
  String get notificationChannelGeneralDesc;

  /// No description provided for @emptyAppsTitle.
  ///
  /// In zh, this message translates to:
  /// **'没有可用应用'**
  String get emptyAppsTitle;

  /// No description provided for @emptyAppsSearchTitle.
  ///
  /// In zh, this message translates to:
  /// **'没有找到应用'**
  String get emptyAppsSearchTitle;

  /// No description provided for @fileDropRejected.
  ///
  /// In zh, this message translates to:
  /// **'无法发送这些文件'**
  String get fileDropRejected;

  /// No description provided for @validationRequired.
  ///
  /// In zh, this message translates to:
  /// **'此项不能为空'**
  String get validationRequired;

  /// No description provided for @validationNicknameRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入昵称'**
  String get validationNicknameRequired;

  /// No description provided for @validationNicknameTooLong.
  ///
  /// In zh, this message translates to:
  /// **'昵称不能超过 64 个字符'**
  String get validationNicknameTooLong;

  /// No description provided for @validationHostRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入主机名或 IP 地址'**
  String get validationHostRequired;

  /// No description provided for @validationHostInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效的 IPv4、IPv6、.local 或主机名'**
  String get validationHostInvalid;

  /// No description provided for @validationPortInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入 1001 到 65535 之间的端口'**
  String get validationPortInvalid;

  /// No description provided for @settingsSectionDeviceAppearance.
  ///
  /// In zh, this message translates to:
  /// **'设备与外观'**
  String get settingsSectionDeviceAppearance;

  /// No description provided for @settingsSectionDeviceAppearanceDesc.
  ///
  /// In zh, this message translates to:
  /// **'名称、主题和本机在附近设备上的显示方式'**
  String get settingsSectionDeviceAppearanceDesc;

  /// No description provided for @settingsSectionConnectionTransfer.
  ///
  /// In zh, this message translates to:
  /// **'连接与传输'**
  String get settingsSectionConnectionTransfer;

  /// No description provided for @settingsSectionConnectionTransferDesc.
  ///
  /// In zh, this message translates to:
  /// **'服务端口、文件保存和可信设备连接'**
  String get settingsSectionConnectionTransferDesc;

  /// No description provided for @settingsSectionSystemBehavior.
  ///
  /// In zh, this message translates to:
  /// **'系统行为'**
  String get settingsSectionSystemBehavior;

  /// No description provided for @settingsSectionSystemBehaviorDesc.
  ///
  /// In zh, this message translates to:
  /// **'启动、后台和窗口行为'**
  String get settingsSectionSystemBehaviorDesc;

  /// No description provided for @settingsSectionPermissionsSharing.
  ///
  /// In zh, this message translates to:
  /// **'权限与共享'**
  String get settingsSectionPermissionsSharing;

  /// No description provided for @settingsSectionPermissionsSharingDesc.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板、信任、音频和键鼠权限'**
  String get settingsSectionPermissionsSharingDesc;

  /// No description provided for @settingsSectionMobileIntegration.
  ///
  /// In zh, this message translates to:
  /// **'移动端集成'**
  String get settingsSectionMobileIntegration;

  /// No description provided for @settingsSectionMobileIntegrationDesc.
  ///
  /// In zh, this message translates to:
  /// **'后台连接和电池行为'**
  String get settingsSectionMobileIntegrationDesc;

  /// No description provided for @settingsSectionNotificationForwarding.
  ///
  /// In zh, this message translates to:
  /// **'通知转发'**
  String get settingsSectionNotificationForwarding;

  /// No description provided for @settingsSectionNotificationForwardingDesc.
  ///
  /// In zh, this message translates to:
  /// **'Android 通知处理和验证码辅助'**
  String get settingsSectionNotificationForwardingDesc;

  /// No description provided for @settingsSectionLanguageFiles.
  ///
  /// In zh, this message translates to:
  /// **'语言与文件'**
  String get settingsSectionLanguageFiles;

  /// No description provided for @settingsSectionLanguageFilesDesc.
  ///
  /// In zh, this message translates to:
  /// **'语言和文件保存目录'**
  String get settingsSectionLanguageFilesDesc;

  /// No description provided for @settingsSaveDirectory.
  ///
  /// In zh, this message translates to:
  /// **'保存目录'**
  String get settingsSaveDirectory;

  /// No description provided for @settingsChangeDirectory.
  ///
  /// In zh, this message translates to:
  /// **'更改保存目录'**
  String get settingsChangeDirectory;

  /// No description provided for @settingsOpenDirectory.
  ///
  /// In zh, this message translates to:
  /// **'打开保存目录'**
  String get settingsOpenDirectory;

  /// No description provided for @settingsVersion.
  ///
  /// In zh, this message translates to:
  /// **'版本'**
  String get settingsVersion;

  /// No description provided for @settingsSectionAbout.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get settingsSectionAbout;

  /// No description provided for @settingsSectionAboutDesc.
  ///
  /// In zh, this message translates to:
  /// **'版本更新和应用信息'**
  String get settingsSectionAboutDesc;

  /// No description provided for @checkForUpdates.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get checkForUpdates;

  /// No description provided for @currentVersion.
  ///
  /// In zh, this message translates to:
  /// **'当前版本 {version}'**
  String currentVersion(String version);

  /// No description provided for @checkingForUpdates.
  ///
  /// In zh, this message translates to:
  /// **'正在检查更新…'**
  String get checkingForUpdates;

  /// No description provided for @updateAvailableVersion.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本 {version}'**
  String updateAvailableVersion(String version);

  /// No description provided for @updateUpToDate.
  ///
  /// In zh, this message translates to:
  /// **'已是最新版本'**
  String get updateUpToDate;

  /// No description provided for @updateCheckFailed.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法检查更新，请稍后重试'**
  String get updateCheckFailed;

  /// No description provided for @updateAvailableTitle.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本 {version}'**
  String updateAvailableTitle(String version);

  /// No description provided for @updateAvailableBody.
  ///
  /// In zh, this message translates to:
  /// **'当前版本 {currentVersion}，可更新到 {latestVersion}。安装前会校验 GitHub 提供的文件哈希。'**
  String updateAvailableBody(String currentVersion, String latestVersion);

  /// No description provided for @downloadAndInstallUpdate.
  ///
  /// In zh, this message translates to:
  /// **'更新'**
  String get downloadAndInstallUpdate;

  /// No description provided for @viewRelease.
  ///
  /// In zh, this message translates to:
  /// **'查看 Release'**
  String get viewRelease;

  /// No description provided for @downloadingUpdate.
  ///
  /// In zh, this message translates to:
  /// **'正在下载 {progress}%'**
  String downloadingUpdate(int progress);

  /// No description provided for @updateInstallerOpened.
  ///
  /// In zh, this message translates to:
  /// **'更新包已校验，已交给系统安装器'**
  String get updateInstallerOpened;

  /// No description provided for @updateInstallFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开更新安装包，请稍后重试'**
  String get updateInstallFailed;

  /// No description provided for @aboutWhisper.
  ///
  /// In zh, this message translates to:
  /// **'关于 Whisper'**
  String get aboutWhisper;

  /// No description provided for @aboutWhisperDescription.
  ///
  /// In zh, this message translates to:
  /// **'面向个人设备的局域网协作工具'**
  String get aboutWhisperDescription;

  /// No description provided for @officialWebsite.
  ///
  /// In zh, this message translates to:
  /// **'官方网站'**
  String get officialWebsite;

  /// No description provided for @sourceCode.
  ///
  /// In zh, this message translates to:
  /// **'GitHub 源代码'**
  String get sourceCode;

  /// No description provided for @appListSearchPlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'搜索应用'**
  String get appListSearchPlaceholder;

  /// No description provided for @appListClearSearch.
  ///
  /// In zh, this message translates to:
  /// **'清除应用搜索'**
  String get appListClearSearch;

  /// No description provided for @deselectAll.
  ///
  /// In zh, this message translates to:
  /// **'取消全选'**
  String get deselectAll;

  /// No description provided for @settingsLoadFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'无法加载设置'**
  String get settingsLoadFailedTitle;

  /// No description provided for @settingsLoadFailedBody.
  ///
  /// In zh, this message translates to:
  /// **'请检查本机应用服务后重试。'**
  String get settingsLoadFailedBody;

  /// No description provided for @appListLoadFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'无法加载应用'**
  String get appListLoadFailedTitle;

  /// No description provided for @appListLoadFailedBody.
  ///
  /// In zh, this message translates to:
  /// **'请检查应用访问权限后重试。'**
  String get appListLoadFailedBody;

  /// No description provided for @appListSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法保存通知应用选择'**
  String get appListSaveFailed;

  /// No description provided for @notificationApps.
  ///
  /// In zh, this message translates to:
  /// **'通知应用'**
  String get notificationApps;

  /// No description provided for @notificationAppsSelected.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, =0{尚未选择应用} other{已选择 {count} 个应用}}'**
  String notificationAppsSelected(int count);

  /// No description provided for @notificationAppsDisabled.
  ///
  /// In zh, this message translates to:
  /// **'开启通知转发后可选择应用'**
  String get notificationAppsDisabled;

  /// No description provided for @notificationForwardingUpdateFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法更新通知转发，请重试'**
  String get notificationForwardingUpdateFailed;

  /// No description provided for @dangerousActions.
  ///
  /// In zh, this message translates to:
  /// **'危险操作'**
  String get dangerousActions;

  /// No description provided for @pairingNewDeviceTitle.
  ///
  /// In zh, this message translates to:
  /// **'配对新设备'**
  String get pairingNewDeviceTitle;

  /// No description provided for @pairingNewDeviceDescription.
  ///
  /// In zh, this message translates to:
  /// **'{device} 请求建立可信连接'**
  String pairingNewDeviceDescription(String device);

  /// No description provided for @pairingNewDeviceCompareCode.
  ///
  /// In zh, this message translates to:
  /// **'{device} 请求连接，请确认数字一致'**
  String pairingNewDeviceCompareCode(String device);

  /// No description provided for @pairingIdentityChangedTitle.
  ///
  /// In zh, this message translates to:
  /// **'设备身份已变化'**
  String get pairingIdentityChangedTitle;

  /// No description provided for @pairingIdentityChangedDescription.
  ///
  /// In zh, this message translates to:
  /// **'{device} 的身份公钥与上次配对不同。仅在你确认设备已重装或重置后继续'**
  String pairingIdentityChangedDescription(String device);

  /// No description provided for @pairingLegacyTrustTitle.
  ///
  /// In zh, this message translates to:
  /// **'重新确认可信设备'**
  String get pairingLegacyTrustTitle;

  /// No description provided for @pairingLegacyTrustDescription.
  ///
  /// In zh, this message translates to:
  /// **'{device} 来自旧版信任记录，需要重新配对以绑定设备身份'**
  String pairingLegacyTrustDescription(String device);

  /// No description provided for @pairingCompareCode.
  ///
  /// In zh, this message translates to:
  /// **'请确认两台设备显示相同的 6 位数字'**
  String get pairingCompareCode;

  /// No description provided for @pairingNotificationBody.
  ///
  /// In zh, this message translates to:
  /// **'配对码 {code} · 请与 {device} 核对'**
  String pairingNotificationBody(String device, String code);

  /// No description provided for @pairingInitiatorNotificationBody.
  ///
  /// In zh, this message translates to:
  /// **'配对码 {code} · 等待 {device} 确认'**
  String pairingInitiatorNotificationBody(String device, String code);

  /// No description provided for @pairingIdentityChangedNotificationBody.
  ///
  /// In zh, this message translates to:
  /// **'配对码 {code} · {device} 的身份已变化，请打开 App 查看'**
  String pairingIdentityChangedNotificationBody(String device, String code);

  /// No description provided for @pairingCodeSemantics.
  ///
  /// In zh, this message translates to:
  /// **'配对码 {code}'**
  String pairingCodeSemantics(String code);

  /// No description provided for @pairingReject.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get pairingReject;

  /// No description provided for @pairingApprove.
  ///
  /// In zh, this message translates to:
  /// **'数字一致'**
  String get pairingApprove;

  /// No description provided for @pairingViewDetails.
  ///
  /// In zh, this message translates to:
  /// **'查看详情'**
  String get pairingViewDetails;

  /// No description provided for @pairingUpgradeRequired.
  ///
  /// In zh, this message translates to:
  /// **'对方版本过低，请升级 Whisper 后重试'**
  String get pairingUpgradeRequired;

  /// No description provided for @pairingExpired.
  ///
  /// In zh, this message translates to:
  /// **'配对请求已过期'**
  String get pairingExpired;

  /// No description provided for @pairingRejectedByPeer.
  ///
  /// In zh, this message translates to:
  /// **'对方拒绝了连接请求'**
  String get pairingRejectedByPeer;

  /// No description provided for @pairingEncryptionNotice.
  ///
  /// In zh, this message translates to:
  /// **'配对后，文本、文件、剪贴板和控制数据均端到端加密'**
  String get pairingEncryptionNotice;

  /// No description provided for @e2eeTrustedConnection.
  ///
  /// In zh, this message translates to:
  /// **'端到端加密 · 可信设备'**
  String get e2eeTrustedConnection;

  /// No description provided for @e2eeEncryptedConnection.
  ///
  /// In zh, this message translates to:
  /// **'端到端加密连接'**
  String get e2eeEncryptedConnection;

  /// No description provided for @transferAssistantTitle.
  ///
  /// In zh, this message translates to:
  /// **'传输助手'**
  String get transferAssistantTitle;

  /// No description provided for @transferAssistantSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索文本消息'**
  String get transferAssistantSearchHint;

  /// No description provided for @transferAssistantClearSearch.
  ///
  /// In zh, this message translates to:
  /// **'清除搜索'**
  String get transferAssistantClearSearch;

  /// No description provided for @transferAssistantSearchResults.
  ///
  /// In zh, this message translates to:
  /// **'搜索结果'**
  String get transferAssistantSearchResults;

  /// No description provided for @transferAssistantFavorites.
  ///
  /// In zh, this message translates to:
  /// **'收藏文本'**
  String get transferAssistantFavorites;

  /// No description provided for @transferAssistantRecent.
  ///
  /// In zh, this message translates to:
  /// **'最近文本'**
  String get transferAssistantRecent;

  /// No description provided for @transferAssistantNoResults.
  ///
  /// In zh, this message translates to:
  /// **'没有找到匹配的文本'**
  String get transferAssistantNoResults;

  /// No description provided for @transferAssistantNoFavorites.
  ///
  /// In zh, this message translates to:
  /// **'还没有收藏文本'**
  String get transferAssistantNoFavorites;

  /// No description provided for @transferAssistantNoRecent.
  ///
  /// In zh, this message translates to:
  /// **'还没有文本消息'**
  String get transferAssistantNoRecent;

  /// No description provided for @transferAssistantIncoming.
  ///
  /// In zh, this message translates to:
  /// **'收到'**
  String get transferAssistantIncoming;

  /// No description provided for @transferAssistantOutgoing.
  ///
  /// In zh, this message translates to:
  /// **'发出'**
  String get transferAssistantOutgoing;

  /// No description provided for @transferAssistantCopy.
  ///
  /// In zh, this message translates to:
  /// **'复制文本'**
  String get transferAssistantCopy;

  /// No description provided for @transferAssistantFavorite.
  ///
  /// In zh, this message translates to:
  /// **'收藏文本'**
  String get transferAssistantFavorite;

  /// No description provided for @transferAssistantUnfavorite.
  ///
  /// In zh, this message translates to:
  /// **'取消收藏'**
  String get transferAssistantUnfavorite;

  /// No description provided for @transferAssistantLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法加载文本消息'**
  String get transferAssistantLoadFailed;

  /// No description provided for @transferAssistantCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制文本'**
  String get transferAssistantCopied;

  /// No description provided for @transferAssistantCopyFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法复制文本'**
  String get transferAssistantCopyFailed;

  /// No description provided for @transferAssistantFavoriteFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法更新收藏，请重试'**
  String get transferAssistantFavoriteFailed;

  /// No description provided for @qrPairingTitle.
  ///
  /// In zh, this message translates to:
  /// **'二维码连接'**
  String get qrPairingTitle;

  /// No description provided for @qrMyCode.
  ///
  /// In zh, this message translates to:
  /// **'我的二维码'**
  String get qrMyCode;

  /// No description provided for @qrScanCode.
  ///
  /// In zh, this message translates to:
  /// **'扫码连接'**
  String get qrScanCode;

  /// No description provided for @qrShowCodeHint.
  ///
  /// In zh, this message translates to:
  /// **'让另一台设备扫描此二维码，地址和设备身份会同时核验'**
  String get qrShowCodeHint;

  /// No description provided for @qrFingerprint.
  ///
  /// In zh, this message translates to:
  /// **'身份指纹 {fingerprint}'**
  String qrFingerprint(String fingerprint);

  /// No description provided for @qrWifiUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'未检测到可用的局域网地址，请先连接 Wi-Fi 再刷新二维码'**
  String get qrWifiUnavailable;

  /// No description provided for @qrCopyLink.
  ///
  /// In zh, this message translates to:
  /// **'复制连接信息'**
  String get qrCopyLink;

  /// No description provided for @qrLinkCopied.
  ///
  /// In zh, this message translates to:
  /// **'连接信息已复制'**
  String get qrLinkCopied;

  /// No description provided for @qrScanHint.
  ///
  /// In zh, this message translates to:
  /// **'扫描对方 Whisper 中显示的二维码'**
  String get qrScanHint;

  /// No description provided for @qrCameraUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'无法使用相机，请在系统设置中允许 Whisper 访问相机'**
  String get qrCameraUnavailable;

  /// No description provided for @qrToggleTorch.
  ///
  /// In zh, this message translates to:
  /// **'开关手电筒'**
  String get qrToggleTorch;

  /// No description provided for @qrSwitchCamera.
  ///
  /// In zh, this message translates to:
  /// **'切换相机'**
  String get qrSwitchCamera;

  /// No description provided for @qrCannotPairSelf.
  ///
  /// In zh, this message translates to:
  /// **'不能连接当前设备，请扫描另一台设备的二维码'**
  String get qrCannotPairSelf;

  /// No description provided for @qrInvalidCode.
  ///
  /// In zh, this message translates to:
  /// **'这不是有效的 Whisper 二维码，请让对方重新出示'**
  String get qrInvalidCode;

  /// No description provided for @connectionDiagnosticTitle.
  ///
  /// In zh, this message translates to:
  /// **'连接诊断'**
  String get connectionDiagnosticTitle;

  /// No description provided for @connectionDiagnosticWifi.
  ///
  /// In zh, this message translates to:
  /// **'无法到达该设备。请确认两台设备连接同一 Wi-Fi，并关闭访客网络或 AP 隔离后重试。'**
  String get connectionDiagnosticWifi;

  /// No description provided for @connectionDiagnosticAddress.
  ///
  /// In zh, this message translates to:
  /// **'二维码中的局域网地址无效或已经变化。请让对方重新打开二维码后再扫描。'**
  String get connectionDiagnosticAddress;

  /// No description provided for @connectionDiagnosticService.
  ///
  /// In zh, this message translates to:
  /// **'地址已找到，但 Whisper 服务没有响应。请在对方设备打开 Whisper，并确认局域网服务正在运行。'**
  String get connectionDiagnosticService;

  /// No description provided for @connectionDiagnosticFirewall.
  ///
  /// In zh, this message translates to:
  /// **'连接超时。请在两台设备的系统防火墙中允许 Whisper 访问局域网后重试。'**
  String get connectionDiagnosticFirewall;

  /// No description provided for @connectionDiagnosticIdentity.
  ///
  /// In zh, this message translates to:
  /// **'设备身份与二维码不一致，Whisper 已停止连接。请在对方设备重新出示二维码，切勿绕过此检查。'**
  String get connectionDiagnosticIdentity;

  /// No description provided for @connectionDiagnosticVersion.
  ///
  /// In zh, this message translates to:
  /// **'两台设备的协议版本不兼容，请将 Whisper 更新到相同的新版本后重试。'**
  String get connectionDiagnosticVersion;

  /// No description provided for @connectionDiagnosticPairing.
  ///
  /// In zh, this message translates to:
  /// **'配对未完成。请保持两台设备上的 Whisper 打开，并重新核对配对码。'**
  String get connectionDiagnosticPairing;

  /// No description provided for @androidSystemShareTitle.
  ///
  /// In zh, this message translates to:
  /// **'发送分享内容'**
  String get androidSystemShareTitle;

  /// No description provided for @androidSystemShareChooseTrustedDevice.
  ///
  /// In zh, this message translates to:
  /// **'选择可信设备，确认前不会发送任何内容'**
  String get androidSystemShareChooseTrustedDevice;

  /// No description provided for @androidSystemShareOnline.
  ///
  /// In zh, this message translates to:
  /// **'在线'**
  String get androidSystemShareOnline;

  /// No description provided for @androidSystemShareOffline.
  ///
  /// In zh, this message translates to:
  /// **'离线'**
  String get androidSystemShareOffline;

  /// No description provided for @androidSystemShareNoTrustedDevices.
  ///
  /// In zh, this message translates to:
  /// **'没有可选的可信设备，请先完成配对并确认设备身份'**
  String get androidSystemShareNoTrustedDevices;

  /// No description provided for @androidSystemShareConfirmTarget.
  ///
  /// In zh, this message translates to:
  /// **'确认发送目标'**
  String get androidSystemShareConfirmTarget;

  /// No description provided for @androidSystemShareWaitingForDevice.
  ///
  /// In zh, this message translates to:
  /// **'已选择 {device}，连接后将自动发送'**
  String androidSystemShareWaitingForDevice(String device);

  /// No description provided for @androidSystemShareSendingTo.
  ///
  /// In zh, this message translates to:
  /// **'正在发送给 {device}'**
  String androidSystemShareSendingTo(String device);

  /// No description provided for @androidSystemShareSentTo.
  ///
  /// In zh, this message translates to:
  /// **'已发送给 {device}'**
  String androidSystemShareSentTo(String device);

  /// No description provided for @androidSystemShareFailedRetained.
  ///
  /// In zh, this message translates to:
  /// **'发送失败，分享内容已保留'**
  String get androidSystemShareFailedRetained;

  /// No description provided for @androidSystemShareStillPending.
  ///
  /// In zh, this message translates to:
  /// **'分享内容仍在等待选择设备'**
  String get androidSystemShareStillPending;

  /// No description provided for @androidSystemShareQueueFull.
  ///
  /// In zh, this message translates to:
  /// **'队列已满，新内容未加入，请先处理已有分享'**
  String get androidSystemShareQueueFull;

  /// No description provided for @androidSystemShareRejected.
  ///
  /// In zh, this message translates to:
  /// **'分享内容超过限制或无法完整读取，未加入队列'**
  String get androidSystemShareRejected;

  /// No description provided for @androidSystemShareTargetNeedsReselection.
  ///
  /// In zh, this message translates to:
  /// **'目标设备身份已变化或不再可信，请重新选择'**
  String get androidSystemShareTargetNeedsReselection;

  /// No description provided for @androidSystemShareChooseAction.
  ///
  /// In zh, this message translates to:
  /// **'选择设备'**
  String get androidSystemShareChooseAction;

  /// No description provided for @androidSystemShareMoreFiles.
  ///
  /// In zh, this message translates to:
  /// **'另有 {count} 个文件'**
  String androidSystemShareMoreFiles(int count);

  /// No description provided for @desktopQuickSendTitle.
  ///
  /// In zh, this message translates to:
  /// **'快捷发送'**
  String get desktopQuickSendTitle;

  /// No description provided for @desktopQuickSendSummary.
  ///
  /// In zh, this message translates to:
  /// **'{textCount} 条文本 · {fileCount} 个文件'**
  String desktopQuickSendSummary(int textCount, int fileCount);

  /// No description provided for @desktopQuickSendMore.
  ///
  /// In zh, this message translates to:
  /// **'还有 {count} 项'**
  String desktopQuickSendMore(int count);

  /// No description provided for @desktopQuickSendFiles.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个文件'**
  String desktopQuickSendFiles(int count);

  /// No description provided for @desktopQuickSendChooseDevice.
  ///
  /// In zh, this message translates to:
  /// **'发送到可信设备'**
  String get desktopQuickSendChooseDevice;

  /// No description provided for @desktopQuickSendNoTrustedDevices.
  ///
  /// In zh, this message translates to:
  /// **'没有可信设备，请先完成配对'**
  String get desktopQuickSendNoTrustedDevices;

  /// No description provided for @desktopQuickSendDeviceOffline.
  ///
  /// In zh, this message translates to:
  /// **'设备离线，内容会保留到重新连接'**
  String get desktopQuickSendDeviceOffline;

  /// No description provided for @desktopQuickSendLater.
  ///
  /// In zh, this message translates to:
  /// **'稍后'**
  String get desktopQuickSendLater;

  /// No description provided for @desktopQuickSendSend.
  ///
  /// In zh, this message translates to:
  /// **'发送'**
  String get desktopQuickSendSend;

  /// No description provided for @desktopQuickSendSent.
  ///
  /// In zh, this message translates to:
  /// **'已加入加密传输队列'**
  String get desktopQuickSendSent;

  /// No description provided for @desktopQuickSendFailedRetained.
  ///
  /// In zh, this message translates to:
  /// **'发送未完成，内容已保留'**
  String get desktopQuickSendFailedRetained;

  /// No description provided for @desktopQuickSendEmptyClipboard.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板中没有可发送的内容'**
  String get desktopQuickSendEmptyClipboard;

  /// No description provided for @desktopQuickSendShortcutUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'全局发送快捷键被其他应用占用'**
  String get desktopQuickSendShortcutUnavailable;

  /// No description provided for @desktopQuickSendDraftLimit.
  ///
  /// In zh, this message translates to:
  /// **'快捷发送已满，新内容未加入，请先处理已有内容'**
  String get desktopQuickSendDraftLimit;

  /// No description provided for @desktopQuickSendFileLimit.
  ///
  /// In zh, this message translates to:
  /// **'一次选择的文件过多，新内容未加入'**
  String get desktopQuickSendFileLimit;

  /// No description provided for @desktopQuickSendTextLimit.
  ///
  /// In zh, this message translates to:
  /// **'文本过长，新内容未加入'**
  String get desktopQuickSendTextLimit;

  /// No description provided for @desktopQuickSendInvalidPath.
  ///
  /// In zh, this message translates to:
  /// **'文件路径无效或过长，新内容未加入'**
  String get desktopQuickSendInvalidPath;

  /// No description provided for @desktopQuickSendClipboardSnapshotUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'无法立即读取剪贴板，未加入可能已变化的内容'**
  String get desktopQuickSendClipboardSnapshotUnavailable;

  /// No description provided for @desktopQuickSendTargetConflict.
  ///
  /// In zh, this message translates to:
  /// **'部分内容已发送到另一台设备，请选择原设备继续'**
  String get desktopQuickSendTargetConflict;

  /// No description provided for @desktopQuickSendTargetNeedsReselection.
  ///
  /// In zh, this message translates to:
  /// **'目标设备身份已变化或不再可信，内容已保留，请重新选择'**
  String get desktopQuickSendTargetNeedsReselection;

  /// No description provided for @chatTimestampYesterday.
  ///
  /// In zh, this message translates to:
  /// **'昨天 {time}'**
  String chatTimestampYesterday(String time);

  /// No description provided for @messageLinkOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开此链接'**
  String get messageLinkOpenFailed;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
