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
      int percent, String speed, String remaining);

  /// No description provided for @transferNotificationBodyReceiving.
  ///
  /// In zh, this message translates to:
  /// **'接收中 {percent}% · {speed} · 剩余 {remaining}'**
  String transferNotificationBodyReceiving(
      int percent, String speed, String remaining);

  /// No description provided for @transferNotificationBodyMixed.
  ///
  /// In zh, this message translates to:
  /// **'收发中 {percent}% · {speed} · 剩余 {remaining}'**
  String transferNotificationBodyMixed(
      int percent, String speed, String remaining);

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
  /// **'连接期间启用前台服务，降低选文件、切后台或锁屏时被系统断开的概率'**
  String get androidBackgroundKeepAliveDesc;

  /// No description provided for @androidBackgroundKeepAliveActiveTitle.
  ///
  /// In zh, this message translates to:
  /// **'Whisper 正在保持连接'**
  String get androidBackgroundKeepAliveActiveTitle;

  /// No description provided for @androidBackgroundKeepAliveActiveDesc.
  ///
  /// In zh, this message translates to:
  /// **'有活动会话时保持前台服务运行'**
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

  /// No description provided for @fileTransferLegacyInProgress.
  ///
  /// In zh, this message translates to:
  /// **'旧协议传输中'**
  String get fileTransferLegacyInProgress;

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

  /// No description provided for @peerDoesNotSupportResumableTransfer.
  ///
  /// In zh, this message translates to:
  /// **'对端不支持断点续传'**
  String get peerDoesNotSupportResumableTransfer;

  /// No description provided for @connectedPeerDoesNotSupportResumableTransfer.
  ///
  /// In zh, this message translates to:
  /// **'当前连接设备不支持断点续传'**
  String get connectedPeerDoesNotSupportResumableTransfer;

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
      Object latePackets);

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
      Object latePackets);

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
  /// **'请先在设备设置里把对端屏幕贴到本机边缘'**
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

  /// No description provided for @remoteInputAutoModeSetting.
  ///
  /// In zh, this message translates to:
  /// **'键鼠共享自动模式：{mode}'**
  String remoteInputAutoModeSetting(String mode);

  /// No description provided for @remoteInputLayoutSetting.
  ///
  /// In zh, this message translates to:
  /// **'屏幕排列：{edge}'**
  String remoteInputLayoutSetting(String edge);

  /// No description provided for @remoteInputAutoModeTitle.
  ///
  /// In zh, this message translates to:
  /// **'键鼠共享自动模式'**
  String get remoteInputAutoModeTitle;

  /// No description provided for @remoteInputAutoModeOff.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get remoteInputAutoModeOff;

  /// No description provided for @remoteInputAutoModeSource.
  ///
  /// In zh, this message translates to:
  /// **'本机控制对端'**
  String get remoteInputAutoModeSource;

  /// No description provided for @remoteInputAutoModeSink.
  ///
  /// In zh, this message translates to:
  /// **'对端控制本机'**
  String get remoteInputAutoModeSink;

  /// No description provided for @remoteInputLayoutTitle.
  ///
  /// In zh, this message translates to:
  /// **'屏幕排列'**
  String get remoteInputLayoutTitle;

  /// No description provided for @remoteInputCurrentEdge.
  ///
  /// In zh, this message translates to:
  /// **'当前：{edge}'**
  String remoteInputCurrentEdge(String edge);

  /// No description provided for @remoteInputLayoutSave.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get remoteInputLayoutSave;

  /// No description provided for @remoteInputSnapLeft.
  ///
  /// In zh, this message translates to:
  /// **'贴左'**
  String get remoteInputSnapLeft;

  /// No description provided for @remoteInputSnapRight.
  ///
  /// In zh, this message translates to:
  /// **'贴右'**
  String get remoteInputSnapRight;

  /// No description provided for @remoteInputSnapTop.
  ///
  /// In zh, this message translates to:
  /// **'贴上'**
  String get remoteInputSnapTop;

  /// No description provided for @remoteInputSnapBottom.
  ///
  /// In zh, this message translates to:
  /// **'贴下'**
  String get remoteInputSnapBottom;

  /// No description provided for @remoteInputLocalScreen.
  ///
  /// In zh, this message translates to:
  /// **'本机'**
  String get remoteInputLocalScreen;

  /// No description provided for @remoteInputPeerScreen.
  ///
  /// In zh, this message translates to:
  /// **'对端'**
  String get remoteInputPeerScreen;

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
      'that was used.');
}
