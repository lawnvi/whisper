// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get connectDeviceTitle => '连接设备';

  @override
  String get connectDeviceDesc => '输入对方局域网地址与端口';

  @override
  String get connectTo => '连接到';

  @override
  String get connectRequest => '连接请求';

  @override
  String connectRequestDesc(String device) {
    return '接入设备：$device?';
  }

  @override
  String get connect => '连接';

  @override
  String get confirm => '确定';

  @override
  String get allow => '同意';

  @override
  String get refuse => '拒绝';

  @override
  String get cancel => '取消';

  @override
  String get setting => '设置';

  @override
  String get sendTips => '发点什么...';

  @override
  String get trust => '自动接入';

  @override
  String get writeClipboard => '写入剪切板';

  @override
  String get deleteDevice => '删除设备';

  @override
  String serverPort(Object port) {
    return '服务端口 $port';
  }

  @override
  String get serverPortTitle => '服务端口';

  @override
  String get trustNewDevice => '自动通过新设备';

  @override
  String get accessClipboard => '允许访问剪切板';

  @override
  String get doubleClickRmMessage => '双击消息删除';

  @override
  String get close2tray => '关闭时隐藏到托盘';

  @override
  String get nickname => '昵称';

  @override
  String get nicknameDesc => '请输入昵称';

  @override
  String get port => '服务端口';

  @override
  String get portDesc => '请输入服务端口：[1000, 65535]';

  @override
  String get timeoutTitle => '连接超时';

  @override
  String get disconnect => '断开';

  @override
  String get keepConnect => '保持';

  @override
  String get menuShow => '显示';

  @override
  String get menuHide => '隐藏';

  @override
  String get menuClipboard => '发送剪切板';

  @override
  String get menuSendFile => '发送文件';

  @override
  String get filePickerOpenFailed => '无法打开文件选择器';

  @override
  String get exit => '退出';

  @override
  String get delete => '删除';

  @override
  String get deleteConfirm => '确认删除';

  @override
  String get warning => '警告';

  @override
  String get deleteWarningText => '连接正在使用，禁止快速删除';

  @override
  String get close => '关闭';

  @override
  String deleteDeviceTitle(String device) {
    return '删除 $device';
  }

  @override
  String get deleteDeviceDesc => '删除与此设备的所有消息，不可恢复';

  @override
  String get brokeConnectTitle => '断开连接';

  @override
  String brokeConnectDesc(String device) {
    return '断开 $device';
  }

  @override
  String get connectFailed => '连接失败';

  @override
  String get deviceBusy => '服务占线';

  @override
  String get startServerFailed => '服务启动失败';

  @override
  String get deleteMessageTitle => '删除消息';

  @override
  String get deleteMessageDesc => '确定删除此消息吗？';

  @override
  String language(Object language) {
    return '语言 $language';
  }

  @override
  String get pushNotification => '推送安卓通知';

  @override
  String get ignoreNotification => '忽略安卓通知';

  @override
  String get ftpService => 'FTP服务';

  @override
  String get back => '返回';

  @override
  String get selectAll => '全选';

  @override
  String get clearAll => '清空';

  @override
  String get selectNotifyApp => '监听APP通知';

  @override
  String get copyVerifyCode => '验证码写入剪切板';

  @override
  String get open => '打开';

  @override
  String get openInFinder => '在Finder中显示';

  @override
  String get openInDir => '所在文件夹';

  @override
  String get keepFile => '保留文件';

  @override
  String get deleteFile => '删除文件';

  @override
  String get copyMessage => '复制消息';

  @override
  String get themeMode => '主题模式';

  @override
  String get followSystem => '跟随系统';

  @override
  String get lightMode => '明亮';

  @override
  String get darkMode => '暗黑';

  @override
  String get selectThemeMode => '选择主题模式';

  @override
  String get selectLanguage => '选择语言';

  @override
  String get searchChats => '搜索';

  @override
  String get selectConversationPlaceholder => '选择一个设备开始对话';

  @override
  String get connectedNow => '当前已连接';

  @override
  String get nearbyAvailable => '附近可连接';

  @override
  String get noMessagesYet => '还没有消息';

  @override
  String get sharedFile => '发送了一个文件';

  @override
  String get connectToSend => '连接后即可发送消息';

  @override
  String get localeNameZhHans => '简体中文';

  @override
  String get localeNameEnglish => 'English';

  @override
  String get localeNameSpanish => 'Español';

  @override
  String get autoConnectTrustedDevices => '自动连接互信设备';

  @override
  String get mutualTrustEnabled => '双向互信已开启';

  @override
  String get mutualTrustNotEstablished => '尚未形成双向互信';

  @override
  String get androidBackgroundKeepAlive => '后台保活连接';

  @override
  String get androidBackgroundKeepAliveDesc =>
      '连接期间启用前台服务，降低选文件、切后台或锁屏时被系统断开的概率';

  @override
  String get androidBackgroundKeepAliveActiveTitle => 'Whisper 正在保持连接';

  @override
  String get androidBackgroundKeepAliveActiveDesc => '有活动会话时保持前台服务运行';

  @override
  String get androidBatteryOptimization => '电池优化白名单';

  @override
  String get androidBatteryOptimizationDesc =>
      '建议允许后台运行，并把 Whisper 加入电池优化白名单，尤其是小米、OPPO、vivo、华为设备';
}
