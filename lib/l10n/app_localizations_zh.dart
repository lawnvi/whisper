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
  String connectRequestNotificationBody(String name, String host) {
    return '$name($host)请求连接';
  }

  @override
  String get connectRequestExpired => '连接请求已过期';

  @override
  String transferNotificationTitle(int count) {
    return '正在传输 $count 个文件';
  }

  @override
  String transferNotificationBodySending(
      int percent, String speed, String remaining) {
    return '发送中 $percent% · $speed · 剩余 $remaining';
  }

  @override
  String transferNotificationBodyReceiving(
      int percent, String speed, String remaining) {
    return '接收中 $percent% · $speed · 剩余 $remaining';
  }

  @override
  String transferNotificationBodyMixed(
      int percent, String speed, String remaining) {
    return '收发中 $percent% · $speed · 剩余 $remaining';
  }

  @override
  String transferNotificationCompleted(int count) {
    return '传输完成 · $count 个文件';
  }

  @override
  String get transferNotificationInterrupted => '传输已中断,回到应用可恢复';

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
  String get portDesc => '请输入 1001 到 65535 之间的端口';

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
  String get clipboardImageSendFailed => '剪贴板图片发送失败';

  @override
  String get clipboardFilesSendFailed => '剪贴板文件发送失败';

  @override
  String get messageSendFailed => '消息发送失败，请重试';

  @override
  String clipboardFilesCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个文件',
      one: '1 个文件',
    );
    return '$_temp0';
  }

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
  String get back => '返回';

  @override
  String get selectAll => '全选';

  @override
  String get clearAll => '清空';

  @override
  String get selectNotifyApp => '选择通知应用';

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
  String get androidBatteryOptimization => '电池优化白名单';

  @override
  String get androidBatteryOptimizationDesc =>
      '建议允许后台运行，并把 Whisper 加入电池优化白名单，尤其是小米、OPPO、vivo、华为设备';

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
  String get audioGroupShareStart => '同步到多台扬声器';

  @override
  String get audioGroupAdjust => '调整音频共享';

  @override
  String get audioGroupSelectSinks => '选择播放设备';

  @override
  String get audioGroupStart => '开始同步播放';

  @override
  String get audioGroupApply => '应用配置';

  @override
  String get audioGroupStop => '停止共享';

  @override
  String get audioGroupRoleStereo => '立体声';

  @override
  String get audioGroupRoleLeft => '左声道';

  @override
  String get audioGroupRoleRight => '右声道';

  @override
  String get audioGroupRoleMono => '单声道';

  @override
  String get audioGroupRequestingPlayback => '正在请求多台设备同步播放';

  @override
  String get audioGroupSelectAtLeastOne => '至少选择一台播放设备';

  @override
  String get audioGroupSyncCalibrating => '正在估算同步';

  @override
  String get audioGroupSyncGood => '同步良好';

  @override
  String get audioGroupSyncFair => '同步一般';

  @override
  String get audioGroupSyncUnstable => '同步波动';

  @override
  String get audioGroupDeviceIdle => '未播放';

  @override
  String get audioGroupLatencyShortLabel => '网络';

  @override
  String get audioGroupJitterShortLabel => '抖动';

  @override
  String get audioGroupBufferShortLabel => '缓冲';

  @override
  String get audioGroupRecentLatePacketShortLabel => '晚包';

  @override
  String get audioGroupClockOffsetLabel => '时钟偏移';

  @override
  String audioGroupSyncEvidence(
      Object quality,
      Object clockOffsetLabel,
      Object offset,
      Object rtt,
      Object jitter,
      Object buffer,
      Object latePackets) {
    return '$quality · $clockOffsetLabel ${offset}ms · RTT ${rtt}ms · 抖动 ${jitter}ms · 缓冲 ${buffer}ms · 晚包 $latePackets';
  }

  @override
  String audioGroupSyncEvidenceCompact(
      Object quality,
      Object latencyLabel,
      Object rtt,
      Object jitterLabel,
      Object jitter,
      Object bufferLabel,
      Object buffer,
      Object latePacketLabel,
      Object latePackets) {
    return '$quality · $latencyLabel$rtt · $jitterLabel$jitter · $bufferLabel$buffer · $latePacketLabel$latePackets';
  }

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

  @override
  String get remoteInputWorkspaceTitle => '键鼠工作区';

  @override
  String get remoteInputWorkspaceTooltip => '键鼠工作区';

  @override
  String get remoteInputWorkspaceStart => '启动';

  @override
  String get remoteInputWorkspaceStop => '停止';

  @override
  String get remoteInputWorkspaceNoTargets => '没有可用的桌面被控设备';

  @override
  String get remoteInputWorkspaceSelectTargets => '被控设备';

  @override
  String get remoteInputWorkspaceCanvasTitle => '屏幕排列';

  @override
  String get remoteInputWorkspaceDetailsTitle => '设备详情';

  @override
  String get remoteInputWorkspaceFocusTarget => '查看设备';

  @override
  String get remoteInputWorkspaceAddTarget => '加入工作区';

  @override
  String get remoteInputWorkspaceRemoveTarget => '移出工作区';

  @override
  String get remoteInputWorkspaceState => '状态';

  @override
  String get remoteInputWorkspaceConflict => '边缘重叠';

  @override
  String get remoteInputWorkspaceTargetIdle => '未启用';

  @override
  String get remoteInputWorkspaceStatusIdle => '键鼠工作区未启用';

  @override
  String get remoteInputWorkspaceStatusOffering => '正在等待被控设备确认';

  @override
  String get remoteInputWorkspaceStatusArmed => '移动到屏幕边缘开始控制目标设备';

  @override
  String remoteInputWorkspaceStatusActive(String peer) {
    return '正在控制 $peer';
  }

  @override
  String remoteInputWorkspaceStatusFailed(String error) {
    return '键鼠工作区失败：$error';
  }

  @override
  String get audioPlaybackNotificationSubtitle => '正在播放系统音频';

  @override
  String get mediaActionPause => '暂停';

  @override
  String get mediaActionPlay => '播放';

  @override
  String get mediaActionDisconnect => '断开';

  @override
  String get notificationChannelKeepAlive => '后台保活';

  @override
  String get notificationChannelKeepAliveDesc => '在后台运行时保持 Whisper 连接';

  @override
  String get notificationChannelMedia => '媒体播放';

  @override
  String get notificationChannelTransfer => '文件传输';

  @override
  String get notificationChannelTransferDesc => '文件传输进度';

  @override
  String get notificationChannelGeneral => '消息';

  @override
  String get notificationChannelGeneralDesc => '新消息与提醒';

  @override
  String get emptyAppsTitle => '没有可用应用';

  @override
  String get emptyAppsSearchTitle => '没有找到应用';

  @override
  String get fileDropRejected => '无法发送这些文件';

  @override
  String get validationRequired => '此项不能为空';

  @override
  String get validationNicknameRequired => '请输入昵称';

  @override
  String get validationNicknameTooLong => '昵称不能超过 64 个字符';

  @override
  String get validationHostRequired => '请输入主机名或 IP 地址';

  @override
  String get validationHostInvalid => '请输入有效的 IPv4、IPv6、.local 或主机名';

  @override
  String get validationPortInvalid => '请输入 1001 到 65535 之间的端口';

  @override
  String get settingsSectionDeviceAppearance => '设备与外观';

  @override
  String get settingsSectionDeviceAppearanceDesc => '名称、主题和本机在附近设备上的显示方式';

  @override
  String get settingsSectionConnectionTransfer => '连接与传输';

  @override
  String get settingsSectionConnectionTransferDesc => '服务端口、文件保存和可信设备连接';

  @override
  String get settingsSectionSystemBehavior => '系统行为';

  @override
  String get settingsSectionSystemBehaviorDesc => '启动、后台和窗口行为';

  @override
  String get settingsSectionPermissionsSharing => '权限与共享';

  @override
  String get settingsSectionPermissionsSharingDesc => '剪贴板、信任、音频和键鼠权限';

  @override
  String get settingsSectionMobileIntegration => '移动端集成';

  @override
  String get settingsSectionMobileIntegrationDesc => '后台连接和电池行为';

  @override
  String get settingsSectionNotificationForwarding => '通知转发';

  @override
  String get settingsSectionNotificationForwardingDesc => 'Android 通知处理和验证码辅助';

  @override
  String get settingsSectionLanguageFiles => '语言与文件';

  @override
  String get settingsSectionLanguageFilesDesc => '语言、保存目录和应用信息';

  @override
  String get settingsSaveDirectory => '保存目录';

  @override
  String get settingsChangeDirectory => '更改保存目录';

  @override
  String get settingsOpenDirectory => '打开保存目录';

  @override
  String get settingsVersion => '版本';

  @override
  String get appListSearchPlaceholder => '搜索应用';

  @override
  String get appListClearSearch => '清除应用搜索';

  @override
  String get deselectAll => '取消全选';

  @override
  String get settingsLoadFailedTitle => '无法加载设置';

  @override
  String get settingsLoadFailedBody => '请检查本机应用服务后重试。';

  @override
  String get appListLoadFailedTitle => '无法加载应用';

  @override
  String get appListLoadFailedBody => '请检查应用访问权限后重试。';

  @override
  String get appListSaveFailed => '无法保存通知应用选择';

  @override
  String get notificationApps => '通知应用';

  @override
  String notificationAppsSelected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已选择 $count 个应用',
      zero: '尚未选择应用',
    );
    return '$_temp0';
  }

  @override
  String get notificationAppsDisabled => '开启通知转发后可选择应用';

  @override
  String get notificationForwardingUpdateFailed => '无法更新通知转发，请重试';

  @override
  String get dangerousActions => '危险操作';

  @override
  String get pairingNewDeviceTitle => '配对新设备';

  @override
  String pairingNewDeviceDescription(String device) {
    return '$device 请求建立可信连接';
  }

  @override
  String get pairingIdentityChangedTitle => '设备身份已变化';

  @override
  String pairingIdentityChangedDescription(String device) {
    return '$device 的身份公钥与上次配对不同。仅在你确认设备已重装或重置后继续';
  }

  @override
  String get pairingLegacyTrustTitle => '重新确认可信设备';

  @override
  String pairingLegacyTrustDescription(String device) {
    return '$device 来自旧版信任记录，需要重新配对以绑定设备身份';
  }

  @override
  String get pairingCompareCode => '请确认两台设备显示相同的 6 位数字';

  @override
  String get pairingNotificationBody => '打开 Whisper，在 App 内比对 6 位配对码';

  @override
  String pairingCodeSemantics(String code) {
    return '配对码 $code';
  }

  @override
  String get pairingReject => '拒绝';

  @override
  String get pairingApprove => '数字一致';

  @override
  String get pairingUpgradeRequired => '对方版本过低，请升级 Whisper 后重试';

  @override
  String get pairingExpired => '配对请求已过期';
}
