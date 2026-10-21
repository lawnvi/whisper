// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get mobileControlSpace => '空格';

  @override
  String get mobileControlEnter => '回车';

  @override
  String get mobileControlSymbols => '数字与符号';

  @override
  String get mobileControlMoreSymbols => '更多符号';

  @override
  String get mobileControlDirectKeys => '直接按键';

  @override
  String get mobileControlReturnKeys => '返回直接按键';

  @override
  String get mobileControlDraftHint => '中文、表情或一段文字…';

  @override
  String get mobileControlScrollShort => '滚动';

  @override
  String get mobileControlLeftShort => '左键';

  @override
  String get mobileControlRightShort => '右键';

  @override
  String get mobileControlStopShort => '停止';

  @override
  String get mobileControlPermission =>
      '请在 Mac 的“系统设置 → 隐私与安全性 → 辅助功能”中允许 Whisper，然后重新开始。';

  @override
  String get mobileControlTitle => '控制电脑';

  @override
  String get mobileControlStart => '开始控制';

  @override
  String get mobileControlStop => '停止控制';

  @override
  String get mobileControlReady => '已就绪';

  @override
  String get mobileControlActive => '正在控制';

  @override
  String get remoteInputPeerControlling => '正在控制此设备';

  @override
  String get remoteInputPeerReceiving => '正在控制本机';

  @override
  String get remoteInputPeerReady => '已就绪，等待切入';

  @override
  String get remoteInputManualSessionTitle => '手机键鼠';

  @override
  String get remoteInputManualSessionHint => '手机控制独立于下方的桌面键鼠工作区。';

  @override
  String get mobileControlPreparing => '正在连接控制';

  @override
  String get mobileControlAir => '体感鼠标';

  @override
  String get mobileControlTouchpad => '触控板';

  @override
  String get mobileControlHoldMove => '按住此处，转腕移动光标';

  @override
  String get mobileControlTouchHint => '单指移动 · 轻点左击\n双指轻点右击 · 双指滑动滚动';

  @override
  String get mobileControlHoldScroll => '按住转腕滚动';

  @override
  String get mobileControlScroll => '滑动滚动';

  @override
  String get mobileControlLeft => '左键';

  @override
  String get mobileControlRight => '右键';

  @override
  String get mobileControlKeyboard => '虚拟键盘';

  @override
  String get mobileControlText => '文字输入';

  @override
  String get mobileControlMainKeys => '主键盘';

  @override
  String get mobileControlFunctionKeys => '功能与导航键';

  @override
  String get mobileControlSendText => '发送文字';

  @override
  String get mobileControlTextHint => '先在电脑选中输入框，再输入并发送文字。';

  @override
  String get mobileControlTextTooLong => '每次最多发送 4 KiB 文字。';

  @override
  String get mobileControlTextUnconfirmed => '未确认输入结果，草稿已保留。请查看电脑后再决定是否重发。';

  @override
  String get mobileControlTextSent => '文字已交给电脑系统，请查看目标应用。';

  @override
  String get mobileControlSensorUnavailable => '体感不可用，已切换到触控板。';

  @override
  String get mobileControlSensitivity => '体感移动速度';

  @override
  String get mobileControlCalibrate => '校准';

  @override
  String get mobileControlCalibrating => '请保持手机静止片刻…';

  @override
  String get mobileControlCalibrationDone => '校准完成';

  @override
  String get mobileControlIdleHint => '开始后可控制光标和键盘，离开此页面会停止。';

  @override
  String mobileControlReceiving(String name) {
    return '此电脑正由 $name 控制';
  }

  @override
  String get mobileControlShortcutHint => '点选修饰键，再点普通键组合发送；完成后自动解除。';

  @override
  String get screenshotCapture => '区域截图';

  @override
  String screenshotButtonTooltip(String shortcut) {
    return '截图（$shortcut）';
  }

  @override
  String get screenshotButtonTooltipPlain => '截图';

  @override
  String get screenshotSelectionHint => '单击选择窗口 · 拖动框选区域 · Esc 取消';

  @override
  String get screenshotAdjustHint => '拖动移动 · 拖边调整 · Enter 复制 · Esc 取消';

  @override
  String get screenshotConfirm => '复制';

  @override
  String get screenshotCopied => '截图已复制，可自行粘贴使用';

  @override
  String get screenshotPermissionDenied =>
      '请在系统设置 → 隐私与安全性中允许 Whisper 录制屏幕，然后重启 Whisper';

  @override
  String get screenshotUnavailable =>
      '当前环境无法进行区域截图；Linux 请检查桌面的截图 Portal 服务是否已安装并运行';

  @override
  String get screenshotFailed => '截图或复制到剪贴板失败，请重试';

  @override
  String get screenshotShortcutTitle => '截图快捷键';

  @override
  String get screenshotShortcutDesc =>
      '框选屏幕区域后复制到剪贴板，由你自行粘贴；截图时保持 Whisper 窗口原样';

  @override
  String get screenshotShortcutEnabled => '启用全局快捷键';

  @override
  String get screenshotShortcutDisabled => '已关闭 · 仍可使用截图按钮';

  @override
  String get screenshotShortcutUnavailable => '快捷键未注册 · 点击配置';

  @override
  String get screenshotShortcutRecord => '点击这里，然后按下组合键';

  @override
  String get screenshotShortcutHint =>
      '使用 Ctrl、Alt 或 Command/Super 搭配字母、数字或 F1–F12；截图时按 Esc 取消，Wayland 下需在系统对话框确认快捷键';

  @override
  String get screenshotShortcutReset => '恢复默认快捷键';

  @override
  String get screenshotShortcutInvalid => '请使用有效组合键，并避开快捷发送的快捷键';

  @override
  String get screenshotShortcutFailed => '快捷键保存失败，可能已被占用、被取消或桌面环境不支持，请尝试其他组合';

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
    int percent,
    String speed,
    String remaining,
  ) {
    return '发送中 $percent% · $speed · 剩余 $remaining';
  }

  @override
  String transferNotificationBodyReceiving(
    int percent,
    String speed,
    String remaining,
  ) {
    return '接收中 $percent% · $speed · 剩余 $remaining';
  }

  @override
  String transferNotificationBodyMixed(
    int percent,
    String speed,
    String remaining,
  ) {
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
  String get sendFiles => '发送文件';

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
  String get clipboardAutoSync => '自动同步剪切板';

  @override
  String get clipboardAutoSyncDesc => '同步到当前可信设备；键鼠工作区中同步到已连接的工作区设备';

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
  String get deleteDeviceDesc => '断开连接并删除与此设备的所有消息，不可恢复';

  @override
  String get brokeConnectTitle => '断开连接';

  @override
  String brokeConnectDesc(String device) {
    return '断开 $device';
  }

  @override
  String get connectFailed => '连接失败';

  @override
  String get connectAlreadyInProgress => '连接正在进行中';

  @override
  String get deviceBusy => '服务占线';

  @override
  String get startServerFailed => '服务启动失败';

  @override
  String get deleteMessageTitle => '删除消息';

  @override
  String get deleteMessageDesc => '确定删除此消息吗？';

  @override
  String get selectMessages => '多选';

  @override
  String selectedMessageCount(int count) {
    return '已选 $count 条';
  }

  @override
  String deleteSelectedMessagesTitle(int count) {
    return '删除 $count 条消息';
  }

  @override
  String get deleteSelectedMessagesDesc => '将删除所选消息，无法撤销。';

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
  String get copyFile => '复制文件';

  @override
  String get fileCopied => '文件已复制';

  @override
  String get fileCopyFailed => '无法复制文件';

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
  String get windowsLockScreenInput => '锁屏与 UAC 时接收键鼠';

  @override
  String get windowsLockScreenInputHint => '锁屏时可输入密码，开关控制 UAC 提示';

  @override
  String get windowsLockScreenInputDesc => '将安装系统服务，让互信设备可在本机锁屏时输入密码。需要管理员确认。';

  @override
  String get windowsLockScreenInputUninstallDesc =>
      '卸载后将无法操作本机的锁屏和 UAC 提示。需要管理员确认。';

  @override
  String get windowsLockScreenInputNotInstalled => '未安装';

  @override
  String get windowsLockScreenInputRunning => '运行中';

  @override
  String get windowsLockScreenInputStopped => '未运行';

  @override
  String get windowsLockScreenInputOutdated => '需更新';

  @override
  String get windowsLockScreenInputInstall => '安装';

  @override
  String get windowsLockScreenInputRepair => '修复';

  @override
  String get windowsLockScreenInputUninstall => '卸载';

  @override
  String get windowsLockScreenInputWorking => '正在等待系统服务就绪…';

  @override
  String get windowsLockScreenInputFailed => '锁屏键鼠服务设置失败';

  @override
  String get windowsElevatedInput => '操作 UAC 提示';

  @override
  String get windowsElevatedInputEnableDesc =>
      '开启后互信设备可操作 UAC 提示，但本机上以你身份运行的程序也能借此绕过 UAC。需要管理员确认。';

  @override
  String get windowsElevatedInputDisableDesc =>
      '关闭后互信设备无法操作 UAC 提示，锁屏输入不受影响。需要管理员确认。';

  @override
  String get windowsElevatedInputEnable => '开启';

  @override
  String get windowsElevatedInputDisable => '关闭';

  @override
  String get windowsElevatedInputFailed => 'UAC 控制设置失败';

  @override
  String get launchAtStartup => '开机自启动';

  @override
  String get launchAtStartupDesc => '登录桌面后自动启动 Whisper，便于自动连接互信设备';

  @override
  String get launchAtStartupFailed => '开机自启动设置失败';

  @override
  String get androidBackgroundKeepAlive => '后台保活连接';

  @override
  String get androidBackgroundKeepAliveDesc => '保持局域网接收服务运行，便于在后台或锁屏时收到连接请求';

  @override
  String get androidBackgroundKeepAliveActiveTitle => 'Whisper 正在监听局域网连接';

  @override
  String get androidBackgroundKeepAliveActiveDesc => '可在后台接收附近设备的连接请求';

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
  String get fileTransferWaitingPeerVerification => '等待对端校验';

  @override
  String get fileTransferFailedNotice => '文件传输失败';

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
    Object latePackets,
  ) {
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
    Object latePackets,
  ) {
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
  String get remoteInputLayoutRequired => '请先在键鼠工作区把对端屏幕贴到本机边缘';

  @override
  String get remoteInputEnabledMoveToEdge => '键鼠共享已启用，移动到屏幕边缘开始控制对端';

  @override
  String remoteInputFailed(String error) {
    return '键鼠共享失败：$error';
  }

  @override
  String get remoteInputLayoutTitle => '屏幕排列';

  @override
  String get remoteInputLocalScreen => '本机';

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
  String get remoteInputWorkspaceNoTargetsHint => '连接并信任支持键鼠控制的桌面设备后会显示在这里';

  @override
  String get remoteInputWorkspaceSelectTargets => '被控设备';

  @override
  String get remoteInputWorkspaceCanvasTitle => '屏幕排列';

  @override
  String get remoteInputWorkspaceCanvasHint => '拖动远端屏幕并贴近本机屏幕边缘';

  @override
  String remoteInputWorkspaceExitShortcut(String shortcut) {
    return '按 $shortcut 退出共享';
  }

  @override
  String get remoteInputWorkspaceSelectTargetHint => '从左侧选择至少一台被控设备';

  @override
  String get remoteInputWorkspaceLocalBadge => '本机';

  @override
  String get remoteInputWorkspaceRemoteBadge => '远端';

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
  String get remoteInputWorkspaceResolution => '分辨率';

  @override
  String get remoteInputWorkspaceConflict => '边缘重叠';

  @override
  String get remoteInputWorkspaceReachable => '可达';

  @override
  String get remoteInputWorkspaceDisconnected => '未连接到工作区';

  @override
  String get remoteInputWorkspaceUnsupported => '不支持工作区路由';

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
  String get settingsSectionLanguageFilesDesc => '语言和文件保存目录';

  @override
  String get settingsSaveDirectory => '保存目录';

  @override
  String get settingsChangeDirectory => '更改保存目录';

  @override
  String get settingsOpenDirectory => '打开保存目录';

  @override
  String get settingsVersion => '版本';

  @override
  String get settingsSectionAbout => '关于';

  @override
  String get settingsSectionAboutDesc => '版本更新和应用信息';

  @override
  String get checkForUpdates => '检查更新';

  @override
  String currentVersion(String version) {
    return '当前版本 $version';
  }

  @override
  String get checkingForUpdates => '正在检查更新…';

  @override
  String updateAvailableVersion(String version) {
    return '发现新版本 $version';
  }

  @override
  String get updateUpToDate => '已是最新版本';

  @override
  String get updateCheckFailed => '暂时无法检查更新，请稍后重试';

  @override
  String updateAvailableTitle(String version) {
    return '发现新版本 $version';
  }

  @override
  String updateAvailableBody(String currentVersion, String latestVersion) {
    return '当前版本 $currentVersion，可更新到 $latestVersion。安装前会校验 GitHub 提供的文件哈希。';
  }

  @override
  String get downloadAndInstallUpdate => '更新';

  @override
  String get viewRelease => '查看 Release';

  @override
  String downloadingUpdate(int progress) {
    return '正在下载 $progress%';
  }

  @override
  String get updateInstallerOpened => '更新包已校验，已交给系统安装器';

  @override
  String get updateInstallFailed => '无法打开更新安装包，请稍后重试';

  @override
  String get aboutWhisper => '关于 Whisper';

  @override
  String get aboutWhisperDescription => '面向个人设备的局域网协作工具';

  @override
  String get officialWebsite => '官方网站';

  @override
  String get sourceCode => 'GitHub 源代码';

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
  String pairingNewDeviceCompareCode(String device) {
    return '$device 请求连接，请确认数字一致';
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
  String pairingNotificationBody(String device, String code) {
    return '配对码 $code · 请与 $device 核对';
  }

  @override
  String pairingInitiatorNotificationBody(String device, String code) {
    return '配对码 $code · 等待 $device 确认';
  }

  @override
  String pairingIdentityChangedNotificationBody(String device, String code) {
    return '配对码 $code · $device 的身份已变化，请打开 App 查看';
  }

  @override
  String pairingCodeSemantics(String code) {
    return '配对码 $code';
  }

  @override
  String get pairingReject => '拒绝';

  @override
  String get pairingApprove => '数字一致';

  @override
  String get pairingViewDetails => '查看详情';

  @override
  String get pairingUpgradeRequired => '对方版本过低，请升级 Whisper 后重试';

  @override
  String get pairingExpired => '配对请求已过期';

  @override
  String get pairingRejectedByPeer => '对方拒绝了连接请求';

  @override
  String get pairingEncryptionNotice => '配对后，文本、文件、剪贴板和控制数据均端到端加密';

  @override
  String get e2eeTrustedConnection => '端到端加密 · 可信设备';

  @override
  String get e2eeEncryptedConnection => '端到端加密连接';

  @override
  String get transferAssistantTitle => '搜索聊天记录';

  @override
  String get transferAssistantSearchHint => '搜索文本消息';

  @override
  String get transferAssistantClearSearch => '清除搜索';

  @override
  String get transferAssistantSearchResults => '搜索结果';

  @override
  String get transferAssistantFavorites => '收藏';

  @override
  String get transferAssistantRecent => '最近消息';

  @override
  String get transferAssistantAllMessages => '全部消息';

  @override
  String get transferAssistantExpandMessage => '展开全文';

  @override
  String get transferAssistantCollapseMessage => '收起全文';

  @override
  String get transferAssistantNoResults => '没有找到匹配的文本';

  @override
  String get transferAssistantNoFavorites => '还没有收藏文本';

  @override
  String get transferAssistantNoRecent => '还没有文本消息';

  @override
  String get transferAssistantIncoming => '收到';

  @override
  String get transferAssistantOutgoing => '发出';

  @override
  String get transferAssistantCopy => '复制文本';

  @override
  String get transferAssistantFavorite => '收藏文本';

  @override
  String get transferAssistantUnfavorite => '取消收藏';

  @override
  String get transferAssistantLoadFailed => '无法加载文本消息';

  @override
  String get transferAssistantCopied => '已复制文本';

  @override
  String get transferAssistantCopyFailed => '无法复制文本';

  @override
  String get transferAssistantFavoriteFailed => '无法更新收藏，请重试';

  @override
  String get qrPairingTitle => '二维码连接';

  @override
  String get qrMyCode => '我的二维码';

  @override
  String get qrScanCode => '扫码连接';

  @override
  String get qrShowCodeHint => '让另一台设备扫描此二维码，地址和设备身份会同时核验';

  @override
  String qrFingerprint(String fingerprint) {
    return '身份指纹 $fingerprint';
  }

  @override
  String get qrWifiUnavailable => '未检测到可用的局域网地址，请先连接 Wi-Fi 再刷新二维码';

  @override
  String get qrCopyLink => '复制连接信息';

  @override
  String get qrLinkCopied => '连接信息已复制';

  @override
  String get qrScanHint => '扫描对方 Whisper 中显示的二维码';

  @override
  String get qrCameraUnavailable => '无法使用相机，请在系统设置中允许 Whisper 访问相机';

  @override
  String get qrToggleTorch => '开关手电筒';

  @override
  String get qrSwitchCamera => '切换相机';

  @override
  String get qrCannotPairSelf => '不能连接当前设备，请扫描另一台设备的二维码';

  @override
  String get qrInvalidCode => '这不是有效的 Whisper 二维码，请让对方重新出示';

  @override
  String get connectionDiagnosticTitle => '连接诊断';

  @override
  String get connectionDiagnosticWifi =>
      '无法到达该设备。请确认两台设备连接同一 Wi-Fi，并关闭访客网络或 AP 隔离后重试。';

  @override
  String get connectionDiagnosticAddress =>
      '二维码中的局域网地址无效或已经变化。请让对方重新打开二维码后再扫描。';

  @override
  String get connectionDiagnosticService =>
      '地址已找到，但 Whisper 服务没有响应。请在对方设备打开 Whisper，并确认局域网服务正在运行。';

  @override
  String get connectionDiagnosticFirewall =>
      '连接超时。请在两台设备的系统防火墙中允许 Whisper 访问局域网后重试。';

  @override
  String get connectionDiagnosticIdentity =>
      '设备身份与二维码不一致，Whisper 已停止连接。请在对方设备重新出示二维码，切勿绕过此检查。';

  @override
  String get connectionDiagnosticVersion =>
      '两台设备的协议版本不兼容，请将 Whisper 更新到相同的新版本后重试。';

  @override
  String get connectionDiagnosticPairing =>
      '配对未完成。请保持两台设备上的 Whisper 打开，并重新核对配对码。';

  @override
  String get quickSendTitle => '快捷发送';

  @override
  String get quickSendTargets => '发送到';

  @override
  String get quickSendNoConnectedDevices => '还没有已连接的设备，连接后即可发送';

  @override
  String quickSendMoreFiles(int count) {
    return '另有 $count 个文件';
  }

  @override
  String get quickSendLater => '稍后';

  @override
  String get quickSendSend => '发送';

  @override
  String androidSystemShareWaitingForDevice(String device) {
    return '已选择 $device，连接后将自动发送';
  }

  @override
  String androidSystemShareSendingTo(String device) {
    return '正在发送给 $device';
  }

  @override
  String androidSystemShareSentTo(String device) {
    return '已发送给 $device';
  }

  @override
  String get androidSystemShareFailedRetained => '发送失败，分享内容已保留';

  @override
  String get androidSystemShareStillPending => '分享内容仍在等待选择设备';

  @override
  String get androidSystemShareQueueFull => '队列已满，新内容未加入，请先处理已有分享';

  @override
  String get androidSystemShareRejected => '分享内容超过限制或无法完整读取，未加入队列';

  @override
  String get androidSystemShareTargetNeedsReselection => '目标设备身份已变化或不再可信，请重新选择';

  @override
  String get androidSystemShareChooseAction => '选择设备';

  @override
  String get desktopQuickSendSent => '已加入加密传输队列';

  @override
  String get desktopQuickSendFailedRetained => '发送未完成，内容已保留';

  @override
  String get desktopQuickSendEmptyClipboard => '剪贴板中没有可发送的内容';

  @override
  String get desktopQuickSendShortcutUnavailable => '全局发送快捷键被其他应用占用';

  @override
  String get desktopQuickSendDraftLimit => '快捷发送已满，新内容未加入，请先处理已有内容';

  @override
  String get desktopQuickSendFileLimit => '一次选择的文件过多，新内容未加入';

  @override
  String get desktopQuickSendTextLimit => '文本过长，新内容未加入';

  @override
  String get desktopQuickSendInvalidPath => '文件路径无效或过长，新内容未加入';

  @override
  String get desktopQuickSendClipboardSnapshotUnavailable =>
      '无法立即读取剪贴板，未加入可能已变化的内容';

  @override
  String get desktopQuickSendTargetConflict => '部分内容已发送到另一台设备，请选择原设备继续';

  @override
  String get desktopQuickSendTargetNeedsReselection =>
      '目标设备身份已变化或不再可信，内容已保留，请重新选择';

  @override
  String chatTimestampYesterday(String time) {
    return '昨天 $time';
  }

  @override
  String get messageLinkOpenFailed => '无法打开此链接';

  @override
  String get connectFirstDevice => '连接你的第一台设备';

  @override
  String get deviceConnectionGuide =>
      '在另一台设备打开 Whisper，并连接同一个 Wi-Fi 或局域网。附近设备会自动显示在列表中。';

  @override
  String get manualConnectAction => '手动输入地址';

  @override
  String get deviceDiscoveryHelp => '没有发现设备？可尝试二维码连接，或在两台设备的系统设置中允许本地网络访问。';

  @override
  String get deviceOffline => '离线设备';

  @override
  String serverPortInUse(int port) {
    return '端口 $port 正被占用。请关闭其他 Whisper 实例，或在设置中更换端口后重试。';
  }

  @override
  String get serverPermissionDenied =>
      '系统拒绝了网络监听。请允许 Whisper 访问本地网络，并检查防火墙设置后重试。';

  @override
  String get serverUnavailableHelp => '暂时无法接收连接。请确认网络已连接，并检查本地网络权限及防火墙后重试。';

  @override
  String updatePackageSaved(String path) {
    return '安装包已保存在：\n$path\n你可以稍后重新安装。';
  }

  @override
  String get updateInstalledRestart => '更新已安装，重新打开 Whisper 后生效。';

  @override
  String get castReceiverTitle => '电视投屏';

  @override
  String get castReceiverHint => '开启后，在同一局域网的视频 App 中选择本机设备名称即可投屏。';

  @override
  String get castReceiverStarting => '正在启动…';

  @override
  String get castReceiverNoLan => '没有可用的局域网地址，请连接网络后重新开启。';

  @override
  String get castReceiverStartupFailed => '投屏服务未能启动，请关闭后重新开启。';

  @override
  String get castPlay => '播放';

  @override
  String get castPause => '暂停';

  @override
  String get castMute => '静音';

  @override
  String get castUnmute => '取消静音';

  @override
  String get castFullscreen => '全屏';

  @override
  String get videoPlaybackFailed => '视频播放失败，请重试或使用其他应用打开。';

  @override
  String get castPlaybackFailed => '视频播放失败，请重试或在手机上重新投屏。';

  @override
  String get castControlFailed => '操作未完成，请重试。';

  @override
  String get castRequestTitle => '允许这台设备投屏吗？';

  @override
  String castRequestMessage(String address) {
    return '来自 $address 的设备希望在本机播放视频。';
  }

  @override
  String castRequestCountdown(int seconds) {
    return '$seconds 秒后自动允许，你也可以拒绝。';
  }

  @override
  String get castRequestDeny => '拒绝';

  @override
  String get castRequestAllow => '允许投屏';

  @override
  String get castExitFullscreen => '退出全屏';

  @override
  String get castSeek => '播放进度';

  @override
  String get castVolume => '音量';

  @override
  String get mobileControlPointer => '鼠标';

  @override
  String get mobileControlKeysTab => '键盘';

  @override
  String get mobileControlTextTab => '文字';

  @override
  String get mobileControlSettings => '指针设置';

  @override
  String get mobileControlLiftHint => '松手暂停，调整握姿后继续。';

  @override
  String get mobileControlDragHint => '按住左键即可拖拽。';

  @override
  String get mobileControlPrecisionHint => '慢转精细定位，快转大幅移动。';

  @override
  String get mobileControlCalibrationRetry => '请保持手机静止，再试一次校准。';

  @override
  String get mobileControlStartShort => '开始';

  @override
  String get mobileControlMotionStart => '开启体感';

  @override
  String get mobileControlMotionPause => '暂停体感';

  @override
  String get mobileControlMotionOnHint => '转腕即可移动，点此暂停。';

  @override
  String get mobileControlMotionOffHint => '点一下开启，无需一直按住屏幕。';

  @override
  String get mobileControlTarget => '控制目标';

  @override
  String get mobileControlTargetHint => '切换后需重新开始控制。';

  @override
  String get mobileControlPointerSpeed => '触控板移动速度';

  @override
  String get mobileControlScrollSpeed => '滚轮滑动速度';

  @override
  String get mobileControlScrollRail => '滑动\n滚动';

  @override
  String get mobileControlPermissionDesktop =>
      '请在电脑上允许远程控制后重试。Linux 需要接受系统的远程控制授权。';

  @override
  String get mobileControlLinuxTextHint =>
      'Linux 只能发送电脑当前键盘布局支持的字符。中文和 emoji 请通过虚拟键盘配合电脑输入法输入。不支持的文字会保留在草稿中。';

  @override
  String get manualConnectAddressInvalid => '请输入有效的局域网 IP 或 .local 地址';

  @override
  String get manualConnectPortInvalid => '端口范围为 1–65535';

  @override
  String get transferStorageHelp => '无法保存，请检查接收端空间和目录权限';

  @override
  String get transferSourceHelp => '源文件无法读取，请重新选择文件';

  @override
  String get transferIntegrityHelp => '文件校验未通过，请重试传输';

  @override
  String get transferQueueHelp => '接收端任务较多，请稍后重试';

  @override
  String get transferTrustHelp => '请重新确认设备信任后再发送';

  @override
  String get transferRetryHelp => '传输未完成，请确认设备已连接后重试';

  @override
  String get mobileControlTransportHelp =>
      '控制连接已中断，请确认电脑上的 Whisper 正在运行，再重新开始。';

  @override
  String get mobileControlInjectionHelp => '电脑未能执行输入，请检查系统控制权限后重新开始。';

  @override
  String get clipboardAutoSyncAndroidDesc => '回到 Whisper 后，将新复制的文字同步到当前可信设备';

  @override
  String get historyLoadFailed => '历史记录未能加载，点按重试';

  @override
  String get deleteReceivedFilesDesc => '同时删除接收的本地文件，发送的源文件会保留。';

  @override
  String get keepReceivedFiles => '保留接收的文件';

  @override
  String get messageDeleteFailed => '删除未完成，请重试。';

  @override
  String get connectionQrTab => '二维码';

  @override
  String get connectionScanTab => '扫一扫';

  @override
  String get connectionAddressTab => 'IP / 端口';

  @override
  String get connectionAddressLabel => 'IP 地址或主机名';

  @override
  String get connectionDetailsTab => '本机信息';

  @override
  String get connectionAddressHint => '填写对方 Whisper 首页显示的地址和端口。两台设备需连接同一局域网。';

  @override
  String get qrCopyFailed => '复制失败，请重试';

  @override
  String get attachFile => '文件';

  @override
  String get attachFolder => '文件夹';

  @override
  String folderFileCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString 个文件',
      zero: '空文件夹',
    );
    return '$_temp0';
  }

  @override
  String folderSkippedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString 项未传';
  }

  @override
  String get folderSkippedTitle => '未传输的项目';

  @override
  String folderSkippedMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '另有 $countString 项的详情需要在对方设备上查看';
  }

  @override
  String get folderSkipSymlink => '链接不会被发送';

  @override
  String get folderSkipSpecial => '不是普通文件';

  @override
  String get folderSkipInvalidName => '名称在其他系统上不可用';

  @override
  String get folderSkipPathTooLong => '路径过长或层级过深';

  @override
  String get folderSkipTooLarge => '文件过大';

  @override
  String get folderSkipUnreadable => '无法读取';

  @override
  String get folderSkipSourceUnavailable => '发送时已被移动、修改或无法读取';

  @override
  String get folderSkipWriteFailed => '无法保存到这台设备';

  @override
  String get folderSkipNameCollision => '与同目录的另一项只有大小写不同';

  @override
  String get folderSkipIntegrity => '校验未通过';

  @override
  String get folderSendFailed => '无法发送这个文件夹';

  @override
  String get folderSendUnsupported => '对方的 Whisper 版本不支持接收文件夹，请先升级对方';

  @override
  String get folderSendInvalidName => '文件夹名称在其他系统上不可用，请改名后再发';

  @override
  String get folderSendUnreadable => '无法读取这个文件夹';

  @override
  String folderSendTooManyEntries(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return '文件夹内超过 $limitString 项，请分批发送';
  }

  @override
  String get folderSendTooLarge => '文件夹超过 1 TB，无法发送';

  @override
  String folderFileProgress(int done, int total) {
    final intl.NumberFormat doneNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String doneString = doneNumberFormat.format(done);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$doneString/$totalString 个文件';
  }

  @override
  String get windowStreamTitle => '手机应用';

  @override
  String get windowStreamConnecting => '正在连接…';

  @override
  String get windowStreamPaused => '已暂停，点按继续';

  @override
  String get windowStreamReconnecting => '正在重新连接…';

  @override
  String get windowStreamDisplaced => '已回到手机上，点按拿回来';

  @override
  String get windowStreamSecureBlocked => '此应用不允许投屏';

  @override
  String get windowStreamAppExited => '应用已退出';

  @override
  String get windowStreamDisconnected => '连接已断开，可以关闭这个窗口';

  @override
  String get windowStreamNoDevice => '没有发现手机';

  @override
  String get windowStreamNoDeviceHint => '用数据线连接手机，或在手机的开发者选项里打开“无线调试”。';

  @override
  String get windowStreamUnauthorized => '请在手机上允许这台电脑调试';

  @override
  String get windowStreamDeviceOffline => '手机暂时连不上，请重新插拔数据线或重新打开无线调试';

  @override
  String get windowStreamAdbMissing => '没有找到 adb，请先安装 Android 平台工具';

  @override
  String get windowStreamAdbFailed => 'adb 服务没能启动';

  @override
  String get windowStreamUnsupported => '这台电脑暂时还不能打开手机应用窗口';

  @override
  String get windowStreamRunningApps => '正在运行';

  @override
  String get windowStreamAllApps => '所有应用';

  @override
  String get windowStreamSearchApps => '搜索应用';

  @override
  String get windowStreamLoadingApps => '正在读取应用…';

  @override
  String get windowStreamOnDesktop => '在桌面上';

  @override
  String get windowStreamShowSystemApps => '显示系统应用';

  @override
  String get windowStreamRetry => '重试';

  @override
  String get windowStreamInjectDenied => '小米手机还要在开发者选项里打开“USB 调试（安全设置）”，然后重启手机';

  @override
  String get windowStreamAndroidTooOld => '需要 Android 10 或更新的系统';

  @override
  String get windowStreamOpenFailed => '没能打开这个应用';

  @override
  String get windowStreamNoApps => '没有读到应用';

  @override
  String get windowStreamSpaceTitle => '流转';

  @override
  String get windowStreamRecents => '最近';

  @override
  String get windowStreamWindows => '窗口';

  @override
  String get windowStreamApps => '应用';

  @override
  String get windowStreamViaUsb => 'USB 连接';

  @override
  String get windowStreamViaWifi => '无线调试';

  @override
  String get windowStreamViaWhisper => '已连接';

  @override
  String get windowStreamStatusLive => '直播';

  @override
  String get windowStreamStatusPaused => '已暂停';

  @override
  String get windowStreamStatusConnecting => '连接中';

  @override
  String get windowStreamStatusEnded => '已断开';

  @override
  String get windowStreamPause => '暂停';

  @override
  String get windowStreamResume => '继续';

  @override
  String get windowStreamClose => '关闭';

  @override
  String get windowStreamNoWindows => '还没有打开的窗口';

  @override
  String get windowStreamNoWindowsHint => '点开一个应用或最近任务，它会出现在这里';

  @override
  String get windowStreamNoDevices => '还没有可用的设备';

  @override
  String get windowStreamNoDevicesHintDesktop =>
      '用数据线连接安卓手机，或在手机的开发者选项里打开“无线调试”。';

  @override
  String get windowStreamNoDevicesHintMobile =>
      '在 Mac 上打开 Whisper，并和这台设备互相信任后，Mac 的窗口会出现在这里。';

  @override
  String get windowStreamLoadFailed => '没能读取这台设备的应用';

  @override
  String get windowStreamBackToSpace => '返回流转';

  @override
  String get windowStreamKeyboard => '键盘';

  @override
  String get windowStreamNoRecents => '这台设备上没有正在运行的应用';

  @override
  String get windowStreamSourceLocked => '这台电脑已锁屏，解锁后才能流转它的窗口';

  @override
  String get windowStreamCapturePermission =>
      '这台电脑还没允许 Whisper 录屏，请在它的“系统设置 › 隐私与安全性 › 录屏”里打开';

  @override
  String get windowStreamUntrusted =>
      '这台手机的 Whisper 还没和本机配对。在手机上打开 Whisper，连接本机并确认配对后才能流转';

  @override
  String get windowStreamWhisperMissing =>
      '这台手机上没有可用的 Whisper。装上最新版 Whisper 并和本机配对后才能流转';

  @override
  String get windowStreamNotPaired => '未配对';

  @override
  String get windowStreamOpenHere => '在本机打开';

  @override
  String windowStreamSendTo(String device) {
    return '送到 $device';
  }

  @override
  String windowStreamSendHint(String device) {
    return '选一个本机窗口送到 $device。点开后窗口会挪到那台设备上，不再占这台电脑的屏幕；那边关掉后自动回到原处。';
  }

  @override
  String windowStreamSent(String device) {
    return '已送到 $device，在那台设备上点开即可查看';
  }

  @override
  String get windowStreamSendFailed => '没能送过去，请确认那台设备连着本机';

  @override
  String windowStreamSendUnavailable(String device) {
    return '$device 上的 Whisper 需要连接本机并更新到最新版，才能接收窗口';
  }

  @override
  String get windowStreamNoLocalWindows => '本机没有可以送出去的窗口';

  @override
  String windowStreamOfferTitle(String device) {
    return '$device 送来了一个窗口';
  }

  @override
  String get windowStreamOfferView => '查看';

  @override
  String windowStreamOfferFrom(String device) {
    return '来自 $device';
  }

  @override
  String get remoteFilesTitle => '文件';

  @override
  String remoteFilesOfDevice(String device) {
    return '$device 的文件';
  }

  @override
  String get remoteFilesThisDevice => '本机';

  @override
  String remoteFilesWaiting(String device) {
    return '正在等 $device 允许…';
  }

  @override
  String remoteFilesDenied(String device) {
    return '$device 没有允许浏览文件';
  }

  @override
  String remoteFilesOffline(String device) {
    return '$device 现在没有连接本机';
  }

  @override
  String remoteFilesUnsupported(String device) {
    return '$device 上的 Whisper 需要更新到最新版才能浏览文件';
  }

  @override
  String get remoteFilesEmptyFolder => '这个文件夹是空的';

  @override
  String remoteFilesCopyTo(String target) {
    return '拷贝到 $target';
  }

  @override
  String get remoteFilesNewFolder => '新建文件夹';

  @override
  String get remoteFilesFolderName => '文件夹名称';

  @override
  String get remoteFilesRename => '重命名';

  @override
  String get remoteFilesMoveToTrash => '移到废纸篓';

  @override
  String get remoteFilesDelete => '删除';

  @override
  String remoteFilesDeleteForever(int count) {
    return '要永久删除这 $count 项吗？这台设备没有废纸篓，删除后无法恢复。';
  }

  @override
  String remoteFilesCopyStarted(int count) {
    return '正在拷贝 $count 项';
  }

  @override
  String get remoteFilesFailed => '操作没有完成';

  @override
  String get remoteFilesNameExists => '这里已经有同名的文件或文件夹';

  @override
  String get remoteFilesShowHidden => '显示隐藏文件';

  @override
  String remoteFilesItemCount(int count) {
    return '$count 项';
  }

  @override
  String remoteFilesSelected(int count) {
    return '已选 $count 项';
  }

  @override
  String get remoteFilesCreate => '新建';

  @override
  String get remoteFilesDone => '完成';

  @override
  String remoteFilesDropHint(String device) {
    return '拖到这里，拷贝到 $device';
  }

  @override
  String get remoteFilesPlaceRoot => '主目录';

  @override
  String get remoteFilesPlaceStorage => '内部存储';

  @override
  String get remoteFilesPlaceDesktop => '桌面';

  @override
  String get remoteFilesPlaceDocuments => '文稿';

  @override
  String get remoteFilesPlaceDownloads => '下载';

  @override
  String get remoteFilesPlacePictures => '图片';

  @override
  String get remoteFilesPlaceCamera => '相机';

  @override
  String get remoteFilesPlaceMovies => '影片';

  @override
  String get remoteFilesPlaceMusic => '音乐';

  @override
  String remoteFilesPromptTitle(String device) {
    return '$device 想浏览你的文件';
  }

  @override
  String get remoteFilesPromptBodyDesktop =>
      '允许后，它能看到你的主目录，并在里面拷贝、新建、重命名和删除文件。删除的文件会进废纸篓。';

  @override
  String get remoteFilesPromptBodyPhone =>
      '允许后，它能看到这台手机的内部存储，并在里面拷贝、新建、重命名和删除文件。删除的文件不能恢复。';

  @override
  String get remoteFilesDeny => '拒绝';

  @override
  String get remoteFilesAllowOnce => '允许这一次';

  @override
  String get remoteFilesAllowAlways => '始终允许';

  @override
  String windowStreamTouchBlockedTitle(String device) {
    return '$device 现在点不动了';
  }

  @override
  String windowStreamTouchBlockedBody(String app) {
    return '$app 留在后台的一个页面挡住了手机屏幕，手机收不到触摸。关掉这个页面就能恢复，$app 不会被卸载，账号和记录都还在。';
  }

  @override
  String get windowStreamTouchBlockedFix => '关掉这个页面';

  @override
  String get windowStreamTouchBlockedLater => '以后再说';

  @override
  String get windowStreamTouchBlockedFixed => '好了，手机可以操作了';

  @override
  String get remoteFilesFavorites => '个人收藏';

  @override
  String get remoteFilesLocations => '位置';

  @override
  String get remoteFilesBrowse => '浏览';

  @override
  String remoteFilesWaitingAllow(String device) {
    return '请在 $device 上点“允许”';
  }

  @override
  String get remoteFilesWaitingDetail => 'Whisper 正在那台设备上询问是否让本机浏览文件。';

  @override
  String get remoteFilesAskAgain => '再问一次';

  @override
  String get remoteFilesColumnName => '名称';

  @override
  String get remoteFilesColumnModified => '修改日期';

  @override
  String get remoteFilesColumnSize => '大小';

  @override
  String get remoteFilesColumnKind => '种类';

  @override
  String get remoteFilesKindFolder => '文件夹';

  @override
  String get remoteFilesKindImage => '图像';

  @override
  String get remoteFilesKindVideo => '影片';

  @override
  String get remoteFilesKindAudio => '音频';

  @override
  String get remoteFilesKindDocument => '文稿';

  @override
  String get remoteFilesKindArchive => '归档';

  @override
  String get remoteFilesKindCode => '源代码';

  @override
  String get remoteFilesKindApp => '应用程序';

  @override
  String get remoteFilesKindOther => '文件';

  @override
  String remoteFilesKindNamed(String ext, String kind) {
    return '$ext $kind';
  }

  @override
  String get remoteFilesViewList => '列表';

  @override
  String get remoteFilesViewIcons => '图标';

  @override
  String get remoteFilesSearch => '搜索';

  @override
  String remoteFilesNoResults(String query) {
    return '没有找到“$query”';
  }

  @override
  String get remoteFilesForward => '前进';

  @override
  String get remoteFilesOpen => '打开';

  @override
  String get remoteFilesCopy => '拷贝';

  @override
  String remoteFilesPaste(int count) {
    return '粘贴 $count 项';
  }

  @override
  String get remoteFilesRefresh => '刷新';

  @override
  String remoteFilesStatusSelected(int selected, int count) {
    return '已选择 $selected 项，共 $count 项';
  }

  @override
  String remoteFilesCopyProgress(int count, int percent) {
    return '正在拷贝 $count 项 · $percent%';
  }

  @override
  String remoteFilesCopyDone(int count) {
    return '已拷贝 $count 项';
  }

  @override
  String remoteFilesCopyPartly(int failed) {
    return '$failed 项没有拷贝成功';
  }

  @override
  String get remoteFilesSameDevice => '已经在这台设备上了';

  @override
  String get remoteFilesBetweenOthers => '只能在本机和另一台设备之间拷贝';

  @override
  String remoteFilesOpenFirst(String device) {
    return '先打开 $device 的文件';
  }

  @override
  String get remoteFilesUntitledFolder => '未命名文件夹';

  @override
  String get remoteFilesSelect => '选择';

  @override
  String get remoteFilesSelectAll => '全选';

  @override
  String get remoteFilesCopyToMenu => '拷贝到…';

  @override
  String get remoteFilesCopyHere => '拷贝到这里';

  @override
  String get remoteFilesChooseDestination => '选好位置后点“拷贝到这里”';

  @override
  String remoteFilesToday(String time) {
    return '今天 $time';
  }

  @override
  String remoteFilesYesterday(String time) {
    return '昨天 $time';
  }

  @override
  String get remoteFilesCopyToSubmenu => '拷贝到';

  @override
  String remoteFilesPasteInto(String name) {
    return '粘贴到“$name”';
  }

  @override
  String get remoteFilesPastePlain => '粘贴';

  @override
  String get remoteFilesSortBy => '排序方式';

  @override
  String get remoteFilesMore => '更多';

  @override
  String get remoteFilesClose => '关闭文件';

  @override
  String get remoteFilesClipboardReady => '可以在访达等应用里粘贴了';

  @override
  String get remoteFilesClipboardOnPaste => '已复制，在 Whisper 里粘贴时开始传输';

  @override
  String remoteFilesClipboardOnPasteDrag(String app) {
    return '已复制，在 Whisper 里粘贴时开始传输；放进$app请直接拖过去';
  }

  @override
  String get windowStreamTextSize => '文字大小';

  @override
  String get macPermissionAccessibility => '辅助功能';

  @override
  String get macPermissionAccessibilityDesc => '共享键盘鼠标、在流转来的窗口里操作时需要';

  @override
  String get macPermissionScreenRecording => '屏幕与系统录音';

  @override
  String get macPermissionScreenRecordingDesc =>
      '把窗口流转出去、当扬声器、截图时需要；改了之后重新打开 Whisper 才生效';

  @override
  String get macPermissionAudioCapture => '仅系统录音';

  @override
  String get macPermissionAudioCaptureDesc =>
      '可选。不开也会把声音带过去；开了以后 Mac 这边静音，浏览器的声音也能带上';

  @override
  String get macPermissionGranted => '已允许';

  @override
  String get macPermissionDenied => '未允许';

  @override
  String get macPermissionNotAsked => '未设置';

  @override
  String get macPermissionOptional => '可选';

  @override
  String get windowStreamQuality => '画质';

  @override
  String get windowStreamQualitySmooth => '流畅';

  @override
  String get windowStreamQualityStandard => '标准';

  @override
  String get windowStreamQualityHigh => '高清';

  @override
  String get windowStreamQualityBest => '超清';

  @override
  String get windowStreamQualityHint => '越高越清晰，也越占网络';

  @override
  String get windowStreamReceiveOnly => '只接收窗口';

  @override
  String get windowStreamNotConnected => '未连接';

  @override
  String get windowStreamConnectFirst => '先在 Whisper 里连上这台手机，才能流转它的应用';

  @override
  String windowStreamOpenHereDetail(String device) {
    return '用 $device 上的应用';
  }

  @override
  String windowStreamSendToDetail(String device) {
    return '把窗口挪到 $device 上';
  }

  @override
  String get toolbarMoreTools => '更多功能';

  @override
  String get toolbarFewerTools => '收起';

  @override
  String get windowStreamStreaming => '流转中';

  @override
  String get windowStreamCloseWindow => '关闭窗口';

  @override
  String get windowStreamCloseFailed => '没能关闭这个窗口';

  @override
  String get windowStreamOfferIgnore => '忽略';

  @override
  String get deviceDetailsTitle => '设备详情';

  @override
  String get deviceFeaturesSection => '功能';

  @override
  String get deviceFeatureFlowDetail => '用它的应用和窗口，或把窗口送过去';

  @override
  String get deviceFeatureFilesDetail => '浏览和拷贝它的文件';

  @override
  String get deviceFeatureNeedsConnection => '连接后可用';

  @override
  String get windowStreamSwitcherRotate => '旋转';

  @override
  String get remoteFilesCopyStarting => '正在准备…';

  @override
  String remoteFilesCopyItems(int count) {
    return '$count 个项目';
  }

  @override
  String remoteFilesCopyToDevice(String device, String folder) {
    return '拷贝到 $device 的“$folder”';
  }

  @override
  String get remoteFilesFinder => '访达';

  @override
  String get remoteFilesExplorer => '文件资源管理器';

  @override
  String get remoteFilesFileManager => '文件管理器';

  @override
  String remoteFilesShowInApp(String app) {
    return '在$app中打开';
  }

  @override
  String get remoteFilesEject => '推出';

  @override
  String remoteFilesMountTooOld(String device, String app) {
    return '$device 上的 Whisper 需要更新，才能在$app中打开它的文件';
  }

  @override
  String remoteFilesMountDenied(String device) {
    return '$device 没有允许访问它的文件';
  }

  @override
  String remoteFilesMountFailed(String app, String device) {
    return '$app没能打开 $device 的文件';
  }

  @override
  String remoteFilesMountNeedsFuse(String app) {
    return '要在$app中打开其他设备的文件，需要先安装 fuse3';
  }

  @override
  String remoteFilesCopyFromDevice(String device, String folder) {
    return '从 $device 拷贝到“$folder”';
  }

  @override
  String remoteFilesCopyLeft(String time) {
    return '剩余 $time';
  }

  @override
  String remoteFilesSeconds(int count) {
    return '$count 秒';
  }

  @override
  String remoteFilesMinutes(int count) {
    return '$count 分钟';
  }

  @override
  String remoteFilesHours(int count) {
    return '$count 小时';
  }

  @override
  String remoteFilesCopyItemsDone(int done, int total) {
    return '$done/$total 项';
  }

  @override
  String remoteFilesCopyFilesMoved(int count) {
    return '已传 $count 个文件';
  }

  @override
  String remoteFilesCopyWaiting(String device) {
    return '等待 $device 重新连接…';
  }

  @override
  String get remoteFilesCopyPaused => '已暂停';

  @override
  String get remoteFilesCopyFailedShort => '没有拷贝成功';

  @override
  String get remoteFilesCopyCanceledShort => '已停止';

  @override
  String get remoteFilesCopyDoneShort => '已拷贝';

  @override
  String get remoteFilesCopyResume => '继续';

  @override
  String get remoteFilesCopyRetry => '重试';

  @override
  String get remoteFilesCopyStop => '停止拷贝';

  @override
  String get remoteFilesCopyShowAll => '查看全部传输';

  @override
  String remoteFilesCopyMore(int count) {
    return '还有 $count 个拷贝';
  }

  @override
  String get remoteFilesCopyAlready => '这些项目已经在拷贝到这里了';

  @override
  String get remoteFilesTransfers => '传输';

  @override
  String get remoteFilesTransfersEmpty => '还没有拷贝';

  @override
  String get remoteFilesTransfersEmptyDetail => '在这里拷贝的文件，进度和结果都会列在这里';

  @override
  String get remoteFilesTransfersClear => '清除已结束';

  @override
  String get remoteFilesTransfersActive => '进行中';

  @override
  String get remoteFilesTransfersRecent => '已结束';

  @override
  String get remoteFilesCopyRemove => '从列表中移除';

  @override
  String get remoteFilesCopyReveal => '在文件中显示';

  @override
  String remoteFilesDeleteTitle(int count) {
    return '永久删除 $count 个项目？';
  }

  @override
  String remoteFilesDeleteDetail(String device) {
    return '$device 没有废纸篓，删除后无法恢复。';
  }

  @override
  String remoteFilesAndMore(int count) {
    return '还有 $count 项';
  }

  @override
  String get remoteFilesCopyJustDone => '刚刚已经拷贝过了';

  @override
  String windowStreamHostLocked(String device) {
    return '$device 已锁屏，解锁后才能流转它的窗口';
  }

  @override
  String windowStreamHostPermissionMac(String device) {
    return '$device 还没允许 Whisper 录屏。请在那台 Mac 的“系统设置 › 隐私与安全性 › 录屏与系统录音”里打开 Whisper';
  }

  @override
  String windowStreamHostPermission(String device) {
    return '$device 的系统不允许 Whisper 录制窗口。请在那台电脑的隐私设置里允许 Whisper 录屏，然后再试一次';
  }

  @override
  String windowStreamHostHelper(String device) {
    return '$device 还差一步：请在那台电脑上注销并重新登录一次，之后就能流转它的窗口';
  }

  @override
  String windowStreamHostDesktopUnsupported(String device) {
    return '$device 的桌面暂不支持流转窗口，需要 GNOME 或 KDE Plasma（Wayland）';
  }

  @override
  String windowStreamHostElevated(String device) {
    return '这个窗口以管理员身份运行，Whisper 无法流转它。请在 $device 上以普通身份重新打开这个应用';
  }

  @override
  String get windowStreamHostProtected => '这个窗口不允许录屏，无法在这里显示';

  @override
  String windowStreamHostEncoder(String device) {
    return '$device 没能开始编码画面，请稍后再试';
  }

  @override
  String windowStreamHostEncoderLinux(String device) {
    return '$device 缺少 H.264 视频编码器，无法流转窗口。请在那台电脑上安装 FFmpeg，以及 x264 或 openh264 编码器';
  }

  @override
  String windowStreamHostUnsupported(String device) {
    return '$device 暂时还不能流转窗口。请把那台设备上的 Whisper 更新到最新版';
  }

  @override
  String windowStreamHostUnsupportedWindows(String device) {
    return '$device 需要 Windows 10（1903）或更新的系统才能流转窗口';
  }

  @override
  String windowStreamHostUnsupportedMac(String device) {
    return '$device 需要 macOS 12.3 或更新的系统才能流转窗口';
  }

  @override
  String get windowStreamThatDevice => '那台设备';

  @override
  String remoteFilesPlaceDrive(String name, String drive) {
    return '$name ($drive:)';
  }

  @override
  String remoteFilesPlaceLocalDisk(String drive) {
    return '本地磁盘 ($drive:)';
  }

  @override
  String remoteFilesPlaceRemovableDisk(String drive) {
    return 'U 盘 ($drive:)';
  }

  @override
  String get remoteFilesPlaceAppFolder => 'Whisper 文件夹';

  @override
  String islandTransferTo(String device) {
    return '发送给 $device';
  }

  @override
  String islandTransferFrom(String device) {
    return '来自 $device';
  }

  @override
  String get islandTransferMixed => '正在收发';

  @override
  String islandTransferFiles(int count) {
    return '$count 个文件';
  }

  @override
  String get islandTransferSent => '已发送';

  @override
  String get islandTransferReceived => '已收到';

  @override
  String get islandTransferFailed => '没有传完';

  @override
  String get islandTransferStop => '停止传输';

  @override
  String get islandAudioPaused => '已暂停播放';

  @override
  String get islandAudioStarting => '正在连接…';

  @override
  String get islandAudioEnded => '已断开';

  @override
  String islandStreamedTitle(String device) {
    return '正在流转到 $device';
  }

  @override
  String islandStreamedWindows(int count) {
    return '$count 个窗口正在那台设备上显示，可以被操作';
  }

  @override
  String get islandStreamedStop => '停止流转';

  @override
  String get islandStreamedStopping => '正在停止…';

  @override
  String get islandStreamedEnded => '流转已结束';

  @override
  String get islandStreamedOtherDevice => '另一台设备';

  @override
  String islandMore(int count) {
    return '还有 $count 项';
  }

  @override
  String get islandHint => '轻点展开，向上轻扫收起';

  @override
  String get shareLinkMenuCreate => '创建共享链接…';

  @override
  String get shareLinkCreateTitle => '创建共享链接';

  @override
  String get shareLinkCreateDetail => '同一局域网里的设备用浏览器打开链接就能下载，不用装 Whisper。';

  @override
  String shareLinkDefaultName(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个项目',
    );
    return '$_temp0';
  }

  @override
  String get shareLinkRoute => '路由';

  @override
  String get shareLinkRouteHelp => '不填就用上面这个随机路由';

  @override
  String get shareLinkShortRoute => '简短路由';

  @override
  String get shareLinkShortRouteDetail => '4 个字符，方便口头告诉别人';

  @override
  String get shareLinkPassword => '密码';

  @override
  String get shareLinkPasswordOptional => '可不填';

  @override
  String get shareLinkShowPassword => '显示密码';

  @override
  String get shareLinkHidePassword => '隐藏密码';

  @override
  String get shareLinkCreate => '创建链接';

  @override
  String get shareLinkRouteTaken => '已经有链接在用这个路由了';

  @override
  String get shareLinkRouteInvalid => '路由要 2–32 个字符，只能用小写字母、数字、- 和 _';

  @override
  String get shareLinkRouteReserved => '这个路由留作他用了，换一个吧';

  @override
  String get shareLinkItemsMissing => '要共享的文件已经不在了';

  @override
  String get shareLinkCreateFailed => '没能创建链接';

  @override
  String get shareLinkReady => '链接已创建';

  @override
  String get shareLinkCopy => '复制链接';

  @override
  String get shareLinkCopied => '已复制';

  @override
  String get shareLinkScanHint => '也可以用手机相机扫一扫';

  @override
  String get shareLinkAddressPicker => '选择网络地址';

  @override
  String get shareLinkServiceOffNote => '服务已关闭，打开后链接才能访问';

  @override
  String get shareLinkNoNetwork => '没有连上局域网，其他设备暂时打不开';

  @override
  String get shareLinkPasswordProtected => '有密码';

  @override
  String get shareLinksTitle => '共享链接';

  @override
  String shareLinksActiveCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个链接开着',
    );
    return '$_temp0';
  }

  @override
  String get shareLinksService => '文件服务';

  @override
  String shareLinksServiceRunning(String port) {
    return '正在运行，端口 $port';
  }

  @override
  String get shareLinksServiceIdle => '没有开着的链接，端口已关闭';

  @override
  String get shareLinksServiceOff => '已关闭。链接都还在，只是暂时打不开。';

  @override
  String get shareLinksServiceStarting => '正在启动…';

  @override
  String shareLinksServicePortsBusy(String from, String to) {
    return '端口 $from–$to 都被占用了';
  }

  @override
  String get shareLinksServiceFailed => '启动失败';

  @override
  String get shareLinkStatusOn => '已开启';

  @override
  String get shareLinkStatusOff => '已关闭';

  @override
  String get shareLinkStatusMissing => '文件不见了';

  @override
  String get shareLinkStatusPartlyMissing => '部分文件不见了';

  @override
  String shareLinkVisits(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 次访问',
    );
    return '$_temp0';
  }

  @override
  String shareLinkDownloads(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 次下载',
    );
    return '$_temp0';
  }

  @override
  String shareLinkLastVisit(String time) {
    return '最近访问 $time';
  }

  @override
  String get shareLinkNeverVisited => '还没人打开过';

  @override
  String shareLinkBytesServed(String size) {
    return '已发送 $size';
  }

  @override
  String get shareLinkQr => '二维码';

  @override
  String get shareLinkTurnOn => '开启链接';

  @override
  String get shareLinkTurnOff => '关闭链接';

  @override
  String get shareLinkDelete => '删除链接';

  @override
  String get shareLinkDeleteTitle => '删除这个共享链接？';

  @override
  String get shareLinkDeleteDetail => '这个地址会马上失效，本机上的文件不受影响。';

  @override
  String get shareLinksEmpty => '还没有共享链接';

  @override
  String get shareLinksEmptyDetailDesktop =>
      '在本机的文件或文件夹上右键，选“创建共享链接…”。也可以先选好多个再右键。';

  @override
  String get shareLinksEmptyDetailPhone =>
      '在本机的文件或文件夹上长按，选“创建共享链接…”。也可以多选后从底部选。';

  @override
  String get shareWebDownload => '下载';

  @override
  String get shareWebOpen => '在浏览器中打开';

  @override
  String get shareWebDownloadAll => '全部下载（.zip）';

  @override
  String get shareWebDownloadZip => '下载为 .zip';

  @override
  String shareWebItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 项',
    );
    return '$_temp0';
  }

  @override
  String get shareWebEmptyFolder => '这个文件夹是空的';

  @override
  String shareWebModified(String date) {
    return '修改于 $date';
  }

  @override
  String shareWebFooter(String device) {
    return '来自 $device · 用 Whisper 共享';
  }

  @override
  String get shareWebNotFoundTitle => '这个链接打不开';

  @override
  String get shareWebNotFoundDetail => '链接可能已经关闭，或者地址输错了。请找分享的人确认一下。';

  @override
  String get shareWebMissingTitle => '文件不见了';

  @override
  String get shareWebMissingDetail => '它可能被移动、改名或删除了。';

  @override
  String get shareWebBack => '回到共享内容';

  @override
  String get shareWebPasswordTitle => '需要密码';

  @override
  String get shareWebPasswordDetail => '这个共享链接设置了密码。';

  @override
  String get shareWebContinue => '继续';

  @override
  String get shareWebPasswordWrong => '密码不对，再试一次';

  @override
  String get shareWebTooManyTitle => '尝试次数太多';

  @override
  String get shareWebTooManyDetail => '请等 1 分钟再试。';

  @override
  String get shareWebErrorTitle => '出了点问题';

  @override
  String get shareWebErrorDetail => '请稍后再试。';

  @override
  String get windowStreamDecoderMissing => '无法显示画面：这台电脑缺少 FFmpeg 视频解码库';

  @override
  String get windowStreamVolume => '音量';

  @override
  String get windowStreamMute => '静音';

  @override
  String get windowStreamUnmute => '取消静音';

  @override
  String get windowStreamMovedAway => '这个窗口已在另一台设备上打开';

  @override
  String flowTaskOpenOn(String device) {
    return '正在 $device 上显示';
  }

  @override
  String get shareLinkBarAction => '共享链接';

  @override
  String get windowStreamSourceErrorDesktopUnsupported => '这台电脑不支持窗口流转';

  @override
  String get windowStreamSourceErrorElevated => '这个窗口以管理员身份运行，无法流转';

  @override
  String windowStreamSourceNoteStagedInPlace(String app) {
    return '$app 不支持在后台运行，正在原位置流转';
  }

  @override
  String get gnomeHelperTitle => '窗口流转组件';

  @override
  String get gnomeHelperHint => '其他设备流转本机窗口需要一个 GNOME 小组件，首次安装后要注销并重新登录一次';

  @override
  String get gnomeHelperWorking => '正在安装…';

  @override
  String get gnomeHelperReady => '已就绪';

  @override
  String get gnomeHelperNotInstalled => '未安装';

  @override
  String get gnomeHelperNeedsRelogin => '需重新登录';

  @override
  String get gnomeHelperOutdated => '需要更新';

  @override
  String get gnomeHelperDisabled => '已停用';

  @override
  String get gnomeHelperExtensionsOff => '扩展已关闭';

  @override
  String get gnomeHelperInstallDesc =>
      'Whisper 会给 GNOME 装一个小扩展：被流转的窗口在后台运行，键盘和鼠标由它转交。只有 Whisper 能使用它。装好后需要注销并重新登录一次。';

  @override
  String get gnomeHelperUpdateDesc =>
      '这个版本的 Whisper 带来了新的窗口流转组件。更新后需要注销并重新登录一次。';

  @override
  String get gnomeHelperReloginDesc =>
      '组件已经装好，GNOME 要在重新登录后才会加载它。注销前请先保存好其他应用里的内容。';

  @override
  String get gnomeHelperDisabledDesc =>
      '窗口流转组件在 GNOME 的“扩展”里被关掉了。重新打开后，其他设备才能流转本机窗口。';

  @override
  String get gnomeHelperExtensionsOffDesc =>
      'GNOME 扩展目前全部关闭。打开扩展后，窗口流转组件才能运行（其他已装的扩展也会一起打开）。';

  @override
  String get gnomeHelperReadyDesc => '窗口流转组件正在运行。其他设备可以把本机窗口流转过去，窗口会在本机后台继续运行。';

  @override
  String get gnomeHelperInstall => '安装';

  @override
  String get gnomeHelperUpdate => '更新';

  @override
  String get gnomeHelperLogOut => '注销…';

  @override
  String get gnomeHelperLater => '稍后';

  @override
  String get gnomeHelperTurnOn => '打开';

  @override
  String get gnomeHelperTurnOnExtensions => '打开扩展';

  @override
  String get gnomeHelperDone => '好';

  @override
  String get gnomeHelperInstalled => '已安装。注销并重新登录后即可使用';

  @override
  String get gnomeHelperFailed => '无法安装窗口流转组件';

  @override
  String get windowStreamShareSetting => '允许查看和操作本机窗口';

  @override
  String get windowStreamShareSettingDesc => '已信任的设备可以在它们那边打开并操作这台电脑上的窗口';

  @override
  String get deviceFilesAlwaysAllowed => '始终允许浏览我的文件';

  @override
  String get deviceMountHere => '挂载到本机';

  @override
  String windowStreamCloseStillOpen(String app) {
    return '“$app”还没有关闭，可能在问你是否保存';
  }

  @override
  String get windowStreamCloseShow => '打开窗口';

  @override
  String get windowStreamClosing => '正在关闭';

  @override
  String shareWebFrom(String device) {
    return '来自 $device';
  }

  @override
  String get shareWebFooterLan => '文件直接从这台设备经局域网传来，不经过云端。';

  @override
  String shareWebPreviewTruncated(String size) {
    return '只显示了前 $size，下载后可查看全部内容。';
  }

  @override
  String get shareWebPrevious => '上一个';

  @override
  String get shareWebNext => '下一个';

  @override
  String get shareLinkAllowAccess => '允许访问';

  @override
  String get shareLinkAddress => '地址';

  @override
  String get shareLinksServiceFooter => '同一局域网里的设备用浏览器打开链接就能下载。服务只在有开着的链接时运行。';

  @override
  String get shareLinkVisitsLabel => '访问次数';

  @override
  String get shareLinkDownloadsLabel => '下载次数';

  @override
  String get shareLinkLastVisitLabel => '最近访问';

  @override
  String get shareLinkSentLabel => '已发送';

  @override
  String get shareLinkNever => '从未';

  @override
  String get androidWindowServiceTitle => '窗口流转服务';

  @override
  String get androidWindowServiceRunning => '已开启';

  @override
  String get androidWindowServiceRunningHint =>
      '你信任的电脑现在可以在它们的流转里看到这台手机，打开手机上的应用来操作';

  @override
  String get androidWindowServiceStopped => '未运行';

  @override
  String get androidWindowServiceStoppedHint => '打开无线调试后，这里可以重新开启，无需再插电脑';

  @override
  String get androidWindowServiceNeedsSetup => '未设置';

  @override
  String get androidWindowServiceNeedsSetupHint =>
      '开启后，这台手机的应用可以流转到你信任的电脑上查看和操作，手机留在后台';

  @override
  String get androidWindowServiceStart => '开启服务';

  @override
  String get androidWindowServiceStop => '停止服务';

  @override
  String get androidWindowServiceSetup => '开始设置';

  @override
  String get androidWindowServiceHowTitle => '一次性设置';

  @override
  String get androidWindowServiceStep1 => '打开开发者选项';

  @override
  String get androidWindowServiceStep1Hint => '在“关于手机”里连续点击“版本号”7 次';

  @override
  String get androidWindowServiceStep1Action => '打开“关于手机”';

  @override
  String get androidWindowServiceStep2 => '打开无线调试';

  @override
  String get androidWindowServiceStep2Hint =>
      '在“开发者选项”里打开“无线调试”，并保持本页在同一屏打开“使用配对码配对设备”';

  @override
  String get androidWindowServiceStep2Action => '打开“开发者选项”';

  @override
  String get androidWindowServiceStep3 => '输入配对码';

  @override
  String get androidWindowServiceStep3Hint =>
      '把系统显示的 6 位配对码填到这里，Whisper 会和这台手机自己配对并开启服务';

  @override
  String get androidWindowServicePairingCode => '配对码';

  @override
  String get androidWindowServicePair => '配对并开启';

  @override
  String get androidWindowServicePairing => '正在配对…';

  @override
  String get androidWindowServiceStarting => '正在开启…';

  @override
  String get androidWindowServiceAutoStart => '重启后自动开启';

  @override
  String get androidWindowServiceAutoStartHint =>
      '需要授予 Whisper 一项系统权限来开启无线调试；只有你信任的电脑才能连上，随时可在这里关闭';

  @override
  String get androidWindowServiceStarted => '窗口流转服务已开启';

  @override
  String get androidWindowServiceStopped2 => '窗口流转服务已停止';

  @override
  String get androidWindowServiceStartFailed => '开启失败，请确认无线调试已打开并重试';

  @override
  String get androidWindowServicePairFailed => '配对失败，请核对配对码后重试';

  @override
  String get androidWindowServiceEntryTitle => '窗口流转服务';

  @override
  String get androidWindowServiceEntryHint => '让其他设备流转这台手机的应用';

  @override
  String get androidWindowServiceComputerHint =>
      '把这台手机连到一台装了 Whisper、开着窗口流转的电脑一次，就能开启；之后其他电脑都能用';

  @override
  String windowStreamPhoneServiceOff(String device) {
    return '在 $device 上打开 Whisper，到“设置 → 窗口流转服务”里开启服务';
  }

  @override
  String remoteFilesNoAnswer(String device) {
    return '$device 没有回应';
  }

  @override
  String get remoteFilesNoAnswerDetail => '那台设备上的询问已经过期。请确认对方在设备旁，再试一次。';

  @override
  String remoteFilesNotAsked(String device) {
    return '浏览 $device 的文件需要对方允许';
  }

  @override
  String get deviceFilesAllowChanges => '允许修改我的文件';

  @override
  String get remoteFilesPromptAllowChanges => '允许修改文件';

  @override
  String remoteFilesReadOnlyHost(String device) {
    return '$device 只允许读取它的文件';
  }

  @override
  String get remoteFilesPromptBodyReadOnlyDesktop =>
      '允许后，它能看到你的主目录，打开和拷出里面的文件，但不能改动。';

  @override
  String get remoteFilesPromptBodyReadOnlyPhone =>
      '允许后，它能看到这台手机的内部存储，打开和拷出里面的文件，但不能改动。';
}
