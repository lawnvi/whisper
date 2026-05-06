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
  String get retry => '重试';

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
  String get launchAtStartup => '开机自启动';

  @override
  String get launchAtStartupDesc => '登录桌面后自动启动 Whisper，便于自动连接互信设备';

  @override
  String launchAtStartupFailed(String error) {
    return '开机自启动设置失败：$error';
  }

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
  String androidBackgroundKeepAliveTransferSending(String progress) {
    return '正在传文件 $progress%';
  }

  @override
  String androidBackgroundKeepAliveTransferReceiving(String progress) {
    return '正在接收文件 $progress%';
  }

  @override
  String get androidBackgroundKeepAliveAudioSharing => '正在共享音频';

  @override
  String get androidBackgroundKeepAliveAudioPlaying => '正在播放共享音频';

  @override
  String get androidBackgroundKeepAliveAudioPreparing => '正在准备音频共享';

  @override
  String get androidBatteryOptimization => '电池优化白名单';

  @override
  String get androidBatteryOptimizationDesc =>
      '建议允许后台运行，并把 Whisper 加入电池优化白名单，尤其是小米、OPPO、vivo、华为设备';

  @override
  String get fileTransferLegacyInProgress => '旧协议传输中';

  @override
  String get fileTransferQueued => '排队中';

  @override
  String fileTransferPreparingResume(String progress) {
    return '准备续传 $progress%';
  }

  @override
  String get fileTransferNegotiating => '协商中';

  @override
  String fileTransferWaitingReconnect(String progress) {
    return '等待重连 $progress%';
  }

  @override
  String get fileTransferPaused => '已暂停';

  @override
  String get fileTransferVerifying => '校验中';

  @override
  String get fileTransferFailedRetryable => '失败，可重试';

  @override
  String get fileTransferCanceled => '已取消';

  @override
  String get peerDoesNotSupportResumableTransfer => '对端不支持断点续传';

  @override
  String get connectedPeerDoesNotSupportResumableTransfer => '当前连接设备不支持断点续传';

  @override
  String get audioShareCaptureConnecting => '采集端：正在连接远端扬声器';

  @override
  String get audioSharePlaybackPreparing => '播放端：正在准备播放共享声音';

  @override
  String get audioShareCaptureActiveStop => '采集端：正在共享本机声音，点击停止';

  @override
  String get audioSharePlaybackActiveStop => '播放端：正在作为扬声器播放，点击停止';

  @override
  String get audioShareStart => '把本机声音共享给对端';

  @override
  String get audioSharePlaybackStopped => '已停止播放共享声音';

  @override
  String get audioShareCaptureStopped => '已停止共享声音';

  @override
  String get audioSharePlaybackGainTitle => '共享扬声器增益';

  @override
  String audioSharePlaybackGainSetting(String gain) {
    return '共享扬声器增益：$gain';
  }

  @override
  String get audioSharePlaybackGainDesc => '只影响本机播放对端共享声音，过高可能产生削波';

  @override
  String get remoteInputScrollMultiplierTitle => '键鼠共享滚轮速度';

  @override
  String remoteInputScrollMultiplierSetting(String multiplier) {
    return '键鼠共享滚轮速度：$multiplier';
  }

  @override
  String get remoteInputScrollMultiplierDesc => '只影响本机作为被控端时接收的远端滚轮事件';

  @override
  String get audioShareUnsupportedCapture => '当前设备不支持系统音频采集';

  @override
  String get audioShareRequestingPlayback => '正在请求对端播放本机声音';

  @override
  String audioShareFailed(String error) {
    return '共享声音失败：$error';
  }

  @override
  String get remoteInputSourceConnecting => '键鼠共享：正在连接对端';

  @override
  String get remoteInputSinkConnecting => '键鼠共享：正在准备接收控制';

  @override
  String get remoteInputEdgeActiveStop => '键鼠共享：边缘穿越已启用，点击停止';

  @override
  String get remoteInputSourceActiveStop => '键鼠共享：正在控制对端，点击停止';

  @override
  String get remoteInputSinkActiveStop => '键鼠共享：正在接收控制，点击停止';

  @override
  String get remoteInputStart => '启用键鼠共享';

  @override
  String get remoteInputStopped => '已停止键鼠共享';

  @override
  String get remoteInputStopCurrentFirst => '请先停止当前键鼠共享会话';

  @override
  String get remoteInputLocalUnsupported => '当前设备不支持键鼠共享';

  @override
  String get remoteInputPeerUnsupported => '当前连接设备不支持键鼠共享';

  @override
  String get remoteInputRequiresMutualTrust => '键鼠共享需要互信设备';

  @override
  String get remoteInputPeerMustTrustThisDevice => '对端还没有信任本机，请先在对端信任本机后再共享键鼠';

  @override
  String get remoteInputLayoutRequired => '请先在设备设置里把对端屏幕贴到本机边缘';

  @override
  String get remoteInputEnabledMoveToEdge => '键鼠共享已启用，移动到屏幕边缘开始控制对端';

  @override
  String remoteInputFailed(String error) {
    return '键鼠共享失败：$error';
  }

  @override
  String remoteInputAutoModeSetting(String mode) {
    return '键鼠共享自动模式：$mode';
  }

  @override
  String remoteInputLayoutSetting(String edge) {
    return '屏幕排列：$edge';
  }

  @override
  String get remoteInputAutoModeTitle => '键鼠共享自动模式';

  @override
  String get remoteInputAutoModeOff => '关闭';

  @override
  String get remoteInputAutoModeSource => '本机控制对端';

  @override
  String get remoteInputAutoModeSink => '对端控制本机';

  @override
  String get remoteInputLayoutTitle => '屏幕排列';

  @override
  String remoteInputCurrentEdge(String edge) {
    return '当前：$edge';
  }

  @override
  String get remoteInputLayoutSave => '保存';

  @override
  String get remoteInputSnapLeft => '贴左';

  @override
  String get remoteInputSnapRight => '贴右';

  @override
  String get remoteInputSnapTop => '贴上';

  @override
  String get remoteInputSnapBottom => '贴下';

  @override
  String get remoteInputLocalScreen => '本机';

  @override
  String get remoteInputPeerScreen => '对端';

  @override
  String get remoteInputEdgeLeft => '左侧';

  @override
  String get remoteInputEdgeRight => '右侧';

  @override
  String get remoteInputEdgeTop => '上方';

  @override
  String get remoteInputEdgeBottom => '下方';

  @override
  String get remoteInputEdgeNotAdjacent => '未贴边';
}
