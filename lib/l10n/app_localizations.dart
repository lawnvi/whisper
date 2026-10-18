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

  /// No description provided for @mobileControlSpace.
  ///
  /// In zh, this message translates to:
  /// **'空格'**
  String get mobileControlSpace;

  /// No description provided for @mobileControlEnter.
  ///
  /// In zh, this message translates to:
  /// **'回车'**
  String get mobileControlEnter;

  /// No description provided for @mobileControlSymbols.
  ///
  /// In zh, this message translates to:
  /// **'数字与符号'**
  String get mobileControlSymbols;

  /// No description provided for @mobileControlMoreSymbols.
  ///
  /// In zh, this message translates to:
  /// **'更多符号'**
  String get mobileControlMoreSymbols;

  /// No description provided for @mobileControlDirectKeys.
  ///
  /// In zh, this message translates to:
  /// **'直接按键'**
  String get mobileControlDirectKeys;

  /// No description provided for @mobileControlReturnKeys.
  ///
  /// In zh, this message translates to:
  /// **'返回直接按键'**
  String get mobileControlReturnKeys;

  /// No description provided for @mobileControlDraftHint.
  ///
  /// In zh, this message translates to:
  /// **'中文、表情或一段文字…'**
  String get mobileControlDraftHint;

  /// No description provided for @mobileControlScrollShort.
  ///
  /// In zh, this message translates to:
  /// **'滚动'**
  String get mobileControlScrollShort;

  /// No description provided for @mobileControlLeftShort.
  ///
  /// In zh, this message translates to:
  /// **'左键'**
  String get mobileControlLeftShort;

  /// No description provided for @mobileControlRightShort.
  ///
  /// In zh, this message translates to:
  /// **'右键'**
  String get mobileControlRightShort;

  /// No description provided for @mobileControlStopShort.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get mobileControlStopShort;

  /// No description provided for @mobileControlPermission.
  ///
  /// In zh, this message translates to:
  /// **'请在 Mac 的“系统设置 → 隐私与安全性 → 辅助功能”中允许 Whisper，然后重新开始。'**
  String get mobileControlPermission;

  /// No description provided for @mobileControlTitle.
  ///
  /// In zh, this message translates to:
  /// **'控制电脑'**
  String get mobileControlTitle;

  /// No description provided for @mobileControlStart.
  ///
  /// In zh, this message translates to:
  /// **'开始控制'**
  String get mobileControlStart;

  /// No description provided for @mobileControlStop.
  ///
  /// In zh, this message translates to:
  /// **'停止控制'**
  String get mobileControlStop;

  /// No description provided for @mobileControlReady.
  ///
  /// In zh, this message translates to:
  /// **'已就绪'**
  String get mobileControlReady;

  /// No description provided for @mobileControlActive.
  ///
  /// In zh, this message translates to:
  /// **'正在控制'**
  String get mobileControlActive;

  /// No description provided for @remoteInputPeerControlling.
  ///
  /// In zh, this message translates to:
  /// **'正在控制此设备'**
  String get remoteInputPeerControlling;

  /// No description provided for @remoteInputPeerReceiving.
  ///
  /// In zh, this message translates to:
  /// **'正在控制本机'**
  String get remoteInputPeerReceiving;

  /// No description provided for @remoteInputPeerReady.
  ///
  /// In zh, this message translates to:
  /// **'已就绪，等待切入'**
  String get remoteInputPeerReady;

  /// No description provided for @remoteInputManualSessionTitle.
  ///
  /// In zh, this message translates to:
  /// **'手机键鼠'**
  String get remoteInputManualSessionTitle;

  /// No description provided for @remoteInputManualSessionHint.
  ///
  /// In zh, this message translates to:
  /// **'手机控制独立于下方的桌面键鼠工作区。'**
  String get remoteInputManualSessionHint;

  /// No description provided for @mobileControlPreparing.
  ///
  /// In zh, this message translates to:
  /// **'正在连接控制'**
  String get mobileControlPreparing;

  /// No description provided for @mobileControlAir.
  ///
  /// In zh, this message translates to:
  /// **'体感鼠标'**
  String get mobileControlAir;

  /// No description provided for @mobileControlTouchpad.
  ///
  /// In zh, this message translates to:
  /// **'触控板'**
  String get mobileControlTouchpad;

  /// No description provided for @mobileControlHoldMove.
  ///
  /// In zh, this message translates to:
  /// **'按住此处，转腕移动光标'**
  String get mobileControlHoldMove;

  /// No description provided for @mobileControlTouchHint.
  ///
  /// In zh, this message translates to:
  /// **'单指移动 · 轻点左击\n双指轻点右击 · 双指滑动滚动'**
  String get mobileControlTouchHint;

  /// No description provided for @mobileControlHoldScroll.
  ///
  /// In zh, this message translates to:
  /// **'按住转腕滚动'**
  String get mobileControlHoldScroll;

  /// No description provided for @mobileControlScroll.
  ///
  /// In zh, this message translates to:
  /// **'滑动滚动'**
  String get mobileControlScroll;

  /// No description provided for @mobileControlLeft.
  ///
  /// In zh, this message translates to:
  /// **'左键'**
  String get mobileControlLeft;

  /// No description provided for @mobileControlRight.
  ///
  /// In zh, this message translates to:
  /// **'右键'**
  String get mobileControlRight;

  /// No description provided for @mobileControlKeyboard.
  ///
  /// In zh, this message translates to:
  /// **'虚拟键盘'**
  String get mobileControlKeyboard;

  /// No description provided for @mobileControlText.
  ///
  /// In zh, this message translates to:
  /// **'文字输入'**
  String get mobileControlText;

  /// No description provided for @mobileControlMainKeys.
  ///
  /// In zh, this message translates to:
  /// **'主键盘'**
  String get mobileControlMainKeys;

  /// No description provided for @mobileControlFunctionKeys.
  ///
  /// In zh, this message translates to:
  /// **'功能与导航键'**
  String get mobileControlFunctionKeys;

  /// No description provided for @mobileControlSendText.
  ///
  /// In zh, this message translates to:
  /// **'发送文字'**
  String get mobileControlSendText;

  /// No description provided for @mobileControlTextHint.
  ///
  /// In zh, this message translates to:
  /// **'先在电脑选中输入框，再输入并发送文字。'**
  String get mobileControlTextHint;

  /// No description provided for @mobileControlTextTooLong.
  ///
  /// In zh, this message translates to:
  /// **'每次最多发送 4 KiB 文字。'**
  String get mobileControlTextTooLong;

  /// No description provided for @mobileControlTextUnconfirmed.
  ///
  /// In zh, this message translates to:
  /// **'未确认输入结果，草稿已保留。请查看电脑后再决定是否重发。'**
  String get mobileControlTextUnconfirmed;

  /// No description provided for @mobileControlTextSent.
  ///
  /// In zh, this message translates to:
  /// **'文字已交给电脑系统，请查看目标应用。'**
  String get mobileControlTextSent;

  /// No description provided for @mobileControlSensorUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'体感不可用，已切换到触控板。'**
  String get mobileControlSensorUnavailable;

  /// No description provided for @mobileControlSensitivity.
  ///
  /// In zh, this message translates to:
  /// **'体感移动速度'**
  String get mobileControlSensitivity;

  /// No description provided for @mobileControlCalibrate.
  ///
  /// In zh, this message translates to:
  /// **'校准'**
  String get mobileControlCalibrate;

  /// No description provided for @mobileControlCalibrating.
  ///
  /// In zh, this message translates to:
  /// **'请保持手机静止片刻…'**
  String get mobileControlCalibrating;

  /// No description provided for @mobileControlCalibrationDone.
  ///
  /// In zh, this message translates to:
  /// **'校准完成'**
  String get mobileControlCalibrationDone;

  /// No description provided for @mobileControlIdleHint.
  ///
  /// In zh, this message translates to:
  /// **'开始后可控制光标和键盘，离开此页面会停止。'**
  String get mobileControlIdleHint;

  /// No description provided for @mobileControlReceiving.
  ///
  /// In zh, this message translates to:
  /// **'此电脑正由 {name} 控制'**
  String mobileControlReceiving(String name);

  /// No description provided for @mobileControlShortcutHint.
  ///
  /// In zh, this message translates to:
  /// **'点选修饰键，再点普通键组合发送；完成后自动解除。'**
  String get mobileControlShortcutHint;

  /// No description provided for @screenshotCapture.
  ///
  /// In zh, this message translates to:
  /// **'区域截图'**
  String get screenshotCapture;

  /// No description provided for @screenshotSelectionHint.
  ///
  /// In zh, this message translates to:
  /// **'单击选择窗口 · 拖动框选区域 · Esc 取消'**
  String get screenshotSelectionHint;

  /// No description provided for @screenshotAdjustHint.
  ///
  /// In zh, this message translates to:
  /// **'拖动移动 · 拖边调整 · Enter 复制 · Esc 取消'**
  String get screenshotAdjustHint;

  /// No description provided for @screenshotConfirm.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get screenshotConfirm;

  /// No description provided for @screenshotCopied.
  ///
  /// In zh, this message translates to:
  /// **'截图已复制，可自行粘贴使用'**
  String get screenshotCopied;

  /// No description provided for @screenshotPermissionDenied.
  ///
  /// In zh, this message translates to:
  /// **'请在系统设置 → 隐私与安全性中允许 Whisper 录制屏幕，然后重启 Whisper'**
  String get screenshotPermissionDenied;

  /// No description provided for @screenshotUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前环境无法进行区域截图；Linux 请检查桌面的截图 Portal 服务是否已安装并运行'**
  String get screenshotUnavailable;

  /// No description provided for @screenshotFailed.
  ///
  /// In zh, this message translates to:
  /// **'截图或复制到剪贴板失败，请重试'**
  String get screenshotFailed;

  /// No description provided for @screenshotShortcutTitle.
  ///
  /// In zh, this message translates to:
  /// **'截图快捷键'**
  String get screenshotShortcutTitle;

  /// No description provided for @screenshotShortcutDesc.
  ///
  /// In zh, this message translates to:
  /// **'框选屏幕区域后复制到剪贴板，由你自行粘贴；截图时保持 Whisper 窗口原样'**
  String get screenshotShortcutDesc;

  /// No description provided for @screenshotShortcutEnabled.
  ///
  /// In zh, this message translates to:
  /// **'启用全局快捷键'**
  String get screenshotShortcutEnabled;

  /// No description provided for @screenshotShortcutDisabled.
  ///
  /// In zh, this message translates to:
  /// **'已关闭 · 仍可使用截图按钮'**
  String get screenshotShortcutDisabled;

  /// No description provided for @screenshotShortcutUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'快捷键未注册 · 点击配置'**
  String get screenshotShortcutUnavailable;

  /// No description provided for @screenshotShortcutRecord.
  ///
  /// In zh, this message translates to:
  /// **'点击这里，然后按下组合键'**
  String get screenshotShortcutRecord;

  /// No description provided for @screenshotShortcutHint.
  ///
  /// In zh, this message translates to:
  /// **'使用 Ctrl、Alt 或 Command/Super 搭配字母、数字或 F1–F12；截图时按 Esc 取消，Wayland 下需在系统对话框确认快捷键'**
  String get screenshotShortcutHint;

  /// No description provided for @screenshotShortcutReset.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认快捷键'**
  String get screenshotShortcutReset;

  /// No description provided for @screenshotShortcutInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请使用有效组合键，并避开快捷发送的快捷键'**
  String get screenshotShortcutInvalid;

  /// No description provided for @screenshotShortcutFailed.
  ///
  /// In zh, this message translates to:
  /// **'快捷键保存失败，可能已被占用、被取消或桌面环境不支持，请尝试其他组合'**
  String get screenshotShortcutFailed;

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
  /// **'同步到当前可信设备；键鼠工作区中同步到已连接的工作区设备'**
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
  /// **'将删除所选消息，无法撤销。'**
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

  /// No description provided for @windowsLockScreenInput.
  ///
  /// In zh, this message translates to:
  /// **'锁屏与 UAC 时接收键鼠'**
  String get windowsLockScreenInput;

  /// No description provided for @windowsLockScreenInputHint.
  ///
  /// In zh, this message translates to:
  /// **'锁屏时可输入密码，开关控制 UAC 提示'**
  String get windowsLockScreenInputHint;

  /// No description provided for @windowsLockScreenInputDesc.
  ///
  /// In zh, this message translates to:
  /// **'将安装系统服务，让互信设备可在本机锁屏时输入密码。需要管理员确认。'**
  String get windowsLockScreenInputDesc;

  /// No description provided for @windowsLockScreenInputUninstallDesc.
  ///
  /// In zh, this message translates to:
  /// **'卸载后将无法操作本机的锁屏和 UAC 提示。需要管理员确认。'**
  String get windowsLockScreenInputUninstallDesc;

  /// No description provided for @windowsLockScreenInputNotInstalled.
  ///
  /// In zh, this message translates to:
  /// **'未安装'**
  String get windowsLockScreenInputNotInstalled;

  /// No description provided for @windowsLockScreenInputRunning.
  ///
  /// In zh, this message translates to:
  /// **'运行中'**
  String get windowsLockScreenInputRunning;

  /// No description provided for @windowsLockScreenInputStopped.
  ///
  /// In zh, this message translates to:
  /// **'未运行'**
  String get windowsLockScreenInputStopped;

  /// No description provided for @windowsLockScreenInputOutdated.
  ///
  /// In zh, this message translates to:
  /// **'需更新'**
  String get windowsLockScreenInputOutdated;

  /// No description provided for @windowsLockScreenInputInstall.
  ///
  /// In zh, this message translates to:
  /// **'安装'**
  String get windowsLockScreenInputInstall;

  /// No description provided for @windowsLockScreenInputRepair.
  ///
  /// In zh, this message translates to:
  /// **'修复'**
  String get windowsLockScreenInputRepair;

  /// No description provided for @windowsLockScreenInputUninstall.
  ///
  /// In zh, this message translates to:
  /// **'卸载'**
  String get windowsLockScreenInputUninstall;

  /// No description provided for @windowsLockScreenInputWorking.
  ///
  /// In zh, this message translates to:
  /// **'正在等待系统服务就绪…'**
  String get windowsLockScreenInputWorking;

  /// No description provided for @windowsLockScreenInputFailed.
  ///
  /// In zh, this message translates to:
  /// **'锁屏键鼠服务设置失败'**
  String get windowsLockScreenInputFailed;

  /// No description provided for @windowsElevatedInput.
  ///
  /// In zh, this message translates to:
  /// **'操作 UAC 提示'**
  String get windowsElevatedInput;

  /// No description provided for @windowsElevatedInputEnableDesc.
  ///
  /// In zh, this message translates to:
  /// **'开启后互信设备可操作 UAC 提示，但本机上以你身份运行的程序也能借此绕过 UAC。需要管理员确认。'**
  String get windowsElevatedInputEnableDesc;

  /// No description provided for @windowsElevatedInputDisableDesc.
  ///
  /// In zh, this message translates to:
  /// **'关闭后互信设备无法操作 UAC 提示，锁屏输入不受影响。需要管理员确认。'**
  String get windowsElevatedInputDisableDesc;

  /// No description provided for @windowsElevatedInputEnable.
  ///
  /// In zh, this message translates to:
  /// **'开启'**
  String get windowsElevatedInputEnable;

  /// No description provided for @windowsElevatedInputDisable.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get windowsElevatedInputDisable;

  /// No description provided for @windowsElevatedInputFailed.
  ///
  /// In zh, this message translates to:
  /// **'UAC 控制设置失败'**
  String get windowsElevatedInputFailed;

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
  /// **'开机自启动设置失败'**
  String get launchAtStartupFailed;

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

  /// No description provided for @fileTransferFailedNotice.
  ///
  /// In zh, this message translates to:
  /// **'文件传输失败'**
  String get fileTransferFailedNotice;

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

  /// No description provided for @remoteInputWorkspaceNoTargetsHint.
  ///
  /// In zh, this message translates to:
  /// **'连接并信任支持键鼠控制的桌面设备后会显示在这里'**
  String get remoteInputWorkspaceNoTargetsHint;

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

  /// No description provided for @remoteInputWorkspaceCanvasHint.
  ///
  /// In zh, this message translates to:
  /// **'拖动远端屏幕并贴近本机屏幕边缘'**
  String get remoteInputWorkspaceCanvasHint;

  /// No description provided for @remoteInputWorkspaceExitShortcut.
  ///
  /// In zh, this message translates to:
  /// **'按 {shortcut} 退出共享'**
  String remoteInputWorkspaceExitShortcut(String shortcut);

  /// No description provided for @remoteInputWorkspaceSelectTargetHint.
  ///
  /// In zh, this message translates to:
  /// **'从左侧选择至少一台被控设备'**
  String get remoteInputWorkspaceSelectTargetHint;

  /// No description provided for @remoteInputWorkspaceLocalBadge.
  ///
  /// In zh, this message translates to:
  /// **'本机'**
  String get remoteInputWorkspaceLocalBadge;

  /// No description provided for @remoteInputWorkspaceRemoteBadge.
  ///
  /// In zh, this message translates to:
  /// **'远端'**
  String get remoteInputWorkspaceRemoteBadge;

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

  /// No description provided for @remoteInputWorkspaceResolution.
  ///
  /// In zh, this message translates to:
  /// **'分辨率'**
  String get remoteInputWorkspaceResolution;

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
  /// **'搜索聊天记录'**
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
  /// **'收藏'**
  String get transferAssistantFavorites;

  /// No description provided for @transferAssistantRecent.
  ///
  /// In zh, this message translates to:
  /// **'最近消息'**
  String get transferAssistantRecent;

  /// No description provided for @transferAssistantAllMessages.
  ///
  /// In zh, this message translates to:
  /// **'全部消息'**
  String get transferAssistantAllMessages;

  /// No description provided for @transferAssistantExpandMessage.
  ///
  /// In zh, this message translates to:
  /// **'展开全文'**
  String get transferAssistantExpandMessage;

  /// No description provided for @transferAssistantCollapseMessage.
  ///
  /// In zh, this message translates to:
  /// **'收起全文'**
  String get transferAssistantCollapseMessage;

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

  /// No description provided for @quickSendTitle.
  ///
  /// In zh, this message translates to:
  /// **'快捷发送'**
  String get quickSendTitle;

  /// No description provided for @quickSendTargets.
  ///
  /// In zh, this message translates to:
  /// **'发送到'**
  String get quickSendTargets;

  /// No description provided for @quickSendNoConnectedDevices.
  ///
  /// In zh, this message translates to:
  /// **'还没有已连接的设备，连接后即可发送'**
  String get quickSendNoConnectedDevices;

  /// No description provided for @quickSendMoreFiles.
  ///
  /// In zh, this message translates to:
  /// **'另有 {count} 个文件'**
  String quickSendMoreFiles(int count);

  /// No description provided for @quickSendLater.
  ///
  /// In zh, this message translates to:
  /// **'稍后'**
  String get quickSendLater;

  /// No description provided for @quickSendSend.
  ///
  /// In zh, this message translates to:
  /// **'发送'**
  String get quickSendSend;

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

  /// No description provided for @connectFirstDevice.
  ///
  /// In zh, this message translates to:
  /// **'连接你的第一台设备'**
  String get connectFirstDevice;

  /// No description provided for @deviceConnectionGuide.
  ///
  /// In zh, this message translates to:
  /// **'在另一台设备打开 Whisper，并连接同一个 Wi-Fi 或局域网。附近设备会自动显示在列表中。'**
  String get deviceConnectionGuide;

  /// No description provided for @manualConnectAction.
  ///
  /// In zh, this message translates to:
  /// **'手动输入地址'**
  String get manualConnectAction;

  /// No description provided for @deviceDiscoveryHelp.
  ///
  /// In zh, this message translates to:
  /// **'没有发现设备？可尝试二维码连接，或在两台设备的系统设置中允许本地网络访问。'**
  String get deviceDiscoveryHelp;

  /// No description provided for @deviceOffline.
  ///
  /// In zh, this message translates to:
  /// **'离线设备'**
  String get deviceOffline;

  /// No description provided for @serverPortInUse.
  ///
  /// In zh, this message translates to:
  /// **'端口 {port} 正被占用。请关闭其他 Whisper 实例，或在设置中更换端口后重试。'**
  String serverPortInUse(int port);

  /// No description provided for @serverPermissionDenied.
  ///
  /// In zh, this message translates to:
  /// **'系统拒绝了网络监听。请允许 Whisper 访问本地网络，并检查防火墙设置后重试。'**
  String get serverPermissionDenied;

  /// No description provided for @serverUnavailableHelp.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法接收连接。请确认网络已连接，并检查本地网络权限及防火墙后重试。'**
  String get serverUnavailableHelp;

  /// No description provided for @updatePackageSaved.
  ///
  /// In zh, this message translates to:
  /// **'安装包已保存在：\n{path}\n你可以稍后重新安装。'**
  String updatePackageSaved(String path);

  /// No description provided for @updateInstalledRestart.
  ///
  /// In zh, this message translates to:
  /// **'更新已安装，重新打开 Whisper 后生效。'**
  String get updateInstalledRestart;

  /// No description provided for @castReceiverTitle.
  ///
  /// In zh, this message translates to:
  /// **'电视投屏'**
  String get castReceiverTitle;

  /// No description provided for @castReceiverHint.
  ///
  /// In zh, this message translates to:
  /// **'开启后，在同一局域网的视频 App 中选择本机设备名称即可投屏。'**
  String get castReceiverHint;

  /// No description provided for @castReceiverStarting.
  ///
  /// In zh, this message translates to:
  /// **'正在启动…'**
  String get castReceiverStarting;

  /// No description provided for @castReceiverNoLan.
  ///
  /// In zh, this message translates to:
  /// **'没有可用的局域网地址，请连接网络后重新开启。'**
  String get castReceiverNoLan;

  /// No description provided for @castReceiverStartupFailed.
  ///
  /// In zh, this message translates to:
  /// **'投屏服务未能启动，请关闭后重新开启。'**
  String get castReceiverStartupFailed;

  /// No description provided for @castPlay.
  ///
  /// In zh, this message translates to:
  /// **'播放'**
  String get castPlay;

  /// No description provided for @castPause.
  ///
  /// In zh, this message translates to:
  /// **'暂停'**
  String get castPause;

  /// No description provided for @castMute.
  ///
  /// In zh, this message translates to:
  /// **'静音'**
  String get castMute;

  /// No description provided for @castUnmute.
  ///
  /// In zh, this message translates to:
  /// **'取消静音'**
  String get castUnmute;

  /// No description provided for @castFullscreen.
  ///
  /// In zh, this message translates to:
  /// **'全屏'**
  String get castFullscreen;

  /// No description provided for @videoPlaybackFailed.
  ///
  /// In zh, this message translates to:
  /// **'视频播放失败，请重试或使用其他应用打开。'**
  String get videoPlaybackFailed;

  /// No description provided for @castPlaybackFailed.
  ///
  /// In zh, this message translates to:
  /// **'视频播放失败，请重试或在手机上重新投屏。'**
  String get castPlaybackFailed;

  /// No description provided for @castControlFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作未完成，请重试。'**
  String get castControlFailed;

  /// No description provided for @castRequestTitle.
  ///
  /// In zh, this message translates to:
  /// **'允许这台设备投屏吗？'**
  String get castRequestTitle;

  /// No description provided for @castRequestMessage.
  ///
  /// In zh, this message translates to:
  /// **'来自 {address} 的设备希望在本机播放视频。'**
  String castRequestMessage(String address);

  /// No description provided for @castRequestCountdown.
  ///
  /// In zh, this message translates to:
  /// **'{seconds} 秒后自动允许，你也可以拒绝。'**
  String castRequestCountdown(int seconds);

  /// No description provided for @castRequestDeny.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get castRequestDeny;

  /// No description provided for @castRequestAllow.
  ///
  /// In zh, this message translates to:
  /// **'允许投屏'**
  String get castRequestAllow;

  /// No description provided for @castExitFullscreen.
  ///
  /// In zh, this message translates to:
  /// **'退出全屏'**
  String get castExitFullscreen;

  /// No description provided for @castSeek.
  ///
  /// In zh, this message translates to:
  /// **'播放进度'**
  String get castSeek;

  /// No description provided for @castVolume.
  ///
  /// In zh, this message translates to:
  /// **'音量'**
  String get castVolume;

  /// No description provided for @mobileControlPointer.
  ///
  /// In zh, this message translates to:
  /// **'鼠标'**
  String get mobileControlPointer;

  /// No description provided for @mobileControlKeysTab.
  ///
  /// In zh, this message translates to:
  /// **'键盘'**
  String get mobileControlKeysTab;

  /// No description provided for @mobileControlTextTab.
  ///
  /// In zh, this message translates to:
  /// **'文字'**
  String get mobileControlTextTab;

  /// No description provided for @mobileControlSettings.
  ///
  /// In zh, this message translates to:
  /// **'指针设置'**
  String get mobileControlSettings;

  /// No description provided for @mobileControlLiftHint.
  ///
  /// In zh, this message translates to:
  /// **'松手暂停，调整握姿后继续。'**
  String get mobileControlLiftHint;

  /// No description provided for @mobileControlDragHint.
  ///
  /// In zh, this message translates to:
  /// **'按住左键即可拖拽。'**
  String get mobileControlDragHint;

  /// No description provided for @mobileControlPrecisionHint.
  ///
  /// In zh, this message translates to:
  /// **'慢转精细定位，快转大幅移动。'**
  String get mobileControlPrecisionHint;

  /// No description provided for @mobileControlCalibrationRetry.
  ///
  /// In zh, this message translates to:
  /// **'请保持手机静止，再试一次校准。'**
  String get mobileControlCalibrationRetry;

  /// No description provided for @mobileControlStartShort.
  ///
  /// In zh, this message translates to:
  /// **'开始'**
  String get mobileControlStartShort;

  /// No description provided for @mobileControlMotionStart.
  ///
  /// In zh, this message translates to:
  /// **'开启体感'**
  String get mobileControlMotionStart;

  /// No description provided for @mobileControlMotionPause.
  ///
  /// In zh, this message translates to:
  /// **'暂停体感'**
  String get mobileControlMotionPause;

  /// No description provided for @mobileControlMotionOnHint.
  ///
  /// In zh, this message translates to:
  /// **'转腕即可移动，点此暂停。'**
  String get mobileControlMotionOnHint;

  /// No description provided for @mobileControlMotionOffHint.
  ///
  /// In zh, this message translates to:
  /// **'点一下开启，无需一直按住屏幕。'**
  String get mobileControlMotionOffHint;

  /// No description provided for @mobileControlTarget.
  ///
  /// In zh, this message translates to:
  /// **'控制目标'**
  String get mobileControlTarget;

  /// No description provided for @mobileControlTargetHint.
  ///
  /// In zh, this message translates to:
  /// **'切换后需重新开始控制。'**
  String get mobileControlTargetHint;

  /// No description provided for @mobileControlPointerSpeed.
  ///
  /// In zh, this message translates to:
  /// **'触控板移动速度'**
  String get mobileControlPointerSpeed;

  /// No description provided for @mobileControlScrollSpeed.
  ///
  /// In zh, this message translates to:
  /// **'滚轮滑动速度'**
  String get mobileControlScrollSpeed;

  /// No description provided for @mobileControlScrollRail.
  ///
  /// In zh, this message translates to:
  /// **'滑动\n滚动'**
  String get mobileControlScrollRail;

  /// No description provided for @mobileControlPermissionDesktop.
  ///
  /// In zh, this message translates to:
  /// **'请在电脑上允许远程控制后重试。Linux 需要接受系统的远程控制授权。'**
  String get mobileControlPermissionDesktop;

  /// No description provided for @mobileControlLinuxTextHint.
  ///
  /// In zh, this message translates to:
  /// **'Linux 只能发送电脑当前键盘布局支持的字符。中文和 emoji 请通过虚拟键盘配合电脑输入法输入。不支持的文字会保留在草稿中。'**
  String get mobileControlLinuxTextHint;

  /// No description provided for @manualConnectAddressInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效的局域网 IP 或 .local 地址'**
  String get manualConnectAddressInvalid;

  /// No description provided for @manualConnectPortInvalid.
  ///
  /// In zh, this message translates to:
  /// **'端口范围为 1–65535'**
  String get manualConnectPortInvalid;

  /// No description provided for @transferStorageHelp.
  ///
  /// In zh, this message translates to:
  /// **'无法保存，请检查接收端空间和目录权限'**
  String get transferStorageHelp;

  /// No description provided for @transferSourceHelp.
  ///
  /// In zh, this message translates to:
  /// **'源文件无法读取，请重新选择文件'**
  String get transferSourceHelp;

  /// No description provided for @transferIntegrityHelp.
  ///
  /// In zh, this message translates to:
  /// **'文件校验未通过，请重试传输'**
  String get transferIntegrityHelp;

  /// No description provided for @transferQueueHelp.
  ///
  /// In zh, this message translates to:
  /// **'接收端任务较多，请稍后重试'**
  String get transferQueueHelp;

  /// No description provided for @transferTrustHelp.
  ///
  /// In zh, this message translates to:
  /// **'请重新确认设备信任后再发送'**
  String get transferTrustHelp;

  /// No description provided for @transferRetryHelp.
  ///
  /// In zh, this message translates to:
  /// **'传输未完成，请确认设备已连接后重试'**
  String get transferRetryHelp;

  /// No description provided for @mobileControlTransportHelp.
  ///
  /// In zh, this message translates to:
  /// **'控制连接已中断，请确认电脑上的 Whisper 正在运行，再重新开始。'**
  String get mobileControlTransportHelp;

  /// No description provided for @mobileControlInjectionHelp.
  ///
  /// In zh, this message translates to:
  /// **'电脑未能执行输入，请检查系统控制权限后重新开始。'**
  String get mobileControlInjectionHelp;

  /// No description provided for @clipboardAutoSyncAndroidDesc.
  ///
  /// In zh, this message translates to:
  /// **'回到 Whisper 后，将新复制的文字同步到当前可信设备'**
  String get clipboardAutoSyncAndroidDesc;

  /// No description provided for @historyLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'历史记录未能加载，点按重试'**
  String get historyLoadFailed;

  /// No description provided for @deleteReceivedFilesDesc.
  ///
  /// In zh, this message translates to:
  /// **'同时删除接收的本地文件，发送的源文件会保留。'**
  String get deleteReceivedFilesDesc;

  /// No description provided for @keepReceivedFiles.
  ///
  /// In zh, this message translates to:
  /// **'保留接收的文件'**
  String get keepReceivedFiles;

  /// No description provided for @messageDeleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'删除未完成，请重试。'**
  String get messageDeleteFailed;

  /// No description provided for @connectionQrTab.
  ///
  /// In zh, this message translates to:
  /// **'二维码'**
  String get connectionQrTab;

  /// No description provided for @connectionScanTab.
  ///
  /// In zh, this message translates to:
  /// **'扫一扫'**
  String get connectionScanTab;

  /// No description provided for @connectionAddressTab.
  ///
  /// In zh, this message translates to:
  /// **'IP / 端口'**
  String get connectionAddressTab;

  /// No description provided for @connectionAddressLabel.
  ///
  /// In zh, this message translates to:
  /// **'IP 地址或主机名'**
  String get connectionAddressLabel;

  /// No description provided for @connectionDetailsTab.
  ///
  /// In zh, this message translates to:
  /// **'本机信息'**
  String get connectionDetailsTab;

  /// No description provided for @connectionAddressHint.
  ///
  /// In zh, this message translates to:
  /// **'填写对方 Whisper 首页显示的地址和端口。两台设备需连接同一局域网。'**
  String get connectionAddressHint;

  /// No description provided for @qrCopyFailed.
  ///
  /// In zh, this message translates to:
  /// **'复制失败，请重试'**
  String get qrCopyFailed;

  /// No description provided for @attachFile.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get attachFile;

  /// No description provided for @attachFolder.
  ///
  /// In zh, this message translates to:
  /// **'文件夹'**
  String get attachFolder;

  /// No description provided for @folderFileCount.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, =0{空文件夹} other{{count} 个文件}}'**
  String folderFileCount(int count);

  /// No description provided for @folderSkippedCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 项未传'**
  String folderSkippedCount(int count);

  /// No description provided for @folderSkippedTitle.
  ///
  /// In zh, this message translates to:
  /// **'未传输的项目'**
  String get folderSkippedTitle;

  /// No description provided for @folderSkippedMore.
  ///
  /// In zh, this message translates to:
  /// **'另有 {count} 项的详情需要在对方设备上查看'**
  String folderSkippedMore(int count);

  /// No description provided for @folderSkipSymlink.
  ///
  /// In zh, this message translates to:
  /// **'链接不会被发送'**
  String get folderSkipSymlink;

  /// No description provided for @folderSkipSpecial.
  ///
  /// In zh, this message translates to:
  /// **'不是普通文件'**
  String get folderSkipSpecial;

  /// No description provided for @folderSkipInvalidName.
  ///
  /// In zh, this message translates to:
  /// **'名称在其他系统上不可用'**
  String get folderSkipInvalidName;

  /// No description provided for @folderSkipPathTooLong.
  ///
  /// In zh, this message translates to:
  /// **'路径过长或层级过深'**
  String get folderSkipPathTooLong;

  /// No description provided for @folderSkipTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'文件过大'**
  String get folderSkipTooLarge;

  /// No description provided for @folderSkipUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'无法读取'**
  String get folderSkipUnreadable;

  /// No description provided for @folderSkipSourceUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'发送时已被移动、修改或无法读取'**
  String get folderSkipSourceUnavailable;

  /// No description provided for @folderSkipWriteFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法保存到这台设备'**
  String get folderSkipWriteFailed;

  /// No description provided for @folderSkipNameCollision.
  ///
  /// In zh, this message translates to:
  /// **'与同目录的另一项只有大小写不同'**
  String get folderSkipNameCollision;

  /// No description provided for @folderSkipIntegrity.
  ///
  /// In zh, this message translates to:
  /// **'校验未通过'**
  String get folderSkipIntegrity;

  /// No description provided for @folderSendFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法发送这个文件夹'**
  String get folderSendFailed;

  /// No description provided for @folderSendUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'对方的 Whisper 版本不支持接收文件夹，请先升级对方'**
  String get folderSendUnsupported;

  /// No description provided for @folderSendInvalidName.
  ///
  /// In zh, this message translates to:
  /// **'文件夹名称在其他系统上不可用，请改名后再发'**
  String get folderSendInvalidName;

  /// No description provided for @folderSendUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'无法读取这个文件夹'**
  String get folderSendUnreadable;

  /// No description provided for @folderSendTooManyEntries.
  ///
  /// In zh, this message translates to:
  /// **'文件夹内超过 {limit} 项，请分批发送'**
  String folderSendTooManyEntries(int limit);

  /// No description provided for @folderSendTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'文件夹超过 1 TB，无法发送'**
  String get folderSendTooLarge;

  /// No description provided for @folderFileProgress.
  ///
  /// In zh, this message translates to:
  /// **'{done}/{total} 个文件'**
  String folderFileProgress(int done, int total);

  /// No description provided for @windowStreamTitle.
  ///
  /// In zh, this message translates to:
  /// **'手机应用'**
  String get windowStreamTitle;

  /// No description provided for @windowStreamConnecting.
  ///
  /// In zh, this message translates to:
  /// **'正在连接…'**
  String get windowStreamConnecting;

  /// No description provided for @windowStreamPaused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停，点按继续'**
  String get windowStreamPaused;

  /// No description provided for @windowStreamReconnecting.
  ///
  /// In zh, this message translates to:
  /// **'正在重新连接…'**
  String get windowStreamReconnecting;

  /// No description provided for @windowStreamDisplaced.
  ///
  /// In zh, this message translates to:
  /// **'已回到手机上，点按拿回来'**
  String get windowStreamDisplaced;

  /// No description provided for @windowStreamSecureBlocked.
  ///
  /// In zh, this message translates to:
  /// **'此应用不允许投屏'**
  String get windowStreamSecureBlocked;

  /// No description provided for @windowStreamAppExited.
  ///
  /// In zh, this message translates to:
  /// **'应用已退出'**
  String get windowStreamAppExited;

  /// No description provided for @windowStreamDisconnected.
  ///
  /// In zh, this message translates to:
  /// **'连接已断开，可以关闭这个窗口'**
  String get windowStreamDisconnected;

  /// No description provided for @windowStreamNoDevice.
  ///
  /// In zh, this message translates to:
  /// **'没有发现手机'**
  String get windowStreamNoDevice;

  /// No description provided for @windowStreamNoDeviceHint.
  ///
  /// In zh, this message translates to:
  /// **'用数据线连接手机，或在手机的开发者选项里打开“无线调试”。'**
  String get windowStreamNoDeviceHint;

  /// No description provided for @windowStreamUnauthorized.
  ///
  /// In zh, this message translates to:
  /// **'请在手机上允许这台电脑调试'**
  String get windowStreamUnauthorized;

  /// No description provided for @windowStreamDeviceOffline.
  ///
  /// In zh, this message translates to:
  /// **'手机暂时连不上，请重新插拔数据线或重新打开无线调试'**
  String get windowStreamDeviceOffline;

  /// No description provided for @windowStreamAdbMissing.
  ///
  /// In zh, this message translates to:
  /// **'没有找到 adb，请先安装 Android 平台工具'**
  String get windowStreamAdbMissing;

  /// No description provided for @windowStreamAdbFailed.
  ///
  /// In zh, this message translates to:
  /// **'adb 服务没能启动'**
  String get windowStreamAdbFailed;

  /// No description provided for @windowStreamUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'这台电脑暂时还不能打开手机应用窗口'**
  String get windowStreamUnsupported;

  /// No description provided for @windowStreamRunningApps.
  ///
  /// In zh, this message translates to:
  /// **'正在运行'**
  String get windowStreamRunningApps;

  /// No description provided for @windowStreamAllApps.
  ///
  /// In zh, this message translates to:
  /// **'所有应用'**
  String get windowStreamAllApps;

  /// No description provided for @windowStreamSearchApps.
  ///
  /// In zh, this message translates to:
  /// **'搜索应用'**
  String get windowStreamSearchApps;

  /// No description provided for @windowStreamLoadingApps.
  ///
  /// In zh, this message translates to:
  /// **'正在读取应用…'**
  String get windowStreamLoadingApps;

  /// No description provided for @windowStreamOnDesktop.
  ///
  /// In zh, this message translates to:
  /// **'在桌面上'**
  String get windowStreamOnDesktop;

  /// No description provided for @windowStreamShowSystemApps.
  ///
  /// In zh, this message translates to:
  /// **'显示系统应用'**
  String get windowStreamShowSystemApps;

  /// No description provided for @windowStreamRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get windowStreamRetry;

  /// No description provided for @windowStreamInjectDenied.
  ///
  /// In zh, this message translates to:
  /// **'小米手机还要在开发者选项里打开“USB 调试（安全设置）”，然后重启手机'**
  String get windowStreamInjectDenied;

  /// No description provided for @windowStreamAndroidTooOld.
  ///
  /// In zh, this message translates to:
  /// **'需要 Android 10 或更新的系统'**
  String get windowStreamAndroidTooOld;

  /// No description provided for @windowStreamOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能打开这个应用'**
  String get windowStreamOpenFailed;

  /// No description provided for @windowStreamNoApps.
  ///
  /// In zh, this message translates to:
  /// **'没有读到应用'**
  String get windowStreamNoApps;

  /// No description provided for @windowStreamSpaceTitle.
  ///
  /// In zh, this message translates to:
  /// **'流转'**
  String get windowStreamSpaceTitle;

  /// No description provided for @windowStreamRecents.
  ///
  /// In zh, this message translates to:
  /// **'最近'**
  String get windowStreamRecents;

  /// No description provided for @windowStreamWindows.
  ///
  /// In zh, this message translates to:
  /// **'窗口'**
  String get windowStreamWindows;

  /// No description provided for @windowStreamApps.
  ///
  /// In zh, this message translates to:
  /// **'应用'**
  String get windowStreamApps;

  /// No description provided for @windowStreamViaUsb.
  ///
  /// In zh, this message translates to:
  /// **'USB 连接'**
  String get windowStreamViaUsb;

  /// No description provided for @windowStreamViaWifi.
  ///
  /// In zh, this message translates to:
  /// **'无线调试'**
  String get windowStreamViaWifi;

  /// No description provided for @windowStreamViaWhisper.
  ///
  /// In zh, this message translates to:
  /// **'已连接'**
  String get windowStreamViaWhisper;

  /// No description provided for @windowStreamStatusLive.
  ///
  /// In zh, this message translates to:
  /// **'直播'**
  String get windowStreamStatusLive;

  /// No description provided for @windowStreamStatusPaused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get windowStreamStatusPaused;

  /// No description provided for @windowStreamStatusConnecting.
  ///
  /// In zh, this message translates to:
  /// **'连接中'**
  String get windowStreamStatusConnecting;

  /// No description provided for @windowStreamStatusEnded.
  ///
  /// In zh, this message translates to:
  /// **'已断开'**
  String get windowStreamStatusEnded;

  /// No description provided for @windowStreamPause.
  ///
  /// In zh, this message translates to:
  /// **'暂停'**
  String get windowStreamPause;

  /// No description provided for @windowStreamResume.
  ///
  /// In zh, this message translates to:
  /// **'继续'**
  String get windowStreamResume;

  /// No description provided for @windowStreamClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get windowStreamClose;

  /// No description provided for @windowStreamNoWindows.
  ///
  /// In zh, this message translates to:
  /// **'还没有打开的窗口'**
  String get windowStreamNoWindows;

  /// No description provided for @windowStreamNoWindowsHint.
  ///
  /// In zh, this message translates to:
  /// **'点开一个应用或最近任务，它会出现在这里'**
  String get windowStreamNoWindowsHint;

  /// No description provided for @windowStreamNoDevices.
  ///
  /// In zh, this message translates to:
  /// **'还没有可用的设备'**
  String get windowStreamNoDevices;

  /// No description provided for @windowStreamNoDevicesHintDesktop.
  ///
  /// In zh, this message translates to:
  /// **'用数据线连接安卓手机，或在手机的开发者选项里打开“无线调试”。'**
  String get windowStreamNoDevicesHintDesktop;

  /// No description provided for @windowStreamNoDevicesHintMobile.
  ///
  /// In zh, this message translates to:
  /// **'在 Mac 上打开 Whisper，并和这台设备互相信任后，Mac 的窗口会出现在这里。'**
  String get windowStreamNoDevicesHintMobile;

  /// No description provided for @windowStreamLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能读取这台设备的应用'**
  String get windowStreamLoadFailed;

  /// No description provided for @windowStreamBackToSpace.
  ///
  /// In zh, this message translates to:
  /// **'返回流转'**
  String get windowStreamBackToSpace;

  /// No description provided for @windowStreamKeyboard.
  ///
  /// In zh, this message translates to:
  /// **'键盘'**
  String get windowStreamKeyboard;

  /// No description provided for @windowStreamNoRecents.
  ///
  /// In zh, this message translates to:
  /// **'这台设备上没有正在运行的应用'**
  String get windowStreamNoRecents;

  /// No description provided for @windowStreamSourceLocked.
  ///
  /// In zh, this message translates to:
  /// **'这台电脑已锁屏，解锁后才能流转它的窗口'**
  String get windowStreamSourceLocked;

  /// No description provided for @windowStreamCapturePermission.
  ///
  /// In zh, this message translates to:
  /// **'这台电脑还没允许 Whisper 录屏，请在它的“系统设置 › 隐私与安全性 › 录屏”里打开'**
  String get windowStreamCapturePermission;

  /// No description provided for @windowStreamUntrusted.
  ///
  /// In zh, this message translates to:
  /// **'这台手机的 Whisper 还没和本机配对。在手机上打开 Whisper，连接本机并确认配对后才能流转'**
  String get windowStreamUntrusted;

  /// No description provided for @windowStreamWhisperMissing.
  ///
  /// In zh, this message translates to:
  /// **'这台手机上没有可用的 Whisper。装上最新版 Whisper 并和本机配对后才能流转'**
  String get windowStreamWhisperMissing;

  /// No description provided for @windowStreamNotPaired.
  ///
  /// In zh, this message translates to:
  /// **'未配对'**
  String get windowStreamNotPaired;

  /// No description provided for @windowStreamOpenHere.
  ///
  /// In zh, this message translates to:
  /// **'在本机打开'**
  String get windowStreamOpenHere;

  /// No description provided for @windowStreamSendTo.
  ///
  /// In zh, this message translates to:
  /// **'送到 {device}'**
  String windowStreamSendTo(String device);

  /// No description provided for @windowStreamSendHint.
  ///
  /// In zh, this message translates to:
  /// **'选一个本机窗口送到 {device}。点开后窗口会挪到那台设备上，不再占这台电脑的屏幕；那边关掉后自动回到原处。'**
  String windowStreamSendHint(String device);

  /// No description provided for @windowStreamSent.
  ///
  /// In zh, this message translates to:
  /// **'已送到 {device}，在那台设备上点开即可查看'**
  String windowStreamSent(String device);

  /// No description provided for @windowStreamSendFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能送过去，请确认那台设备连着本机'**
  String get windowStreamSendFailed;

  /// No description provided for @windowStreamSendUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'{device} 上的 Whisper 需要连接本机并更新到最新版，才能接收窗口'**
  String windowStreamSendUnavailable(String device);

  /// No description provided for @windowStreamNoLocalWindows.
  ///
  /// In zh, this message translates to:
  /// **'本机没有可以送出去的窗口'**
  String get windowStreamNoLocalWindows;

  /// No description provided for @windowStreamOfferTitle.
  ///
  /// In zh, this message translates to:
  /// **'{device} 送来了一个窗口'**
  String windowStreamOfferTitle(String device);

  /// No description provided for @windowStreamOfferView.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get windowStreamOfferView;

  /// No description provided for @windowStreamOfferFrom.
  ///
  /// In zh, this message translates to:
  /// **'来自 {device}'**
  String windowStreamOfferFrom(String device);

  /// No description provided for @remoteFilesTitle.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get remoteFilesTitle;

  /// No description provided for @remoteFilesOfDevice.
  ///
  /// In zh, this message translates to:
  /// **'{device} 的文件'**
  String remoteFilesOfDevice(String device);

  /// No description provided for @remoteFilesThisDevice.
  ///
  /// In zh, this message translates to:
  /// **'本机'**
  String get remoteFilesThisDevice;

  /// No description provided for @remoteFilesWaiting.
  ///
  /// In zh, this message translates to:
  /// **'正在等 {device} 允许…'**
  String remoteFilesWaiting(String device);

  /// No description provided for @remoteFilesDenied.
  ///
  /// In zh, this message translates to:
  /// **'{device} 没有允许浏览文件'**
  String remoteFilesDenied(String device);

  /// No description provided for @remoteFilesOffline.
  ///
  /// In zh, this message translates to:
  /// **'{device} 现在没有连接本机'**
  String remoteFilesOffline(String device);

  /// No description provided for @remoteFilesUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'{device} 上的 Whisper 需要更新到最新版才能浏览文件'**
  String remoteFilesUnsupported(String device);

  /// No description provided for @remoteFilesEmptyFolder.
  ///
  /// In zh, this message translates to:
  /// **'这个文件夹是空的'**
  String get remoteFilesEmptyFolder;

  /// No description provided for @remoteFilesCopyTo.
  ///
  /// In zh, this message translates to:
  /// **'拷贝到 {target}'**
  String remoteFilesCopyTo(String target);

  /// No description provided for @remoteFilesNewFolder.
  ///
  /// In zh, this message translates to:
  /// **'新建文件夹'**
  String get remoteFilesNewFolder;

  /// No description provided for @remoteFilesFolderName.
  ///
  /// In zh, this message translates to:
  /// **'文件夹名称'**
  String get remoteFilesFolderName;

  /// No description provided for @remoteFilesRename.
  ///
  /// In zh, this message translates to:
  /// **'重命名'**
  String get remoteFilesRename;

  /// No description provided for @remoteFilesMoveToTrash.
  ///
  /// In zh, this message translates to:
  /// **'移到废纸篓'**
  String get remoteFilesMoveToTrash;

  /// No description provided for @remoteFilesDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get remoteFilesDelete;

  /// No description provided for @remoteFilesDeleteForever.
  ///
  /// In zh, this message translates to:
  /// **'要永久删除这 {count} 项吗？这台设备没有废纸篓，删除后无法恢复。'**
  String remoteFilesDeleteForever(int count);

  /// No description provided for @remoteFilesCopyStarted.
  ///
  /// In zh, this message translates to:
  /// **'正在拷贝 {count} 项'**
  String remoteFilesCopyStarted(int count);

  /// No description provided for @remoteFilesFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作没有完成'**
  String get remoteFilesFailed;

  /// No description provided for @remoteFilesNameExists.
  ///
  /// In zh, this message translates to:
  /// **'这里已经有同名的文件或文件夹'**
  String get remoteFilesNameExists;

  /// No description provided for @remoteFilesShowHidden.
  ///
  /// In zh, this message translates to:
  /// **'显示隐藏文件'**
  String get remoteFilesShowHidden;

  /// No description provided for @remoteFilesItemCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 项'**
  String remoteFilesItemCount(int count);

  /// No description provided for @remoteFilesSelected.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 项'**
  String remoteFilesSelected(int count);

  /// No description provided for @remoteFilesCreate.
  ///
  /// In zh, this message translates to:
  /// **'新建'**
  String get remoteFilesCreate;

  /// No description provided for @remoteFilesDone.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get remoteFilesDone;

  /// No description provided for @remoteFilesDropHint.
  ///
  /// In zh, this message translates to:
  /// **'拖到这里，拷贝到 {device}'**
  String remoteFilesDropHint(String device);

  /// No description provided for @remoteFilesPlaceRoot.
  ///
  /// In zh, this message translates to:
  /// **'主目录'**
  String get remoteFilesPlaceRoot;

  /// No description provided for @remoteFilesPlaceStorage.
  ///
  /// In zh, this message translates to:
  /// **'内部存储'**
  String get remoteFilesPlaceStorage;

  /// No description provided for @remoteFilesPlaceDesktop.
  ///
  /// In zh, this message translates to:
  /// **'桌面'**
  String get remoteFilesPlaceDesktop;

  /// No description provided for @remoteFilesPlaceDocuments.
  ///
  /// In zh, this message translates to:
  /// **'文稿'**
  String get remoteFilesPlaceDocuments;

  /// No description provided for @remoteFilesPlaceDownloads.
  ///
  /// In zh, this message translates to:
  /// **'下载'**
  String get remoteFilesPlaceDownloads;

  /// No description provided for @remoteFilesPlacePictures.
  ///
  /// In zh, this message translates to:
  /// **'图片'**
  String get remoteFilesPlacePictures;

  /// No description provided for @remoteFilesPlaceCamera.
  ///
  /// In zh, this message translates to:
  /// **'相机'**
  String get remoteFilesPlaceCamera;

  /// No description provided for @remoteFilesPlaceMovies.
  ///
  /// In zh, this message translates to:
  /// **'影片'**
  String get remoteFilesPlaceMovies;

  /// No description provided for @remoteFilesPlaceMusic.
  ///
  /// In zh, this message translates to:
  /// **'音乐'**
  String get remoteFilesPlaceMusic;

  /// No description provided for @remoteFilesPromptTitle.
  ///
  /// In zh, this message translates to:
  /// **'{device} 想浏览你的文件'**
  String remoteFilesPromptTitle(String device);

  /// No description provided for @remoteFilesPromptBodyDesktop.
  ///
  /// In zh, this message translates to:
  /// **'允许后，它能看到你的主目录，并在里面拷贝、新建、重命名和删除文件。删除的文件会进废纸篓。'**
  String get remoteFilesPromptBodyDesktop;

  /// No description provided for @remoteFilesPromptBodyPhone.
  ///
  /// In zh, this message translates to:
  /// **'允许后，它能看到这台手机的内部存储，并在里面拷贝、新建、重命名和删除文件。删除前会再问一次。'**
  String get remoteFilesPromptBodyPhone;

  /// No description provided for @remoteFilesDeny.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get remoteFilesDeny;

  /// No description provided for @remoteFilesAllowOnce.
  ///
  /// In zh, this message translates to:
  /// **'允许这一次'**
  String get remoteFilesAllowOnce;

  /// No description provided for @remoteFilesAllowAlways.
  ///
  /// In zh, this message translates to:
  /// **'始终允许'**
  String get remoteFilesAllowAlways;

  /// No description provided for @windowStreamTouchBlockedTitle.
  ///
  /// In zh, this message translates to:
  /// **'{device} 现在点不动了'**
  String windowStreamTouchBlockedTitle(String device);

  /// No description provided for @windowStreamTouchBlockedBody.
  ///
  /// In zh, this message translates to:
  /// **'{app} 留在后台的一个页面挡住了手机屏幕，手机收不到触摸。关掉这个页面就能恢复，{app} 不会被卸载，账号和记录都还在。'**
  String windowStreamTouchBlockedBody(String app);

  /// No description provided for @windowStreamTouchBlockedFix.
  ///
  /// In zh, this message translates to:
  /// **'关掉这个页面'**
  String get windowStreamTouchBlockedFix;

  /// No description provided for @windowStreamTouchBlockedLater.
  ///
  /// In zh, this message translates to:
  /// **'以后再说'**
  String get windowStreamTouchBlockedLater;

  /// No description provided for @windowStreamTouchBlockedFixed.
  ///
  /// In zh, this message translates to:
  /// **'好了，手机可以操作了'**
  String get windowStreamTouchBlockedFixed;

  /// No description provided for @remoteFilesFavorites.
  ///
  /// In zh, this message translates to:
  /// **'个人收藏'**
  String get remoteFilesFavorites;

  /// No description provided for @remoteFilesLocations.
  ///
  /// In zh, this message translates to:
  /// **'位置'**
  String get remoteFilesLocations;

  /// No description provided for @remoteFilesBrowse.
  ///
  /// In zh, this message translates to:
  /// **'浏览'**
  String get remoteFilesBrowse;

  /// No description provided for @remoteFilesWaitingAllow.
  ///
  /// In zh, this message translates to:
  /// **'请在 {device} 上点“允许”'**
  String remoteFilesWaitingAllow(String device);

  /// No description provided for @remoteFilesWaitingDetail.
  ///
  /// In zh, this message translates to:
  /// **'Whisper 正在那台设备上询问是否让本机浏览文件。'**
  String get remoteFilesWaitingDetail;

  /// No description provided for @remoteFilesAskAgain.
  ///
  /// In zh, this message translates to:
  /// **'再问一次'**
  String get remoteFilesAskAgain;

  /// No description provided for @remoteFilesColumnName.
  ///
  /// In zh, this message translates to:
  /// **'名称'**
  String get remoteFilesColumnName;

  /// No description provided for @remoteFilesColumnModified.
  ///
  /// In zh, this message translates to:
  /// **'修改日期'**
  String get remoteFilesColumnModified;

  /// No description provided for @remoteFilesColumnSize.
  ///
  /// In zh, this message translates to:
  /// **'大小'**
  String get remoteFilesColumnSize;

  /// No description provided for @remoteFilesColumnKind.
  ///
  /// In zh, this message translates to:
  /// **'种类'**
  String get remoteFilesColumnKind;

  /// No description provided for @remoteFilesKindFolder.
  ///
  /// In zh, this message translates to:
  /// **'文件夹'**
  String get remoteFilesKindFolder;

  /// No description provided for @remoteFilesKindImage.
  ///
  /// In zh, this message translates to:
  /// **'图像'**
  String get remoteFilesKindImage;

  /// No description provided for @remoteFilesKindVideo.
  ///
  /// In zh, this message translates to:
  /// **'影片'**
  String get remoteFilesKindVideo;

  /// No description provided for @remoteFilesKindAudio.
  ///
  /// In zh, this message translates to:
  /// **'音频'**
  String get remoteFilesKindAudio;

  /// No description provided for @remoteFilesKindDocument.
  ///
  /// In zh, this message translates to:
  /// **'文稿'**
  String get remoteFilesKindDocument;

  /// No description provided for @remoteFilesKindArchive.
  ///
  /// In zh, this message translates to:
  /// **'归档'**
  String get remoteFilesKindArchive;

  /// No description provided for @remoteFilesKindCode.
  ///
  /// In zh, this message translates to:
  /// **'源代码'**
  String get remoteFilesKindCode;

  /// No description provided for @remoteFilesKindApp.
  ///
  /// In zh, this message translates to:
  /// **'应用程序'**
  String get remoteFilesKindApp;

  /// No description provided for @remoteFilesKindOther.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get remoteFilesKindOther;

  /// No description provided for @remoteFilesKindNamed.
  ///
  /// In zh, this message translates to:
  /// **'{ext} {kind}'**
  String remoteFilesKindNamed(String ext, String kind);

  /// No description provided for @remoteFilesViewList.
  ///
  /// In zh, this message translates to:
  /// **'列表'**
  String get remoteFilesViewList;

  /// No description provided for @remoteFilesViewIcons.
  ///
  /// In zh, this message translates to:
  /// **'图标'**
  String get remoteFilesViewIcons;

  /// No description provided for @remoteFilesSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get remoteFilesSearch;

  /// No description provided for @remoteFilesNoResults.
  ///
  /// In zh, this message translates to:
  /// **'没有找到“{query}”'**
  String remoteFilesNoResults(String query);

  /// No description provided for @remoteFilesForward.
  ///
  /// In zh, this message translates to:
  /// **'前进'**
  String get remoteFilesForward;

  /// No description provided for @remoteFilesOpen.
  ///
  /// In zh, this message translates to:
  /// **'打开'**
  String get remoteFilesOpen;

  /// No description provided for @remoteFilesCopy.
  ///
  /// In zh, this message translates to:
  /// **'拷贝'**
  String get remoteFilesCopy;

  /// No description provided for @remoteFilesPaste.
  ///
  /// In zh, this message translates to:
  /// **'粘贴 {count} 项'**
  String remoteFilesPaste(int count);

  /// No description provided for @remoteFilesRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get remoteFilesRefresh;

  /// No description provided for @remoteFilesStatusSelected.
  ///
  /// In zh, this message translates to:
  /// **'已选择 {selected} 项，共 {count} 项'**
  String remoteFilesStatusSelected(int selected, int count);

  /// No description provided for @remoteFilesCopyProgress.
  ///
  /// In zh, this message translates to:
  /// **'正在拷贝 {count} 项 · {percent}%'**
  String remoteFilesCopyProgress(int count, int percent);

  /// No description provided for @remoteFilesCopyDone.
  ///
  /// In zh, this message translates to:
  /// **'已拷贝 {count} 项'**
  String remoteFilesCopyDone(int count);

  /// No description provided for @remoteFilesCopyPartly.
  ///
  /// In zh, this message translates to:
  /// **'{failed} 项没有拷贝成功'**
  String remoteFilesCopyPartly(int failed);

  /// No description provided for @remoteFilesSameDevice.
  ///
  /// In zh, this message translates to:
  /// **'已经在这台设备上了'**
  String get remoteFilesSameDevice;

  /// No description provided for @remoteFilesBetweenOthers.
  ///
  /// In zh, this message translates to:
  /// **'只能在本机和另一台设备之间拷贝'**
  String get remoteFilesBetweenOthers;

  /// No description provided for @remoteFilesOpenFirst.
  ///
  /// In zh, this message translates to:
  /// **'先打开 {device} 的文件'**
  String remoteFilesOpenFirst(String device);

  /// No description provided for @remoteFilesUntitledFolder.
  ///
  /// In zh, this message translates to:
  /// **'未命名文件夹'**
  String get remoteFilesUntitledFolder;

  /// No description provided for @remoteFilesSelect.
  ///
  /// In zh, this message translates to:
  /// **'选择'**
  String get remoteFilesSelect;

  /// No description provided for @remoteFilesSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get remoteFilesSelectAll;

  /// No description provided for @remoteFilesCopyToMenu.
  ///
  /// In zh, this message translates to:
  /// **'拷贝到…'**
  String get remoteFilesCopyToMenu;

  /// No description provided for @remoteFilesCopyHere.
  ///
  /// In zh, this message translates to:
  /// **'拷贝到这里'**
  String get remoteFilesCopyHere;

  /// No description provided for @remoteFilesChooseDestination.
  ///
  /// In zh, this message translates to:
  /// **'选好位置后点“拷贝到这里”'**
  String get remoteFilesChooseDestination;

  /// No description provided for @remoteFilesToday.
  ///
  /// In zh, this message translates to:
  /// **'今天 {time}'**
  String remoteFilesToday(String time);

  /// No description provided for @remoteFilesYesterday.
  ///
  /// In zh, this message translates to:
  /// **'昨天 {time}'**
  String remoteFilesYesterday(String time);

  /// No description provided for @remoteFilesCopyToSubmenu.
  ///
  /// In zh, this message translates to:
  /// **'拷贝到'**
  String get remoteFilesCopyToSubmenu;

  /// No description provided for @remoteFilesPasteInto.
  ///
  /// In zh, this message translates to:
  /// **'粘贴到“{name}”'**
  String remoteFilesPasteInto(String name);

  /// No description provided for @remoteFilesPastePlain.
  ///
  /// In zh, this message translates to:
  /// **'粘贴'**
  String get remoteFilesPastePlain;

  /// No description provided for @remoteFilesSortBy.
  ///
  /// In zh, this message translates to:
  /// **'排序方式'**
  String get remoteFilesSortBy;

  /// No description provided for @remoteFilesMore.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get remoteFilesMore;

  /// No description provided for @remoteFilesClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭文件'**
  String get remoteFilesClose;

  /// No description provided for @remoteFilesClipboardPreparing.
  ///
  /// In zh, this message translates to:
  /// **'正在取回 {count} 项，好了就能在访达等应用里粘贴'**
  String remoteFilesClipboardPreparing(int count);

  /// No description provided for @remoteFilesClipboardReady.
  ///
  /// In zh, this message translates to:
  /// **'可以在访达等应用里粘贴了'**
  String get remoteFilesClipboardReady;

  /// No description provided for @windowStreamTextSize.
  ///
  /// In zh, this message translates to:
  /// **'文字大小'**
  String get windowStreamTextSize;

  /// No description provided for @windowStreamOpenHereDetail.
  ///
  /// In zh, this message translates to:
  /// **'用 {device} 上的应用'**
  String windowStreamOpenHereDetail(String device);

  /// No description provided for @windowStreamSendToDetail.
  ///
  /// In zh, this message translates to:
  /// **'把窗口挪到 {device} 上'**
  String windowStreamSendToDetail(String device);

  /// No description provided for @toolbarMoreTools.
  ///
  /// In zh, this message translates to:
  /// **'更多功能'**
  String get toolbarMoreTools;

  /// No description provided for @toolbarFewerTools.
  ///
  /// In zh, this message translates to:
  /// **'收起'**
  String get toolbarFewerTools;

  /// No description provided for @windowStreamStreaming.
  ///
  /// In zh, this message translates to:
  /// **'流转中'**
  String get windowStreamStreaming;

  /// No description provided for @windowStreamCloseWindow.
  ///
  /// In zh, this message translates to:
  /// **'关闭窗口'**
  String get windowStreamCloseWindow;

  /// No description provided for @windowStreamCloseFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能关闭这个窗口'**
  String get windowStreamCloseFailed;

  /// No description provided for @windowStreamOfferIgnore.
  ///
  /// In zh, this message translates to:
  /// **'忽略'**
  String get windowStreamOfferIgnore;

  /// No description provided for @deviceDetailsTitle.
  ///
  /// In zh, this message translates to:
  /// **'设备详情'**
  String get deviceDetailsTitle;

  /// No description provided for @deviceFeaturesSection.
  ///
  /// In zh, this message translates to:
  /// **'功能'**
  String get deviceFeaturesSection;

  /// No description provided for @deviceFeatureFlowDetail.
  ///
  /// In zh, this message translates to:
  /// **'用它的应用和窗口，或把窗口送过去'**
  String get deviceFeatureFlowDetail;

  /// No description provided for @deviceFeatureFilesDetail.
  ///
  /// In zh, this message translates to:
  /// **'浏览和拷贝它的文件'**
  String get deviceFeatureFilesDetail;

  /// No description provided for @deviceFeatureNeedsConnection.
  ///
  /// In zh, this message translates to:
  /// **'连接后可用'**
  String get deviceFeatureNeedsConnection;

  /// No description provided for @windowStreamSwitcherRotate.
  ///
  /// In zh, this message translates to:
  /// **'旋转'**
  String get windowStreamSwitcherRotate;

  /// No description provided for @remoteFilesCopyStarting.
  ///
  /// In zh, this message translates to:
  /// **'正在准备…'**
  String get remoteFilesCopyStarting;

  /// No description provided for @remoteFilesCopyItems.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个项目'**
  String remoteFilesCopyItems(int count);

  /// No description provided for @remoteFilesCopyToDevice.
  ///
  /// In zh, this message translates to:
  /// **'拷贝到 {device} 的“{folder}”'**
  String remoteFilesCopyToDevice(String device, String folder);

  /// No description provided for @remoteFilesCopyFromDevice.
  ///
  /// In zh, this message translates to:
  /// **'从 {device} 拷贝到“{folder}”'**
  String remoteFilesCopyFromDevice(String device, String folder);

  /// No description provided for @remoteFilesCopyLeft.
  ///
  /// In zh, this message translates to:
  /// **'剩余 {time}'**
  String remoteFilesCopyLeft(String time);

  /// No description provided for @remoteFilesSeconds.
  ///
  /// In zh, this message translates to:
  /// **'{count} 秒'**
  String remoteFilesSeconds(int count);

  /// No description provided for @remoteFilesMinutes.
  ///
  /// In zh, this message translates to:
  /// **'{count} 分钟'**
  String remoteFilesMinutes(int count);

  /// No description provided for @remoteFilesHours.
  ///
  /// In zh, this message translates to:
  /// **'{count} 小时'**
  String remoteFilesHours(int count);

  /// No description provided for @remoteFilesCopyItemsDone.
  ///
  /// In zh, this message translates to:
  /// **'{done}/{total} 项'**
  String remoteFilesCopyItemsDone(int done, int total);

  /// No description provided for @remoteFilesCopyFilesMoved.
  ///
  /// In zh, this message translates to:
  /// **'已传 {count} 个文件'**
  String remoteFilesCopyFilesMoved(int count);

  /// No description provided for @remoteFilesCopyWaiting.
  ///
  /// In zh, this message translates to:
  /// **'等待 {device} 重新连接…'**
  String remoteFilesCopyWaiting(String device);

  /// No description provided for @remoteFilesCopyPaused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get remoteFilesCopyPaused;

  /// No description provided for @remoteFilesCopyFailedShort.
  ///
  /// In zh, this message translates to:
  /// **'没有拷贝成功'**
  String get remoteFilesCopyFailedShort;

  /// No description provided for @remoteFilesCopyCanceledShort.
  ///
  /// In zh, this message translates to:
  /// **'已停止'**
  String get remoteFilesCopyCanceledShort;

  /// No description provided for @remoteFilesCopyDoneShort.
  ///
  /// In zh, this message translates to:
  /// **'已拷贝'**
  String get remoteFilesCopyDoneShort;

  /// No description provided for @remoteFilesCopyResume.
  ///
  /// In zh, this message translates to:
  /// **'继续'**
  String get remoteFilesCopyResume;

  /// No description provided for @remoteFilesCopyRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get remoteFilesCopyRetry;

  /// No description provided for @remoteFilesCopyStop.
  ///
  /// In zh, this message translates to:
  /// **'停止拷贝'**
  String get remoteFilesCopyStop;

  /// No description provided for @remoteFilesCopyShowAll.
  ///
  /// In zh, this message translates to:
  /// **'查看全部传输'**
  String get remoteFilesCopyShowAll;

  /// No description provided for @remoteFilesCopyMore.
  ///
  /// In zh, this message translates to:
  /// **'还有 {count} 个拷贝'**
  String remoteFilesCopyMore(int count);

  /// No description provided for @remoteFilesCopyAlready.
  ///
  /// In zh, this message translates to:
  /// **'这些项目已经在拷贝到这里了'**
  String get remoteFilesCopyAlready;

  /// No description provided for @remoteFilesTransfers.
  ///
  /// In zh, this message translates to:
  /// **'传输'**
  String get remoteFilesTransfers;

  /// No description provided for @remoteFilesTransfersEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有拷贝'**
  String get remoteFilesTransfersEmpty;

  /// No description provided for @remoteFilesTransfersEmptyDetail.
  ///
  /// In zh, this message translates to:
  /// **'在这里拷贝的文件，进度和结果都会列在这里'**
  String get remoteFilesTransfersEmptyDetail;

  /// No description provided for @remoteFilesTransfersClear.
  ///
  /// In zh, this message translates to:
  /// **'清除已结束'**
  String get remoteFilesTransfersClear;

  /// No description provided for @remoteFilesTransfersActive.
  ///
  /// In zh, this message translates to:
  /// **'进行中'**
  String get remoteFilesTransfersActive;

  /// No description provided for @remoteFilesTransfersRecent.
  ///
  /// In zh, this message translates to:
  /// **'已结束'**
  String get remoteFilesTransfersRecent;

  /// No description provided for @remoteFilesCopyRemove.
  ///
  /// In zh, this message translates to:
  /// **'从列表中移除'**
  String get remoteFilesCopyRemove;

  /// No description provided for @remoteFilesCopyReveal.
  ///
  /// In zh, this message translates to:
  /// **'在文件中显示'**
  String get remoteFilesCopyReveal;

  /// No description provided for @remoteFilesDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'永久删除 {count} 个项目？'**
  String remoteFilesDeleteTitle(int count);

  /// No description provided for @remoteFilesDeleteDetail.
  ///
  /// In zh, this message translates to:
  /// **'{device} 没有废纸篓，删除后无法恢复。'**
  String remoteFilesDeleteDetail(String device);

  /// No description provided for @remoteFilesAndMore.
  ///
  /// In zh, this message translates to:
  /// **'还有 {count} 项'**
  String remoteFilesAndMore(int count);

  /// Toast when the same files are pasted into the same folder again right after a copy finished
  ///
  /// In zh, this message translates to:
  /// **'刚刚已经拷贝过了'**
  String get remoteFilesCopyJustDone;

  /// Window stream: the source desktop is locked; shown on the viewing device.
  ///
  /// In zh, this message translates to:
  /// **'{device} 已锁屏，解锁后才能流转它的窗口'**
  String windowStreamHostLocked(String device);

  /// Window stream: a Mac source lacks the Screen Recording permission; tells the viewer what to do on the Mac.
  ///
  /// In zh, this message translates to:
  /// **'{device} 还没允许 Whisper 录屏。请在那台 Mac 的“系统设置 › 隐私与安全性 › 录屏与系统录音”里打开 Whisper'**
  String windowStreamHostPermissionMac(String device);

  /// Window stream: a Windows or Linux source refused screen capture (privacy setting).
  ///
  /// In zh, this message translates to:
  /// **'{device} 的系统不允许 Whisper 录制窗口。请在那台电脑的隐私设置里允许 Whisper 录屏，然后再试一次'**
  String windowStreamHostPermission(String device);

  /// Window stream: a Linux (GNOME) source's Whisper Shell helper is not active yet; it becomes active after logging out and in once.
  ///
  /// In zh, this message translates to:
  /// **'{device} 还差一步：请在那台电脑上注销并重新登录一次，之后就能流转它的窗口'**
  String windowStreamHostHelper(String device);

  /// Window stream: a Linux source runs a desktop other than GNOME on Wayland (KDE, X11).
  ///
  /// In zh, this message translates to:
  /// **'{device} 的桌面暂不支持流转窗口，需要 GNOME（Wayland）'**
  String windowStreamHostDesktopUnsupported(String device);

  /// Window stream: a Windows source's window belongs to an elevated (administrator) process.
  ///
  /// In zh, this message translates to:
  /// **'这个窗口以管理员身份运行，Whisper 无法流转它。请在 {device} 上以普通身份重新打开这个应用'**
  String windowStreamHostElevated(String device);

  /// Window stream: the window excludes itself from screen capture (DRM, password managers).
  ///
  /// In zh, this message translates to:
  /// **'这个窗口不允许录屏，无法在这里显示'**
  String get windowStreamHostProtected;

  /// Window stream: the source could not open a video encoder.
  ///
  /// In zh, this message translates to:
  /// **'{device} 没能开始编码画面，请稍后再试'**
  String windowStreamHostEncoder(String device);

  /// Window stream: the source has no usable capture backend (generic).
  ///
  /// In zh, this message translates to:
  /// **'{device} 暂时还不能流转窗口。请把那台设备上的 Whisper 更新到最新版'**
  String windowStreamHostUnsupported(String device);

  /// Window stream: a Windows source lacks Windows Graphics Capture.
  ///
  /// In zh, this message translates to:
  /// **'{device} 需要 Windows 10（1903）或更新的系统才能流转窗口'**
  String windowStreamHostUnsupportedWindows(String device);

  /// Window stream: a Mac source is older than macOS 12.3 (no ScreenCaptureKit).
  ///
  /// In zh, this message translates to:
  /// **'{device} 需要 macOS 12.3 或更新的系统才能流转窗口'**
  String windowStreamHostUnsupportedMac(String device);

  /// Window stream: stands in for {device} when the source's name is unknown (lower case; the sentence start is capitalised in code).
  ///
  /// In zh, this message translates to:
  /// **'那台设备'**
  String get windowStreamThatDevice;

  /// File browser: a Windows drive with a volume label, e.g. "Data (D:)".
  ///
  /// In zh, this message translates to:
  /// **'{name} ({drive}:)'**
  String remoteFilesPlaceDrive(String name, String drive);

  /// File browser: a Windows drive without a volume label, as Explorer names it.
  ///
  /// In zh, this message translates to:
  /// **'本地磁盘 ({drive}:)'**
  String remoteFilesPlaceLocalDisk(String drive);

  /// File browser: a removable Windows drive without a volume label.
  ///
  /// In zh, this message translates to:
  /// **'U 盘 ({drive}:)'**
  String remoteFilesPlaceRemovableDisk(String drive);

  /// File browser: an iPhone's or iPad's root, the app's own Documents folder (Files › On My iPhone › Whisper).
  ///
  /// In zh, this message translates to:
  /// **'Whisper 文件夹'**
  String get remoteFilesPlaceAppFolder;

  /// Island: files being sent from a conversation, under the file name
  ///
  /// In zh, this message translates to:
  /// **'发送给 {device}'**
  String islandTransferTo(String device);

  /// Island: files being received in a conversation, under the file name
  ///
  /// In zh, this message translates to:
  /// **'来自 {device}'**
  String islandTransferFrom(String device);

  /// Island: files going both ways at once
  ///
  /// In zh, this message translates to:
  /// **'正在收发'**
  String get islandTransferMixed;

  /// Island: title when several files are under way
  ///
  /// In zh, this message translates to:
  /// **'{count} 个文件'**
  String islandTransferFiles(int count);

  /// Island: conversation files all sent
  ///
  /// In zh, this message translates to:
  /// **'已发送'**
  String get islandTransferSent;

  /// Island: conversation files all received
  ///
  /// In zh, this message translates to:
  /// **'已收到'**
  String get islandTransferReceived;

  /// Island: some conversation files failed
  ///
  /// In zh, this message translates to:
  /// **'没有传完'**
  String get islandTransferFailed;

  /// Island button (screen-reader label): cancel the conversation transfers under way
  ///
  /// In zh, this message translates to:
  /// **'停止传输'**
  String get islandTransferStop;

  /// Island: this phone, acting as a speaker for another device, is paused
  ///
  /// In zh, this message translates to:
  /// **'已暂停播放'**
  String get islandAudioPaused;

  /// Island: speaker playback is starting or resuming
  ///
  /// In zh, this message translates to:
  /// **'正在连接…'**
  String get islandAudioStarting;

  /// Island: speaker playback ended (shown for a moment)
  ///
  /// In zh, this message translates to:
  /// **'已断开'**
  String get islandAudioEnded;

  /// Island: this phone's apps are shown on another device
  ///
  /// In zh, this message translates to:
  /// **'正在流转到 {device}'**
  String islandStreamedTitle(String device);

  /// Island: under 'Streaming to {device}'
  ///
  /// In zh, this message translates to:
  /// **'{count} 个窗口正在那台设备上显示，可以被操作'**
  String islandStreamedWindows(int count);

  /// Island button: stop streaming this phone's apps (same as the notification's button)
  ///
  /// In zh, this message translates to:
  /// **'停止流转'**
  String get islandStreamedStop;

  /// Island: waiting for the streamed windows to go back
  ///
  /// In zh, this message translates to:
  /// **'正在停止…'**
  String get islandStreamedStopping;

  /// Island: streaming of this phone stopped (shown for a moment)
  ///
  /// In zh, this message translates to:
  /// **'流转已结束'**
  String get islandStreamedEnded;

  /// Island: stands in for the viewer's name when it is not known
  ///
  /// In zh, this message translates to:
  /// **'另一台设备'**
  String get islandStreamedOtherDevice;

  /// Island card: more activities than are listed
  ///
  /// In zh, this message translates to:
  /// **'还有 {count} 项'**
  String islandMore(int count);

  /// Screen-reader hint on the small island
  ///
  /// In zh, this message translates to:
  /// **'轻点展开，向上轻扫收起'**
  String get islandHint;

  /// File manager menu item / toolbar tooltip that opens the share-link sheet for the selected local items
  ///
  /// In zh, this message translates to:
  /// **'创建共享链接…'**
  String get shareLinkMenuCreate;

  /// Title of the sheet that creates a LAN download link
  ///
  /// In zh, this message translates to:
  /// **'创建共享链接'**
  String get shareLinkCreateTitle;

  /// Explains what a share link does, under the sheet title
  ///
  /// In zh, this message translates to:
  /// **'同一局域网里的设备用浏览器打开链接就能下载，不用装 Whisper。'**
  String get shareLinkCreateDetail;

  /// Name of a share link made of several files and folders (shown on the web page and used for the zip)
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 个项目}}'**
  String shareLinkDefaultName(int count);

  /// Label of the field for the path part of the link, e.g. the 'k7qm' in http://host:port/k7qm
  ///
  /// In zh, this message translates to:
  /// **'路由'**
  String get shareLinkRoute;

  /// Helper text under the route field; the placeholder shows a generated route
  ///
  /// In zh, this message translates to:
  /// **'不填就用上面这个随机路由'**
  String get shareLinkRouteHelp;

  /// Switch that makes the generated route 4 characters long
  ///
  /// In zh, this message translates to:
  /// **'简短路由'**
  String get shareLinkShortRoute;

  /// Subtitle of the short-route switch
  ///
  /// In zh, this message translates to:
  /// **'4 个字符，方便口头告诉别人'**
  String get shareLinkShortRouteDetail;

  /// Label of the optional password field; also the placeholder of the password box on the web page
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get shareLinkPassword;

  /// Placeholder of the optional password field
  ///
  /// In zh, this message translates to:
  /// **'可不填'**
  String get shareLinkPasswordOptional;

  /// Tooltip of the eye button in the password field
  ///
  /// In zh, this message translates to:
  /// **'显示密码'**
  String get shareLinkShowPassword;

  /// Tooltip of the eye button in the password field while the password is visible
  ///
  /// In zh, this message translates to:
  /// **'隐藏密码'**
  String get shareLinkHidePassword;

  /// Primary button of the share-link sheet
  ///
  /// In zh, this message translates to:
  /// **'创建链接'**
  String get shareLinkCreate;

  /// Error under the route field
  ///
  /// In zh, this message translates to:
  /// **'已经有链接在用这个路由了'**
  String get shareLinkRouteTaken;

  /// Error under the route field
  ///
  /// In zh, this message translates to:
  /// **'路由要 2–32 个字符，只能用小写字母、数字、- 和 _'**
  String get shareLinkRouteInvalid;

  /// Error under the route field when the user typed a reserved word such as zip
  ///
  /// In zh, this message translates to:
  /// **'这个路由留作他用了，换一个吧'**
  String get shareLinkRouteReserved;

  /// Error when the selected files were moved or deleted before the link was created
  ///
  /// In zh, this message translates to:
  /// **'要共享的文件已经不在了'**
  String get shareLinkItemsMissing;

  /// Generic error when creating a share link fails
  ///
  /// In zh, this message translates to:
  /// **'没能创建链接'**
  String get shareLinkCreateFailed;

  /// Title of the sheet after the link was created
  ///
  /// In zh, this message translates to:
  /// **'链接已创建'**
  String get shareLinkReady;

  /// Button / tooltip that copies the link address
  ///
  /// In zh, this message translates to:
  /// **'复制链接'**
  String get shareLinkCopy;

  /// The copy button's label for a moment after copying
  ///
  /// In zh, this message translates to:
  /// **'已复制'**
  String get shareLinkCopied;

  /// Caption under the QR code
  ///
  /// In zh, this message translates to:
  /// **'也可以用手机相机扫一扫'**
  String get shareLinkScanHint;

  /// Tooltip of the menu that switches between this device's LAN addresses when it has several
  ///
  /// In zh, this message translates to:
  /// **'选择网络地址'**
  String get shareLinkAddressPicker;

  /// Note in the result sheet when the file server switch is off
  ///
  /// In zh, this message translates to:
  /// **'服务已关闭，打开后链接才能访问'**
  String get shareLinkServiceOffNote;

  /// Shown instead of an address when this device has no LAN address
  ///
  /// In zh, this message translates to:
  /// **'没有连上局域网，其他设备暂时打不开'**
  String get shareLinkNoNetwork;

  /// Badge / tooltip for a link that needs a password
  ///
  /// In zh, this message translates to:
  /// **'有密码'**
  String get shareLinkPasswordProtected;

  /// Sidebar row and title of the page that manages share links
  ///
  /// In zh, this message translates to:
  /// **'共享链接'**
  String get shareLinksTitle;

  /// Subtitle of the share links row on phones
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 个链接开着}}'**
  String shareLinksActiveCount(int count);

  /// Name of the switch that turns the HTTP file server for share links on or off
  ///
  /// In zh, this message translates to:
  /// **'文件服务'**
  String get shareLinksService;

  /// File server status
  ///
  /// In zh, this message translates to:
  /// **'正在运行，端口 {port}'**
  String shareLinksServiceRunning(String port);

  /// File server status when it is switched on but no link is enabled
  ///
  /// In zh, this message translates to:
  /// **'没有开着的链接，端口已关闭'**
  String get shareLinksServiceIdle;

  /// File server status when switched off
  ///
  /// In zh, this message translates to:
  /// **'已关闭。链接都还在，只是暂时打不开。'**
  String get shareLinksServiceOff;

  /// File server status
  ///
  /// In zh, this message translates to:
  /// **'正在启动…'**
  String get shareLinksServiceStarting;

  /// File server status when no port could be opened
  ///
  /// In zh, this message translates to:
  /// **'端口 {from}–{to} 都被占用了'**
  String shareLinksServicePortsBusy(String from, String to);

  /// File server status when it failed to start for another reason
  ///
  /// In zh, this message translates to:
  /// **'启动失败'**
  String get shareLinksServiceFailed;

  /// Status of a share link
  ///
  /// In zh, this message translates to:
  /// **'已开启'**
  String get shareLinkStatusOn;

  /// Status of a share link
  ///
  /// In zh, this message translates to:
  /// **'已关闭'**
  String get shareLinkStatusOff;

  /// Status of a share link whose files were all moved or deleted
  ///
  /// In zh, this message translates to:
  /// **'文件不见了'**
  String get shareLinkStatusMissing;

  /// Status of a share link when some of its files were moved or deleted
  ///
  /// In zh, this message translates to:
  /// **'部分文件不见了'**
  String get shareLinkStatusPartlyMissing;

  /// How many times the link's pages were opened
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 次访问}}'**
  String shareLinkVisits(int count);

  /// How many downloads were started from the link
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 次下载}}'**
  String shareLinkDownloads(int count);

  /// When the link was last opened; time is like 今天 10:24
  ///
  /// In zh, this message translates to:
  /// **'最近访问 {time}'**
  String shareLinkLastVisit(String time);

  /// Shown instead of the last visit time
  ///
  /// In zh, this message translates to:
  /// **'还没人打开过'**
  String get shareLinkNeverVisited;

  /// How much data the link has served, e.g. 1.2 GB
  ///
  /// In zh, this message translates to:
  /// **'已发送 {size}'**
  String shareLinkBytesServed(String size);

  /// Button / tooltip that shows the link's QR code
  ///
  /// In zh, this message translates to:
  /// **'二维码'**
  String get shareLinkQr;

  /// Tooltip / semantics of a link's switch
  ///
  /// In zh, this message translates to:
  /// **'开启链接'**
  String get shareLinkTurnOn;

  /// Tooltip / semantics of a link's switch
  ///
  /// In zh, this message translates to:
  /// **'关闭链接'**
  String get shareLinkTurnOff;

  /// Tooltip of a link's delete button
  ///
  /// In zh, this message translates to:
  /// **'删除链接'**
  String get shareLinkDelete;

  /// Delete confirmation title
  ///
  /// In zh, this message translates to:
  /// **'删除这个共享链接？'**
  String get shareLinkDeleteTitle;

  /// Delete confirmation body
  ///
  /// In zh, this message translates to:
  /// **'这个地址会马上失效，本机上的文件不受影响。'**
  String get shareLinkDeleteDetail;

  /// Empty state title
  ///
  /// In zh, this message translates to:
  /// **'还没有共享链接'**
  String get shareLinksEmpty;

  /// Empty state detail on desktop
  ///
  /// In zh, this message translates to:
  /// **'在本机的文件或文件夹上右键，选“创建共享链接…”。也可以先选好多个再右键。'**
  String get shareLinksEmptyDetailDesktop;

  /// Empty state detail on phones
  ///
  /// In zh, this message translates to:
  /// **'在本机的文件或文件夹上长按，选“创建共享链接…”。也可以多选后从底部选。'**
  String get shareLinksEmptyDetailPhone;

  /// Web page: main button of a shared file
  ///
  /// In zh, this message translates to:
  /// **'下载'**
  String get shareWebDownload;

  /// Web page: opens a previewable file (picture, movie, PDF…) in the browser
  ///
  /// In zh, this message translates to:
  /// **'在浏览器中打开'**
  String get shareWebOpen;

  /// Web page: downloads everything shown as one zip
  ///
  /// In zh, this message translates to:
  /// **'全部下载（.zip）'**
  String get shareWebDownloadAll;

  /// Web page: label of a folder row's download button
  ///
  /// In zh, this message translates to:
  /// **'下载为 .zip'**
  String get shareWebDownloadZip;

  /// Web page: how many items a folder holds
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 项}}'**
  String shareWebItemCount(int count);

  /// Web page
  ///
  /// In zh, this message translates to:
  /// **'这个文件夹是空的'**
  String get shareWebEmptyFolder;

  /// Web page: when a shared file was last changed
  ///
  /// In zh, this message translates to:
  /// **'修改于 {date}'**
  String shareWebModified(String date);

  /// Web page footer
  ///
  /// In zh, this message translates to:
  /// **'来自 {device} · 用 Whisper 共享'**
  String shareWebFooter(String device);

  /// Web page for an unknown or switched-off link
  ///
  /// In zh, this message translates to:
  /// **'这个链接打不开'**
  String get shareWebNotFoundTitle;

  /// Web page for an unknown or switched-off link
  ///
  /// In zh, this message translates to:
  /// **'链接可能已经关闭，或者地址输错了。请找分享的人确认一下。'**
  String get shareWebNotFoundDetail;

  /// Web page when a shared file was moved or deleted
  ///
  /// In zh, this message translates to:
  /// **'文件不见了'**
  String get shareWebMissingTitle;

  /// Web page when a shared file was moved or deleted
  ///
  /// In zh, this message translates to:
  /// **'它可能被移动、改名或删除了。'**
  String get shareWebMissingDetail;

  /// Web page: link from an error page to the link's first page
  ///
  /// In zh, this message translates to:
  /// **'回到共享内容'**
  String get shareWebBack;

  /// Web page title for a password-protected link
  ///
  /// In zh, this message translates to:
  /// **'需要密码'**
  String get shareWebPasswordTitle;

  /// Web page for a password-protected link
  ///
  /// In zh, this message translates to:
  /// **'这个共享链接设置了密码。'**
  String get shareWebPasswordDetail;

  /// Web page: submit button of the password form
  ///
  /// In zh, this message translates to:
  /// **'继续'**
  String get shareWebContinue;

  /// Web page: error after a wrong password
  ///
  /// In zh, this message translates to:
  /// **'密码不对，再试一次'**
  String get shareWebPasswordWrong;

  /// Web page when a client is rate-limited
  ///
  /// In zh, this message translates to:
  /// **'尝试次数太多'**
  String get shareWebTooManyTitle;

  /// Web page when a client is rate-limited
  ///
  /// In zh, this message translates to:
  /// **'请等 1 分钟再试。'**
  String get shareWebTooManyDetail;

  /// Web page for an unexpected server error
  ///
  /// In zh, this message translates to:
  /// **'出了点问题'**
  String get shareWebErrorTitle;

  /// Web page for an unexpected server error
  ///
  /// In zh, this message translates to:
  /// **'请稍后再试。'**
  String get shareWebErrorDetail;

  /// Overlay message for a streamed window on Linux when no H.264 decoder can be loaded (native WSN_WINDOW_DECODE_ERROR with a = 1). Dart should set it with wsn_surface_set_visual(WSN_VISUAL_ERROR, message).
  ///
  /// In zh, this message translates to:
  /// **'无法显示画面：这台电脑缺少 FFmpeg 视频解码库'**
  String get windowStreamDecoderMissing;

  /// Tooltip and accessibility label of the volume button in a streamed window (desktop).
  ///
  /// In zh, this message translates to:
  /// **'音量'**
  String get windowStreamVolume;

  /// Mute toggle in a streamed window's volume control.
  ///
  /// In zh, this message translates to:
  /// **'静音'**
  String get windowStreamMute;

  /// Unmute toggle in a streamed window's volume control.
  ///
  /// In zh, this message translates to:
  /// **'取消静音'**
  String get windowStreamUnmute;

  /// Overlay in a streamed window when the same window was opened on another device (a window is shown in one place at a time); the window then closes.
  ///
  /// In zh, this message translates to:
  /// **'这个窗口已在另一台设备上打开'**
  String get windowStreamMovedAway;

  /// Under a window card in Flow: the window is shown on another device right now; opening it here moves it here.
  ///
  /// In zh, this message translates to:
  /// **'正在 {device} 上显示'**
  String flowTaskOpenOn(String device);

  /// Short label of the share-link button in the phone file manager's selection bar
  ///
  /// In zh, this message translates to:
  /// **'共享链接'**
  String get shareLinkBarAction;

  /// Window-stream source failure shown to the viewer: the host desktop cannot capture windows at all (reason code = WSN_CAPTURE_ERROR_UNSUPPORTED from the Windows source; Windows is supported, so this is only for very old builds or missing Graphics.Capture).
  ///
  /// In zh, this message translates to:
  /// **'这台电脑不支持窗口流转'**
  String get windowStreamSourceErrorDesktopUnsupported;

  /// Window-stream source: the chosen window belongs to a higher-integrity (administrator) process on Windows, so input can't be injected and it is excluded. Maps from a notFound/permission reason when the target was filtered out as elevated.
  ///
  /// In zh, this message translates to:
  /// **'这个窗口以管理员身份运行，无法流转'**
  String get windowStreamSourceErrorElevated;

  /// Window-stream source status note (not an error): the app refused to stage off-screen or produced no frames after moving, so it is mirrored in its real on-screen position instead of the background. Shown on the host, or logged. {app} is the application name.
  ///
  /// In zh, this message translates to:
  /// **'{app} 不支持在后台运行，正在原位置流转'**
  String windowStreamSourceNoteStagedInPlace(String app);

  /// Linux (GNOME) settings row title: the GNOME Shell extension that lets other devices show this computer's windows.
  ///
  /// In zh, this message translates to:
  /// **'窗口流转组件'**
  String get gnomeHelperTitle;

  /// Linux settings row subtitle: why the helper exists and that the first install needs one logout/login.
  ///
  /// In zh, this message translates to:
  /// **'其他设备流转本机窗口需要一个 GNOME 小组件，首次安装后要注销并重新登录一次'**
  String get gnomeHelperHint;

  /// Linux settings row subtitle while the helper is being installed.
  ///
  /// In zh, this message translates to:
  /// **'正在安装…'**
  String get gnomeHelperWorking;

  /// Status label (with a green dot): the helper is running.
  ///
  /// In zh, this message translates to:
  /// **'已就绪'**
  String get gnomeHelperReady;

  /// Status label: the helper has never been installed.
  ///
  /// In zh, this message translates to:
  /// **'未安装'**
  String get gnomeHelperNotInstalled;

  /// Status label: installed, takes effect after logging out and back in.
  ///
  /// In zh, this message translates to:
  /// **'需重新登录'**
  String get gnomeHelperNeedsRelogin;

  /// Status label: an older helper is installed; this Whisper brings a newer one.
  ///
  /// In zh, this message translates to:
  /// **'需要更新'**
  String get gnomeHelperOutdated;

  /// Status label: the helper was switched off in GNOME's Extensions app.
  ///
  /// In zh, this message translates to:
  /// **'已停用'**
  String get gnomeHelperDisabled;

  /// Status label: all GNOME user extensions are switched off.
  ///
  /// In zh, this message translates to:
  /// **'扩展已关闭'**
  String get gnomeHelperExtensionsOff;

  /// Confirmation dialog before installing the helper.
  ///
  /// In zh, this message translates to:
  /// **'Whisper 会给 GNOME 装一个小扩展：被流转的窗口在后台运行，键盘和鼠标由它转交。只有 Whisper 能使用它。装好后需要注销并重新登录一次。'**
  String get gnomeHelperInstallDesc;

  /// Confirmation dialog before updating the helper.
  ///
  /// In zh, this message translates to:
  /// **'这个版本的 Whisper 带来了新的窗口流转组件。更新后需要注销并重新登录一次。'**
  String get gnomeHelperUpdateDesc;

  /// Dialog when the helper waits for a new login; the confirm button logs out (GNOME asks again).
  ///
  /// In zh, this message translates to:
  /// **'组件已经装好，GNOME 要在重新登录后才会加载它。注销前请先保存好其他应用里的内容。'**
  String get gnomeHelperReloginDesc;

  /// Dialog when the helper was switched off in GNOME Extensions.
  ///
  /// In zh, this message translates to:
  /// **'窗口流转组件在 GNOME 的“扩展”里被关掉了。重新打开后，其他设备才能流转本机窗口。'**
  String get gnomeHelperDisabledDesc;

  /// Dialog when all GNOME extensions are off; confirming turns user extensions back on.
  ///
  /// In zh, this message translates to:
  /// **'GNOME 扩展目前全部关闭。打开扩展后，窗口流转组件才能运行（其他已装的扩展也会一起打开）。'**
  String get gnomeHelperExtensionsOffDesc;

  /// Dialog when the helper is running (information only).
  ///
  /// In zh, this message translates to:
  /// **'窗口流转组件正在运行。其他设备可以把本机窗口流转过去，窗口会在本机后台继续运行。'**
  String get gnomeHelperReadyDesc;

  /// Button: install the helper.
  ///
  /// In zh, this message translates to:
  /// **'安装'**
  String get gnomeHelperInstall;

  /// Button: update the helper.
  ///
  /// In zh, this message translates to:
  /// **'更新'**
  String get gnomeHelperUpdate;

  /// Button: log out of the desktop session now (GNOME shows its own confirmation).
  ///
  /// In zh, this message translates to:
  /// **'注销…'**
  String get gnomeHelperLogOut;

  /// Button: dismiss the dialog without doing anything.
  ///
  /// In zh, this message translates to:
  /// **'稍后'**
  String get gnomeHelperLater;

  /// Button: turn the helper back on.
  ///
  /// In zh, this message translates to:
  /// **'打开'**
  String get gnomeHelperTurnOn;

  /// Button: turn GNOME user extensions back on.
  ///
  /// In zh, this message translates to:
  /// **'打开扩展'**
  String get gnomeHelperTurnOnExtensions;

  /// Button: close an information dialog.
  ///
  /// In zh, this message translates to:
  /// **'好'**
  String get gnomeHelperDone;

  /// Toast after installing: log out and back in to finish.
  ///
  /// In zh, this message translates to:
  /// **'已安装。注销并重新登录后即可使用'**
  String get gnomeHelperInstalled;

  /// Toast when installing or enabling the helper failed.
  ///
  /// In zh, this message translates to:
  /// **'无法安装窗口流转组件'**
  String get gnomeHelperFailed;

  /// Settings switch: whether trusted devices may open and control this computer's windows (window flow source)
  ///
  /// In zh, this message translates to:
  /// **'允许查看和操作本机窗口'**
  String get windowStreamShareSetting;

  /// Detail under the window sharing settings switch
  ///
  /// In zh, this message translates to:
  /// **'已信任的设备可以在它们那边打开并操作这台电脑上的窗口'**
  String get windowStreamShareSettingDesc;

  /// Device page switch: this device may browse my files without asking each time. Turning it off takes back an earlier "Always allow".
  ///
  /// In zh, this message translates to:
  /// **'始终允许浏览我的文件'**
  String get deviceFilesAlwaysAllowed;

  /// Toast after closing a window from the recents: the window stayed open on its device (for example a save prompt).
  ///
  /// In zh, this message translates to:
  /// **'“{app}”还没有关闭，可能在问你是否保存'**
  String windowStreamCloseStillOpen(String app);

  /// Toast action: open the window that did not close, to answer its prompt.
  ///
  /// In zh, this message translates to:
  /// **'打开窗口'**
  String get windowStreamCloseShow;

  /// Accessibility label of a recents card whose window is being closed.
  ///
  /// In zh, this message translates to:
  /// **'正在关闭'**
  String get windowStreamClosing;

  /// Web page header: which device shares the files
  ///
  /// In zh, this message translates to:
  /// **'来自 {device}'**
  String shareWebFrom(String device);

  /// Web page footer explaining where the files come from
  ///
  /// In zh, this message translates to:
  /// **'文件直接从这台设备经局域网传来，不经过云端。'**
  String get shareWebFooterLan;

  /// Under a text preview that was cut short; size is like 32 KB
  ///
  /// In zh, this message translates to:
  /// **'只显示了前 {size}，下载后可查看全部内容。'**
  String shareWebPreviewTruncated(String size);

  /// Web page: link to the previous file in the folder
  ///
  /// In zh, this message translates to:
  /// **'上一个'**
  String get shareWebPrevious;

  /// Web page: link to the next file in the folder
  ///
  /// In zh, this message translates to:
  /// **'下一个'**
  String get shareWebNext;

  /// Switch row in a share link's details: whether the link can be opened
  ///
  /// In zh, this message translates to:
  /// **'允许访问'**
  String get shareLinkAllowAccess;

  /// Row label for this device's network address in the share link details
  ///
  /// In zh, this message translates to:
  /// **'地址'**
  String get shareLinkAddress;

  /// Footer under the file server switch on the share links page
  ///
  /// In zh, this message translates to:
  /// **'同一局域网里的设备用浏览器打开链接就能下载。服务只在有开着的链接时运行。'**
  String get shareLinksServiceFooter;

  /// Row label in share link details
  ///
  /// In zh, this message translates to:
  /// **'访问次数'**
  String get shareLinkVisitsLabel;

  /// Row label in share link details
  ///
  /// In zh, this message translates to:
  /// **'下载次数'**
  String get shareLinkDownloadsLabel;

  /// Row label in share link details
  ///
  /// In zh, this message translates to:
  /// **'最近访问'**
  String get shareLinkLastVisitLabel;

  /// Row label in share link details: how much data the link served
  ///
  /// In zh, this message translates to:
  /// **'已发送'**
  String get shareLinkSentLabel;

  /// Value of the last-visit row when nobody opened the link yet
  ///
  /// In zh, this message translates to:
  /// **'从未'**
  String get shareLinkNever;

  /// Android page title: the on-phone service that lets other devices view and control this phone's apps.
  ///
  /// In zh, this message translates to:
  /// **'窗口流转服务'**
  String get androidWindowServiceTitle;

  /// Android window flow service status: the agent is running and reachable.
  ///
  /// In zh, this message translates to:
  /// **'已开启'**
  String get androidWindowServiceRunning;

  /// Android window flow service subtitle when running: what it enables.
  ///
  /// In zh, this message translates to:
  /// **'你信任的电脑现在可以在它们的流转里看到这台手机，打开手机上的应用来操作'**
  String get androidWindowServiceRunningHint;

  /// Android window flow service status: set up before, but the agent is not running now (e.g. after a reboot).
  ///
  /// In zh, this message translates to:
  /// **'未运行'**
  String get androidWindowServiceStopped;

  /// Android window flow service subtitle when stopped but already set up once.
  ///
  /// In zh, this message translates to:
  /// **'打开无线调试后，这里可以重新开启，无需再插电脑'**
  String get androidWindowServiceStoppedHint;

  /// Android window flow service status: never set up on this phone.
  ///
  /// In zh, this message translates to:
  /// **'未设置'**
  String get androidWindowServiceNeedsSetup;

  /// Android window flow service subtitle when not set up: what the feature does.
  ///
  /// In zh, this message translates to:
  /// **'开启后，这台手机的应用可以流转到你信任的电脑上查看和操作，手机留在后台'**
  String get androidWindowServiceNeedsSetupHint;

  /// Android window flow service primary button: start the service.
  ///
  /// In zh, this message translates to:
  /// **'开启服务'**
  String get androidWindowServiceStart;

  /// Android window flow service button: stop the running service.
  ///
  /// In zh, this message translates to:
  /// **'停止服务'**
  String get androidWindowServiceStop;

  /// Android window flow service primary button: begin first-time setup.
  ///
  /// In zh, this message translates to:
  /// **'开始设置'**
  String get androidWindowServiceSetup;

  /// Android window flow setup section header: the steps only needed once.
  ///
  /// In zh, this message translates to:
  /// **'一次性设置'**
  String get androidWindowServiceHowTitle;

  /// Android setup step 1 title.
  ///
  /// In zh, this message translates to:
  /// **'打开开发者选项'**
  String get androidWindowServiceStep1;

  /// Android setup step 1 subtitle.
  ///
  /// In zh, this message translates to:
  /// **'在“关于手机”里连续点击“版本号”7 次'**
  String get androidWindowServiceStep1Hint;

  /// Android setup step 1 button: deep link to device info settings.
  ///
  /// In zh, this message translates to:
  /// **'打开“关于手机”'**
  String get androidWindowServiceStep1Action;

  /// Android setup step 2 title.
  ///
  /// In zh, this message translates to:
  /// **'打开无线调试'**
  String get androidWindowServiceStep2;

  /// Android setup step 2 subtitle.
  ///
  /// In zh, this message translates to:
  /// **'在“开发者选项”里打开“无线调试”，并保持本页在同一屏打开“使用配对码配对设备”'**
  String get androidWindowServiceStep2Hint;

  /// Android setup step 2 button: deep link to development settings.
  ///
  /// In zh, this message translates to:
  /// **'打开“开发者选项”'**
  String get androidWindowServiceStep2Action;

  /// Android setup step 3 title: the 6-digit Wireless debugging pairing code.
  ///
  /// In zh, this message translates to:
  /// **'输入配对码'**
  String get androidWindowServiceStep3;

  /// Android setup step 3 subtitle.
  ///
  /// In zh, this message translates to:
  /// **'把系统显示的 6 位配对码填到这里，Whisper 会和这台手机自己配对并开启服务'**
  String get androidWindowServiceStep3Hint;

  /// Android setup pairing-code text field label.
  ///
  /// In zh, this message translates to:
  /// **'配对码'**
  String get androidWindowServicePairingCode;

  /// Android setup button: submit the pairing code, pair, and start the service.
  ///
  /// In zh, this message translates to:
  /// **'配对并开启'**
  String get androidWindowServicePair;

  /// Android setup status while pairing with the phone's own adb.
  ///
  /// In zh, this message translates to:
  /// **'正在配对…'**
  String get androidWindowServicePairing;

  /// Android window flow service status while the agent starts.
  ///
  /// In zh, this message translates to:
  /// **'正在开启…'**
  String get androidWindowServiceStarting;

  /// Android window flow service toggle: let Whisper restart the service by itself after the phone reboots.
  ///
  /// In zh, this message translates to:
  /// **'重启后自动开启'**
  String get androidWindowServiceAutoStart;

  /// Android window flow service auto-start toggle subtitle, stating the security trade-off.
  ///
  /// In zh, this message translates to:
  /// **'需要授予 Whisper 一项系统权限来开启无线调试；只有你信任的电脑才能连上，随时可在这里关闭'**
  String get androidWindowServiceAutoStartHint;

  /// Toast after the service starts.
  ///
  /// In zh, this message translates to:
  /// **'窗口流转服务已开启'**
  String get androidWindowServiceStarted;

  /// Toast after the service stops.
  ///
  /// In zh, this message translates to:
  /// **'窗口流转服务已停止'**
  String get androidWindowServiceStopped2;

  /// Toast when the self-start fails.
  ///
  /// In zh, this message translates to:
  /// **'开启失败，请确认无线调试已打开并重试'**
  String get androidWindowServiceStartFailed;

  /// Toast when pairing with the pairing code fails.
  ///
  /// In zh, this message translates to:
  /// **'配对失败，请核对配对码后重试'**
  String get androidWindowServicePairFailed;

  /// Settings row title linking to the Android window flow service page.
  ///
  /// In zh, this message translates to:
  /// **'窗口流转服务'**
  String get androidWindowServiceEntryTitle;

  /// Settings row subtitle for the Android window flow service page.
  ///
  /// In zh, this message translates to:
  /// **'让其他设备流转这台手机的应用'**
  String get androidWindowServiceEntryHint;

  /// Android window flow service hint shown when the phone cannot start the agent by itself (no bundled pairing): use a computer once.
  ///
  /// In zh, this message translates to:
  /// **'把这台手机连到一台装了 Whisper、开着窗口流转的电脑一次，就能开启；之后其他电脑都能用'**
  String get androidWindowServiceComputerHint;

  /// Shown above an Android phone's (empty) window list on another device when the phone's window-flow service is not running.
  ///
  /// In zh, this message translates to:
  /// **'在 {device} 上打开 Whisper，到“设置 → 窗口流转服务”里开启服务'**
  String windowStreamPhoneServiceOff(String device);

  /// File browser: the other device was asked to allow browsing, but nobody answered there within a minute.
  ///
  /// In zh, this message translates to:
  /// **'{device} 没有回应'**
  String remoteFilesNoAnswer(String device);

  /// File browser: under remoteFilesNoAnswer.
  ///
  /// In zh, this message translates to:
  /// **'那台设备上的询问已经过期。请确认对方在设备旁，再试一次。'**
  String get remoteFilesNoAnswerDetail;

  /// File browser: shown after the user stopped waiting for the other device to allow browsing; a button asks again.
  ///
  /// In zh, this message translates to:
  /// **'浏览 {device} 的文件需要对方允许'**
  String remoteFilesNotAsked(String device);
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
