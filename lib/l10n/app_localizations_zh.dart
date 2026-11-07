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
  String get remoteInputPeerControlling => '正在控制本机';

  @override
  String get remoteInputPeerReceiving => '正在控制本机';

  @override
  String get remoteInputPeerReady => '已就绪，等待切入';

  @override
  String get mobileControlPreparing => '正在连接控制';

  @override
  String get mobileControlAir => '体感鼠标';

  @override
  String get mobileControlTouchpad => '触控板';

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
  String get mobileControlTextUnconfirmed => '未确认是否输入成功，草稿已保留';

  @override
  String get mobileControlTextSent => '已发送到电脑';

  @override
  String get mobileControlSensitivity => '体感移动速度';

  @override
  String get mobileControlCalibrate => '校准';

  @override
  String get mobileControlCalibrating => '请保持手机静止片刻…';

  @override
  String get mobileControlCalibrationDone => '校准完成';

  @override
  String mobileControlReceiving(String name) {
    return '本机正由 $name 控制';
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
  String get screenshotMarkUp => '标注';

  @override
  String get captureRect => '框';

  @override
  String get captureEllipse => '圈';

  @override
  String get captureArrow => '箭头';

  @override
  String get capturePen => '画笔';

  @override
  String get captureText => '文字';

  @override
  String get captureMosaic => '马赛克';

  @override
  String get captureUndo => '撤销';

  @override
  String get captureRedo => '重做';

  @override
  String get captureSave => '存为文件';

  @override
  String get messageCopy => '复制';

  @override
  String get diagTitle => '诊断信息';

  @override
  String get diagDatabase => '数据库';

  @override
  String get diagServer => '连接服务';

  @override
  String get diagDiscovery => '发现设备';

  @override
  String get diagOk => '正常';

  @override
  String get diagFailed => '出错了';

  @override
  String get healthTitle => 'Whisper 没有正常运行';

  @override
  String get healthDatabase => '本地数据库打不开，聊天记录和设备都用不了，也发现不了其他设备。';

  @override
  String get healthStartup => '启动时出错了，发现不了其他设备，其他设备也连不上这台。';

  @override
  String get healthServer => '连接服务没有启动，其他设备连不上这台。';

  @override
  String get healthDiscovery => '发现设备没有启动，附近的设备可能显示不出来。';

  @override
  String get diagRestartHint => '可以先重启 Whisper。还不行就把诊断信息发给我们。';

  @override
  String get diagView => '查看';

  @override
  String get diagCopy => '拷贝';

  @override
  String get diagCopied => '诊断信息已拷贝';

  @override
  String get diagFeedback => '反馈问题';

  @override
  String get diagFeedbackCopied => '诊断信息已拷贝，粘贴到问题里就行';

  @override
  String get diagPrivacy => '不含消息、文件和设备名，只有系统版本、本机网络地址和运行记录。只有你发出去才会离开这台设备。';

  @override
  String get diagOldHistory => '旧版本的聊天记录读取不了，还在原来的位置，没有被删除。';

  @override
  String get healthOldHistory => '旧版本的聊天记录读取不了';

  @override
  String get screenshotCopied => '截图已复制';

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
  String get screenshotShortcutUnavailable => '快捷键未注册 · 点击配置';

  @override
  String get screenshotShortcutInvalid => '请使用有效组合键，并避开快捷发送的快捷键';

  @override
  String get screenshotShortcutFailed => '快捷键保存失败，可能已被占用、被取消或桌面环境不支持，请尝试其他组合';

  @override
  String get connectDeviceTitle => '连接设备';

  @override
  String get connectRequest => '连接请求';

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
  String get allow => '允许';

  @override
  String get refuse => '拒绝';

  @override
  String get cancel => '取消';

  @override
  String get retry => '重试';

  @override
  String get setting => '设置';

  @override
  String get trust => '自动接受连接';

  @override
  String get writeClipboard => '写入剪贴板';

  @override
  String get deleteDevice => '删除设备';

  @override
  String get serverPortTitle => '服务端口';

  @override
  String get clipboardAutoSync => '自动同步剪贴板';

  @override
  String get close2tray => '关闭时隐藏到托盘';

  @override
  String get nickname => '昵称';

  @override
  String get port => '服务端口';

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
  String get menuClipboard => '发送剪贴板';

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
  String get warning => '警告';

  @override
  String get close => '关闭';

  @override
  String deleteDeviceTitle(String device) {
    return '删除 $device';
  }

  @override
  String get deleteDeviceDesc => '断开连接并删除与该设备的所有消息，不可恢复';

  @override
  String get connectFailed => '连接失败';

  @override
  String get connectAlreadyInProgress => '连接正在进行中';

  @override
  String get startServerFailed => '服务启动失败';

  @override
  String get deleteMessageTitle => '删除消息';

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
  String get open => '打开';

  @override
  String get openInFinder => '在访达中显示';

  @override
  String get openInDir => '所在文件夹';

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
  String get shareFile => '分享';

  @override
  String get shareFileFailed => '无法分享文件';

  @override
  String get themeMode => '主题模式';

  @override
  String get followSystem => '跟随系统';

  @override
  String get connectedNow => '当前已连接';

  @override
  String get nearbyAvailable => '附近可连接';

  @override
  String get noMessagesYet => '没有消息';

  @override
  String get sharedFile => '发送了一个文件';

  @override
  String get localeNameZhHans => '简体中文';

  @override
  String get localeNameEnglish => 'English';

  @override
  String get localeNameSpanish => 'Español';

  @override
  String get autoConnectTrustedDevices => '自动连接已配对设备';

  @override
  String get windowsLockScreenInput => '锁屏与 UAC 时接收键鼠';

  @override
  String get windowsLockScreenInputDesc => '将安装系统服务，让已配对设备可在本机锁屏时输入密码。需要管理员确认。';

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
      '开启后已配对设备可操作 UAC 提示，但本机上以你身份运行的程序也能借此绕过 UAC。需要管理员确认。';

  @override
  String get windowsElevatedInputDisableDesc =>
      '关闭后已配对设备无法操作 UAC 提示，锁屏输入不受影响。需要管理员确认。';

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
  String get androidBackgroundKeepAliveActiveTitle => 'Whisper 正在监听局域网连接';

  @override
  String get androidBackgroundKeepAliveActiveDesc => '可在后台接收附近设备的连接请求';

  @override
  String get androidBatteryOptimization => '电池优化白名单';

  @override
  String get fileTransferQueued => '排队中';

  @override
  String fileTransferPreparingResume(String progress) {
    return '准备续传 $progress%';
  }

  @override
  String get fileTransferNegotiating => '正在准备';

  @override
  String fileTransferWaitingReconnect(String progress) {
    return '等待重连 $progress%';
  }

  @override
  String get fileTransferPaused => '已暂停';

  @override
  String get fileTransferVerifying => '校验中';

  @override
  String get fileTransferWaitingPeerVerification => '等待对方校验';

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
  String get audioShareStart => '把本机声音共享给对方';

  @override
  String get remoteInputScrollMultiplierTitle => '滚轮速度';

  @override
  String get audioShareUnsupportedCapture => '当前设备不支持系统音频采集';

  @override
  String get audioGroupSelectSinks => '选择播放设备';

  @override
  String get audioGroupStart => '开始同步播放';

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
  String audioShareFailed(String error) {
    return '共享声音失败：$error';
  }

  @override
  String get remoteInputSourceConnecting => '键鼠共享：正在连接对方';

  @override
  String get remoteInputSinkConnecting => '键鼠共享：正在准备接收控制';

  @override
  String get remoteInputEdgeActiveStop => '键鼠共享：边缘穿越已启用，点击停止';

  @override
  String get remoteInputSourceActiveStop => '键鼠共享：正在控制对方，点击停止';

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
  String get remoteInputRequiresMutualTrust => '键鼠共享需要两台设备已配对';

  @override
  String get remoteInputPeerMustTrustThisDevice => '对方还没有信任本机，请先在对方设备上信任本机';

  @override
  String get remoteInputLayoutRequired => '请先把对方屏幕拖到本机屏幕边缘';

  @override
  String get remoteInputEnabledMoveToEdge => '键鼠共享已开启，移到屏幕边缘开始控制对方';

  @override
  String remoteInputFailed(String error) {
    return '键鼠共享失败：$error';
  }

  @override
  String get remoteInputWorkspaceStop => '停止';

  @override
  String get remoteInputWorkspaceNoTargets => '没有可用的桌面被控设备';

  @override
  String get remoteInputWorkspaceCanvasTitle => '屏幕排列';

  @override
  String remoteInputWorkspaceExitShortcut(String shortcut) {
    return '按 $shortcut 退出共享';
  }

  @override
  String remoteInputWorkspaceStatusActive(String peer) {
    return '正在控制 $peer';
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
  String get notificationChannelRequests => '需要你回答的请求';

  @override
  String get emptyAppsTitle => '没有可用应用';

  @override
  String get emptyAppsSearchTitle => '没有找到应用';

  @override
  String get fileDropRejected => '无法发送这些文件';

  @override
  String get validationNicknameRequired => '请输入昵称';

  @override
  String get validationNicknameTooLong => '昵称不能超过 64 个字符';

  @override
  String get settingsSectionPermissionsSharing => '权限与共享';

  @override
  String get settingsSectionPermissionsSharingDesc => '剪贴板、信任、音频和键鼠权限';

  @override
  String currentVersion(String version) {
    return '当前版本 $version';
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
    return '当前版本 $currentVersion，可更新到 $latestVersion。';
  }

  @override
  String get downloadAndInstallUpdate => '更新';

  @override
  String get viewRelease => '查看更新说明';

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
  String get appListClearSearch => '清除应用搜索';

  @override
  String get settingsLoadFailedTitle => '无法加载设置';

  @override
  String get appListLoadFailedTitle => '无法加载应用';

  @override
  String get appListSaveFailed => '无法保存通知应用选择';

  @override
  String get notificationApps => '通知应用';

  @override
  String get notificationForwardingUpdateFailed => '无法更新通知转发，请重试';

  @override
  String get dangerousActions => '危险操作';

  @override
  String get pairingNewDeviceTitle => '配对新设备';

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
  String get qrMyCode => '我的二维码';

  @override
  String get qrWifiUnavailable => '未检测到可用的局域网地址，请先连接 Wi-Fi 再刷新二维码';

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
  String get castRequestTitle => '允许该设备投屏吗？';

  @override
  String castRequestMessage(String address) {
    return '来自 $address 的设备希望在本机播放视频。';
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
  String get mobileControlSettings => '指针设置';

  @override
  String get mobileControlCalibrationRetry => '请保持手机静止，再试一次校准。';

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
  String get mobileControlPointerSpeed => '触控板移动速度';

  @override
  String get mobileControlScrollSpeed => '滚轮滑动速度';

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
  String get folderSkipWriteFailed => '无法保存到本机';

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
  String get windowStreamConnecting => '正在连接…';

  @override
  String get windowStreamPaused => '已暂停，点按继续';

  @override
  String get windowStreamReconnecting => '正在重新连接…';

  @override
  String get windowStreamDisplaced => '已回到手机上，点按收回';

  @override
  String get windowStreamSecureBlocked => '此应用不允许投屏';

  @override
  String get windowStreamAppExited => '应用已退出';

  @override
  String get windowStreamDisconnected => '连接已断开';

  @override
  String get windowStreamUnauthorized => '请在手机上允许本机调试';

  @override
  String get windowStreamDeviceOffline => '无法连接手机，请重新插拔数据线或重新打开无线调试';

  @override
  String get windowStreamAdbMissing =>
      '这台电脑没有 adb，也可以不装：在手机 Whisper 里打开“设置 → 窗口流转服务”，再连接本机';

  @override
  String get windowStreamAdbFailed => 'adb 服务启动失败';

  @override
  String get windowStreamUnsupported => '本机暂不支持打开手机应用窗口';

  @override
  String get windowStreamSearchApps => '搜索应用';

  @override
  String get windowStreamShowSystemApps => '显示系统应用';

  @override
  String get windowStreamRetry => '重试';

  @override
  String get windowStreamInjectDenied => '小米手机还要在开发者选项里打开“USB 调试（安全设置）”，然后重启手机';

  @override
  String get windowStreamAndroidTooOld => '需要 Android 10 或更新的系统';

  @override
  String get windowStreamOpenFailed => '无法打开此应用';

  @override
  String get windowStreamNoApps => '未读取到应用';

  @override
  String get windowStreamSpaceTitle => '流转';

  @override
  String get windowStreamPause => '暂停';

  @override
  String get windowStreamResume => '继续';

  @override
  String get windowStreamClose => '关闭';

  @override
  String get windowStreamNoDevices => '没有可用设备';

  @override
  String get windowStreamNoDevicesHintDesktop =>
      '在手机 Whisper 里打开“设置 → 窗口流转服务”，再连接本机；也可以用数据线连接手机。';

  @override
  String get windowStreamNoDevicesHintMobile =>
      '在 Mac 上打开 Whisper 并完成配对后，Mac 的窗口会显示在这里。';

  @override
  String get windowStreamLoadFailed => '无法读取该设备的应用';

  @override
  String get windowStreamBackToSpace => '返回流转';

  @override
  String get windowStreamKeyboard => '键盘';

  @override
  String get windowStreamSourceLocked => '该电脑已锁屏，解锁后才能流转窗口';

  @override
  String get windowStreamCapturePermission =>
      '该电脑未允许 Whisper 录屏，请在“系统设置 › 隐私与安全性 › 录屏”中开启';

  @override
  String get windowStreamUntrusted => '该手机的 Whisper 尚未与本机配对，请在手机上连接本机并确认配对';

  @override
  String get windowStreamWhisperMissing => '该手机上没有可用的 Whisper，请安装最新版并与本机配对';

  @override
  String get windowStreamNotPaired => '未配对';

  @override
  String windowStreamSendTo(String device) {
    return '发送到 $device';
  }

  @override
  String windowStreamSent(String device) {
    return '已发送到 $device';
  }

  @override
  String get windowStreamSendFailed => '发送失败，请确认该设备已连接本机';

  @override
  String windowStreamSendUnavailable(String device) {
    return '$device 上的 Whisper 需要连接本机并更新到最新版，才能接收窗口';
  }

  @override
  String get windowStreamNoLocalWindows => '本机没有可以送出去的窗口';

  @override
  String windowStreamOfferTitle(String device) {
    return '$device 发来一个窗口';
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
  String get remoteFilesThisDevice => '本机';

  @override
  String remoteFilesOffline(String device) {
    return '$device 未连接本机';
  }

  @override
  String remoteFilesUnsupported(String device) {
    return '$device 上的 Whisper 需要更新到最新版才能浏览文件';
  }

  @override
  String get remoteFilesEmptyFolder => '空文件夹';

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
    return '要永久删除这 $count 项吗？该设备没有废纸篓，删除后无法恢复。';
  }

  @override
  String get remoteFilesFailed => '操作失败';

  @override
  String get remoteFilesNameExists => '已存在同名项目';

  @override
  String get remoteFilesShowHidden => '显示隐藏文件';

  @override
  String remoteFilesSelected(int count) {
    return '已选 $count 项';
  }

  @override
  String get remoteFilesCreate => '新建';

  @override
  String get remoteFilesDone => '完成';

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
    return '$device 请求访问你的文件';
  }

  @override
  String get remoteFilesDeny => '拒绝';

  @override
  String get remoteFilesAllowOnce => '允许';

  @override
  String windowStreamTouchBlockedTitle(String device) {
    return '$device 无法操作';
  }

  @override
  String windowStreamTouchBlockedBody(String app) {
    return '$app 留在后台的页面挡住了手机屏幕，手机收不到触摸。关闭该页面即可恢复，不会卸载 $app，账号和记录不受影响。';
  }

  @override
  String get windowStreamTouchBlockedFix => '关闭该页面';

  @override
  String get windowStreamTouchBlockedLater => '稍后';

  @override
  String get windowStreamTouchBlockedFixed => '手机已恢复操作';

  @override
  String get remoteFilesWaitingDetail => '正在等待对方允许';

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
  String get remoteFilesOpen => '打开';

  @override
  String get remoteFilesCopy => '复制';

  @override
  String remoteFilesPaste(int count) {
    return '粘贴 $count 项';
  }

  @override
  String get remoteFilesRefresh => '刷新';

  @override
  String get remoteFilesSameDevice => '已在该设备上';

  @override
  String get remoteFilesBetweenOthers => '只能在本机和另一台设备之间复制';

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
  String get remoteFilesCopyToMenu => '复制到…';

  @override
  String get remoteFilesCopyHere => '复制到这里';

  @override
  String get remoteFilesChooseDestination => '选择位置后点“复制到这里”';

  @override
  String remoteFilesToday(String time) {
    return '今天 $time';
  }

  @override
  String remoteFilesYesterday(String time) {
    return '昨天 $time';
  }

  @override
  String get remoteFilesCopyToSubmenu => '复制到';

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
  String get windowStreamTextSize => '文字大小';

  @override
  String get macPermissionAccessibility => '辅助功能';

  @override
  String get macPermissionScreenRecording => '屏幕与系统录音';

  @override
  String get macPermissionAudioCapture => '仅系统录音';

  @override
  String get macPermissionGranted => '已允许';

  @override
  String get macPermissionDenied => '未允许';

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
  String get windowStreamStreaming => '流转中';

  @override
  String get windowStreamCloseWindow => '关闭窗口';

  @override
  String get windowStreamCloseFailed => '无法关闭此窗口';

  @override
  String get windowStreamOfferIgnore => '忽略';

  @override
  String get deviceDetailsTitle => '设备详情';

  @override
  String get deviceFeaturesSection => '功能';

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
    return '复制到 $device 的“$folder”';
  }

  @override
  String get remoteFilesFinder => '访达';

  @override
  String get remoteFilesExplorer => '文件资源管理器';

  @override
  String get remoteFilesFileManager => '文件管理器';

  @override
  String remoteFilesMountTooOld(String device, String app) {
    return '$device 上的 Whisper 需要更新，才能在$app中打开文件';
  }

  @override
  String remoteFilesMountDenied(String device) {
    return '$device 未允许访问文件';
  }

  @override
  String remoteFilesMountFailed(String app, String device) {
    return '$app无法打开 $device 的文件';
  }

  @override
  String remoteFilesMountNeedsFuse(String app) {
    return '要在$app中打开其他设备的文件，需要先安装 fuse3';
  }

  @override
  String remoteFilesCopyFromDevice(String device, String folder) {
    return '从 $device 复制到“$folder”';
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
  String get remoteFilesCopyFailedShort => '复制失败';

  @override
  String get remoteFilesCopyCanceledShort => '已停止';

  @override
  String get remoteFilesCopyDoneShort => '已复制';

  @override
  String get remoteFilesCopyResume => '继续';

  @override
  String get remoteFilesCopyRetry => '重试';

  @override
  String get remoteFilesCopyStop => '停止复制';

  @override
  String get remoteFilesCopyShowAll => '查看全部传输';

  @override
  String get remoteFilesCopyAlready => '这些项目正在复制到这里';

  @override
  String get remoteFilesTransfers => '传输';

  @override
  String get remoteFilesTransfersEmpty => '没有传输记录';

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
  String get remoteFilesCopyJustDone => '刚刚已复制';

  @override
  String windowStreamHostLocked(String device) {
    return '$device 已锁屏，解锁后才能流转窗口';
  }

  @override
  String windowStreamHostPermissionMac(String device) {
    return '$device 未允许 Whisper 录屏，请在该 Mac 的“系统设置 › 隐私与安全性 › 录屏与系统录音”中开启';
  }

  @override
  String windowStreamHostPermission(String device) {
    return '$device 不允许 Whisper 录制窗口，请在隐私设置中允许后重试';
  }

  @override
  String windowStreamHostHelper(String device) {
    return '请在 $device 上注销并重新登录，之后才能流转窗口';
  }

  @override
  String windowStreamHostDesktopUnsupported(String device) {
    return '$device 的桌面不支持流转窗口，需要 GNOME 或 KDE Plasma（Wayland）';
  }

  @override
  String windowStreamHostElevated(String device) {
    return '此窗口以管理员身份运行，无法流转。请在 $device 上以普通身份重新打开';
  }

  @override
  String get windowStreamHostProtected => '这个窗口不允许录屏，无法在这里显示';

  @override
  String windowStreamHostEncoder(String device) {
    return '$device 画面编码失败，请稍后重试';
  }

  @override
  String windowStreamHostEncoderLinux(String device) {
    return '$device 缺少 H.264 编码器，请安装 FFmpeg 以及 x264 或 openh264';
  }

  @override
  String windowStreamHostUnsupported(String device) {
    return '$device 暂不支持流转窗口，请更新 Whisper';
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
  String get windowStreamThatDevice => '该设备';

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
    return '$count 个窗口正在该设备上显示';
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
  String shareLinkDefaultName(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个项目',
    );
    return '$_temp0';
  }

  @override
  String get shareLinkRoute => '链接后缀';

  @override
  String get shareLinkPassword => '密码';

  @override
  String get shareLinkRouteTaken => '此后缀已被其他链接使用';

  @override
  String get shareLinkRouteInvalid => '后缀需 2–32 个字符，只能使用小写字母、数字、- 和 _';

  @override
  String get shareLinkRouteReserved => '此后缀不可用，请更换';

  @override
  String get shareLinkItemsMissing => '要共享的文件已经不在了';

  @override
  String get shareLinkCreateFailed => '创建链接失败';

  @override
  String get shareLinkCopy => '复制链接';

  @override
  String get shareLinkPasswordProtected => '有密码';

  @override
  String get shareLinksTitle => '共享链接';

  @override
  String get shareLinksService => '文件服务';

  @override
  String shareLinksServiceRunning(String port) {
    return '正在运行，端口 $port';
  }

  @override
  String get shareLinksServiceIdle => '没有开启的链接';

  @override
  String get shareLinksServiceOff => '已关闭，链接暂时无法打开';

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
  String get shareLinkStatusMissing => '文件已移动或删除';

  @override
  String get shareLinkStatusPartlyMissing => '部分文件已移动或删除';

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
  String get shareLinksEmpty => '没有共享链接';

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
  String shareWebItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 项',
    );
    return '$_temp0';
  }

  @override
  String get shareWebEmptyFolder => '空文件夹';

  @override
  String get shareWebNotFoundTitle => '无法打开此链接';

  @override
  String get shareWebNotFoundDetail => '链接可能已关闭或地址有误，请联系分享者确认。';

  @override
  String get shareWebMissingTitle => '文件已移动或删除';

  @override
  String get shareWebMissingDetail => '请联系分享者确认。';

  @override
  String get shareWebBack => '回到共享内容';

  @override
  String get shareWebPasswordTitle => '需要密码';

  @override
  String get shareWebPasswordDetail => '这个共享链接设置了密码。';

  @override
  String get shareWebContinue => '继续';

  @override
  String get shareWebPasswordWrong => '密码错误，请重试';

  @override
  String get shareWebTooManyTitle => '尝试次数太多';

  @override
  String get shareWebTooManyDetail => '请 1 分钟后重试。';

  @override
  String get shareWebErrorTitle => '加载失败';

  @override
  String get shareWebErrorDetail => '请稍后重试。';

  @override
  String get windowStreamDecoderMissing => '无法显示画面：本机缺少 FFmpeg 视频解码库';

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
      '将安装一个 GNOME 扩展，用于在后台运行被流转的窗口。安装后需要注销并重新登录。';

  @override
  String get gnomeHelperUpdateDesc => '窗口流转组件有新版本，更新后需要注销并重新登录。';

  @override
  String get gnomeHelperReloginDesc => '组件已安装，重新登录后生效。注销前请保存其他应用的内容。';

  @override
  String get gnomeHelperDisabledDesc => '窗口流转组件已在 GNOME 扩展中关闭，打开后其他设备才能流转本机窗口。';

  @override
  String get gnomeHelperExtensionsOffDesc =>
      'GNOME 扩展已全部关闭，打开后窗口流转组件才能运行，其他扩展也会一起打开。';

  @override
  String get gnomeHelperReadyDesc => '窗口流转组件正在运行。';

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
  String get gnomeHelperDone => '完成';

  @override
  String get gnomeHelperInstalled => '已安装。注销并重新登录后即可使用';

  @override
  String get gnomeHelperFailed => '无法安装窗口流转组件';

  @override
  String get windowStreamShareSetting => '允许查看和操作本机窗口';

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
  String shareWebPreviewTruncated(String size) {
    return '只显示了前 $size，下载后可查看全部内容。';
  }

  @override
  String get shareWebPrevious => '上一个';

  @override
  String get shareWebNext => '下一个';

  @override
  String get shareLinkAddress => '地址';

  @override
  String get androidWindowServiceTitle => '窗口流转服务';

  @override
  String get androidWindowServiceRunning => '已开启';

  @override
  String get androidWindowServiceRunningHint => '你配对过的设备现在可以查看和操作本机应用';

  @override
  String get androidWindowServiceStopped => '未运行';

  @override
  String get androidWindowServiceStoppedHint => '打开无线调试后，点下面的开启，不需要电脑';

  @override
  String get androidWindowServiceNeedsSetup => '未设置';

  @override
  String get androidWindowServiceNeedsSetupHint =>
      '开启后，配对过的设备可以查看和操作本机应用，不需要电脑';

  @override
  String get androidWindowServiceStart => '开启服务';

  @override
  String get androidWindowServiceStop => '停止服务';

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
      '点这里进入“开发者选项”，打开“无线调试”，再点“使用配对码配对设备”。别离开配对码页面：下拉通知栏，展开 Whisper 的通知，在里面填配对码';

  @override
  String get androidWindowServiceStep2Action => '打开“开发者选项”';

  @override
  String get androidWindowServiceStep3 => '输入配对码';

  @override
  String get androidWindowServiceStep3Hint => '也可以分屏后填在这里';

  @override
  String get androidWindowServicePairingCode => '配对码';

  @override
  String get androidWindowServicePair => '配对并开启';

  @override
  String get androidWindowServicePairing => '正在配对…';

  @override
  String get androidWindowServiceStarting => '正在开启…';

  @override
  String get androidWindowServiceAutoStart => '打开 Whisper 时自动开启';

  @override
  String get androidWindowServiceAutoStartHint =>
      '手机重启后服务会停止。打开这项后，Whisper 启动或有设备来查看时会自己打开无线调试、开启服务，再把无线调试关上。这需要授予 Whisper 一项系统权限，随时可以在这里关闭';

  @override
  String get androidWindowServiceStarted => '窗口流转服务已开启';

  @override
  String get androidWindowServiceStopped2 => '窗口流转服务已停止';

  @override
  String get androidWindowServiceStartFailed => '服务没有开启，请再试一次';

  @override
  String get androidWindowServicePairFailed => '配对失败，请核对配对码后重试';

  @override
  String get androidWindowServiceEntryTitle => '窗口流转服务';

  @override
  String get androidWindowServiceComputerHint =>
      '这台手机的系统低于 Android 12，不能自己开启。把它连接一次装有 adb 和 Whisper 的电脑即可';

  @override
  String windowStreamPhoneServiceOff(String device) {
    return '在 $device 上打开 Whisper，到“设置 → 窗口流转服务”里开启服务';
  }

  @override
  String remoteFilesNoAnswer(String device) {
    return '$device 没有回应';
  }

  @override
  String get remoteFilesNoAnswerDetail => '请求已过期，请确认对方在设备旁后重试。';

  @override
  String remoteFilesNotAsked(String device) {
    return '浏览 $device 的文件需要对方允许';
  }

  @override
  String get deviceFilesAllowChanges => '允许修改我的文件';

  @override
  String remoteFilesReadOnlyHost(String device) {
    return '$device 只允许读取文件';
  }

  @override
  String get islandOverlay => '后台悬浮提示';

  @override
  String get islandOverlayOn => '已开启';

  @override
  String get islandOverlayOff => '未开启';

  @override
  String get islandOverlayStop => '停止';

  @override
  String get islandOverlayOpen => '打开 Whisper';

  @override
  String islandOverlayFrom(String device) {
    return '来自 $device';
  }

  @override
  String islandOverlayTo(String device) {
    return '发送到 $device';
  }

  @override
  String get shellRowConnecting => '正在连接…';

  @override
  String get shellRowNearbyUnpaired => '在附近 · 可以配对';

  @override
  String get shellRowNearby => '在附近';

  @override
  String get shellRowOffline => '离线';

  @override
  String shellRowOfflineSince(String time) {
    return '离线 · $time';
  }

  @override
  String get shellRowSoundHere => '正在本机播放';

  @override
  String get shellRowControllingThis => '正在控制本机';

  @override
  String get shellRowPointerThere => '正在控制该设备';

  @override
  String get shellRowPlayingOurs => '正在播放本机声音';

  @override
  String shellRowWindows(int count) {
    return '$count 个窗口';
  }

  @override
  String get shellTabChat => '对话';

  @override
  String get shellTabFiles => '文件';

  @override
  String get shellTabApps => '应用';

  @override
  String get shellDeviceInfo => '设备信息';

  @override
  String get shellSearch => '搜索';

  @override
  String get shellAddDevice => '连接新设备';

  @override
  String get shellSound => '声音';

  @override
  String get shellInput => '键鼠';

  @override
  String get shellShareLinks => '共享链接';

  @override
  String get shellSettings => '设置';

  @override
  String get shellFirstDevice => '附近还没有设备';

  @override
  String get shellConnectDevice => '连接设备';

  @override
  String shellNotConnected(String device) {
    return '$device 没有连接';
  }

  @override
  String get shellConnect => '连接';

  @override
  String get shellConnecting => '正在连接…';

  @override
  String shellNearbyTitle(String device) {
    return '$device 在附近';
  }

  @override
  String shellComposerOffline(String device) {
    return '连接 $device 后可以发送';
  }

  @override
  String get shellSelfNoLan => '本机未连接局域网，其他设备无法发现';

  @override
  String get shellSelfAddress => '地址';

  @override
  String get shellSelfFingerprint => '身份指纹';

  @override
  String get shellEnterAddress => '输入地址…';

  @override
  String get shellDone => '完成';

  @override
  String get shellWindowMinimize => '最小化';

  @override
  String get shellWindowMaximize => '最大化';

  @override
  String get shellWindowRestore => '还原';

  @override
  String get shellWindowClose => '关闭';

  @override
  String get shellCardMenu => '设备卡片';

  @override
  String get shellCardConnected => '已连接';

  @override
  String shellCardCan(String device) {
    return '$device 可以';
  }

  @override
  String get shellCardTrust => '自动接受连接';

  @override
  String get shellCardBrowse => '浏览我的文件';

  @override
  String get shellCardChange => '修改我的文件';

  @override
  String get shellCardDiagnostics => '连接诊断';

  @override
  String get shellCardDisconnect => '断开连接';

  @override
  String get shellCardRemove => '删除设备';

  @override
  String get shellCardSound => '声音';

  @override
  String get shellCardInput => '键鼠';

  @override
  String get shellCardClipboard => '剪贴板';

  @override
  String get shellCardMount => '挂载';

  @override
  String get shellPhoneDevices => '设备';

  @override
  String get shellPhoneControl => '控制';

  @override
  String shellPhoneSyncClipboard(String device) {
    return '把剪贴板同步给 $device';
  }

  @override
  String get shellPhoneSearchHistory => '搜索聊天记录';

  @override
  String get shellLanDown => '局域网断开了';

  @override
  String shellComposerHint(String device) {
    return '发送给 $device';
  }

  @override
  String get shellPaletteDevice => '设备';

  @override
  String get shellPaletteAction => '动作';

  @override
  String get shellPalettePage => '页面';

  @override
  String get shellPaletteMessage => '消息';

  @override
  String shellPalettePlayOn(String device) {
    return '把本机声音播放到 $device';
  }

  @override
  String shellPaletteControl(String device) {
    return '用本机键鼠控制 $device';
  }

  @override
  String get shellSettingsGeneral => '通用';

  @override
  String get shellSettingsConnection => '连接';

  @override
  String get shellSettingsSystem => '系统';

  @override
  String get shellSettingsSharing => '共享与权限';

  @override
  String get shellSettingsNotifications => '通知';

  @override
  String get shellSettingsAbout => '关于';

  @override
  String get shellSettingsClipboardNotifications => '剪贴板和通知';

  @override
  String get shellSettingsAppearance => '外观';

  @override
  String get shellSettingsAppearanceAuto => '自动';

  @override
  String get shellSettingsAppearanceLight => '浅色';

  @override
  String get shellSettingsAppearanceDark => '深色';

  @override
  String get shellSettingsLanguage => '语言';

  @override
  String get shellSettingsSaveTo => '文件保存到';

  @override
  String get shellSettingsChange => '更改…';

  @override
  String get shellSettingsCast => '接收电视投屏';

  @override
  String get shellSettingsKeepAlive => '后台保持连接';

  @override
  String get shellSettingsScreenshotEnabled => '启用截图快捷键';

  @override
  String get shellSettingsPressShortcut => '按下快捷键…';

  @override
  String get shellSettingsClipboardSync => '同步剪贴板';

  @override
  String get shellSettingsPlaybackGain => '播放音量';

  @override
  String get shellSettingsCopyCode => '验证码写入剪贴板';

  @override
  String get shellSettingsVersion => '版本';

  @override
  String get shellSettingsVersionChecking => '正在检查…';

  @override
  String get shellSettingsQrAndAddress => '二维码和地址';

  @override
  String shellSettingsMultiplier(String value) {
    return '${value}x';
  }

  @override
  String shellSettingsVersionLatest(String version) {
    return '$version · 已是最新';
  }

  @override
  String shellSettingsVersionAvailable(String version) {
    return '有新版本 $version';
  }

  @override
  String shellSettingsVersionDownloading(int progress) {
    return '下载中 $progress%';
  }

  @override
  String shellSettingsAboutVersion(String version) {
    return '版本 $version';
  }

  @override
  String shellSettingsLinksOn(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个开启中',
    );
    return '$_temp0';
  }

  @override
  String get soundSelfIdle => '未播放';

  @override
  String get soundSelfSilent => '这台没有声音在放';

  @override
  String soundSelfPlaying(int count) {
    return '正在播放到 $count 台设备';
  }

  @override
  String get soundShareThisDevice => '共享本机声音';

  @override
  String get soundMemberStopped => '已停止';

  @override
  String soundMemberFailed(String reason) {
    return '播放失败 · $reason';
  }

  @override
  String get soundMemberBusy => '正在播放其他来源';

  @override
  String get soundMemberSoloOnly => '只能单独播放';

  @override
  String get soundPermissionNeeded => '需要允许屏幕与系统录音';

  @override
  String soundCheckLabel(String device) {
    return '把声音播放到 $device';
  }

  @override
  String soundChannelLabel(String device, String channel) {
    return '$device 的声道：$channel';
  }

  @override
  String get soundNoDevices => '没有已连接的设备';

  @override
  String get soundSinkPaused => '已暂停';

  @override
  String get soundSinkWaiting => '没有收到声音';

  @override
  String get soundSinkResuming => '正在恢复…';

  @override
  String get soundGain => '增益';

  @override
  String soundGainValue(String value) {
    return '${value}x';
  }

  @override
  String get soundResume => '继续';

  @override
  String get shareOpenSettings => '去开启';

  @override
  String inputHintExit(String shortcut) {
    return '按 $shortcut 收回键鼠';
  }

  @override
  String get inputStatusWaiting => '等待确认';

  @override
  String get inputStatusNotConnected => '无法控制';

  @override
  String get inputSideRight => '右侧';

  @override
  String get inputSideLeft => '左侧';

  @override
  String get inputSideAbove => '上方';

  @override
  String get inputSideBelow => '下方';

  @override
  String get inputSideElsewhere => '接在其他屏幕旁';

  @override
  String inputScreenCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 块屏幕',
      two: '两块屏幕',
    );
    return '$_temp0';
  }

  @override
  String inputResolution(int width, int height) {
    return '$width×$height';
  }

  @override
  String inputDetail(String resolution, String place) {
    return '$resolution · $place';
  }

  @override
  String get inputRemove => '移出';

  @override
  String get inputReasonPeerNotTrusting => '对方未信任本机';

  @override
  String get inputReasonNotTrusted => '本机未信任对方';

  @override
  String get inputReasonUnsupported => '对方版本不支持';

  @override
  String get inputReasonPeerPermission => '对方未允许被控制';

  @override
  String get inputReasonBusy => '对方暂时无法被控制';

  @override
  String get inputReasonBlocked => '中间的屏幕未连接';

  @override
  String get inputCandidateUnsupported => '不支持';

  @override
  String get inputPermissionNeeded => '需要允许辅助功能';

  @override
  String inputControlledTitle(String device) {
    return '$device 正在控制本机';
  }

  @override
  String get inputSwitchLabel => '键鼠共享';

  @override
  String inputScreenLabel(String device, String detail) {
    return '$device 的屏幕，$detail';
  }

  @override
  String inputAddLabel(String device) {
    return '把 $device 加入键鼠共享';
  }

  @override
  String get shellIslandFinished => '已完成';

  @override
  String get shellPaletteEmpty => '没有找到';

  @override
  String get shellLinksServiceOff => '文件服务已关闭';

  @override
  String get shellLinksServiceIdle => '没有开启的链接';

  @override
  String get shellLinksEmptyTitle => '没有链接';

  @override
  String get shellLinksEmptyBody => '选择文件或文件夹生成链接，对方用浏览器打开即可下载。';

  @override
  String get shellLinksChoose => '选择文件';

  @override
  String get shellLinksNew => '新建';

  @override
  String get shellLinkOff => '已关闭';

  @override
  String get shellLinkMissing => '部分文件已移动或删除';

  @override
  String shellLinkVisits(int count) {
    return '$count 次访问';
  }

  @override
  String shellLinkDownloads(int count) {
    return '$count 次下载';
  }

  @override
  String shellLinkVisitsCount(int count) {
    return '$count 次';
  }

  @override
  String get shellLinkEnabled => '开启';

  @override
  String get shellLinkPassword => '密码';

  @override
  String get shellLinkPasswordSet => '已设置';

  @override
  String get shellLinkPasswordNone => '没有';

  @override
  String get shellLinkVisitsLabel => '访问';

  @override
  String get shellLinkDownloadsLabel => '下载';

  @override
  String get shellLinkDeleted => '链接已删除';

  @override
  String get shellMore => '更多';

  @override
  String shellFilesCount(int count) {
    return '$count 项';
  }

  @override
  String get shellFilesSendTo => '发送到…';

  @override
  String get shellFilesCopyHere => '复制到本机';

  @override
  String shellFilesAskOnDevice(String device) {
    return '请在 $device 上允许';
  }

  @override
  String shellFilesDenied(String device) {
    return '$device 拒绝了';
  }

  @override
  String get shellAppsMoving => '正在流转';

  @override
  String shellAppsRunsOn(String device) {
    return '运行于 $device，显示于本机';
  }

  @override
  String get shellAppsEnd => '结束';

  @override
  String shellAppsOn(String device) {
    return '$device 上的应用';
  }

  @override
  String shellSettingsAppsSelected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已选择 $count 个',
      zero: '尚未选择',
    );
    return '$_temp0';
  }

  @override
  String get shellTrayClipboard => '剪贴板';

  @override
  String get shellTrayClipboardEmpty => '剪贴板是空的';

  @override
  String get shellTrayScreenshot => '截图';

  @override
  String get shellTrayRecent => '最近的剪贴板';

  @override
  String get shellTrayOpen => '打开 Whisper';

  @override
  String get shellTrayNoDevice => '没有已连接的设备';

  @override
  String get shellTraySoundOff => '关';

  @override
  String shellTrayFrom(String device, String when) {
    return '$device · $when';
  }

  @override
  String get shellTrayThisDevice => '本机';

  @override
  String shellTrayPlaying(String device) {
    return '正在播放 $device 的声音';
  }

  @override
  String shellTrayControlled(String device) {
    return '$device 正在控制本机';
  }

  @override
  String get shellTrayInputOn => '已开启';

  @override
  String shellIslandPlayingOn(String devices) {
    return '正在播放到 $devices';
  }

  @override
  String shellIslandControlling(String device) {
    return '正在控制 $device';
  }

  @override
  String get shellToday => '今天';

  @override
  String get shellYesterday => '昨天';

  @override
  String get shellTraySendClipboardTo => '发送剪贴板到';

  @override
  String get shellTraySendFileTo => '发送文件到';

  @override
  String get shellTrayPlayOn => '播放到';

  @override
  String get phoneConnectCopyLink => '复制连接链接';

  @override
  String get phoneConnectCopied => '连接链接已复制';

  @override
  String get phoneConnectCopyFailed => '复制失败，请重试';

  @override
  String get phoneConnectOpenSettings => '去开启';

  @override
  String get phonePairApprove => '数字一致';

  @override
  String get pickerNoDevices => '没有其他已连接的设备';

  @override
  String pickerSendFile(String name) {
    return '把「$name」发送到';
  }

  @override
  String pickerSendItems(int count) {
    return '把 $count 项发送到';
  }

  @override
  String get pickerSendText => '把这段文字发送到';

  @override
  String phoneFilesCopied(int count) {
    return '已复制 $count 项';
  }

  @override
  String get phoneConnectPort => '端口';

  @override
  String get shellLinkPasswordOptional => '密码（可不填）';

  @override
  String shellAppsShownOn(String device) {
    return '运行于本机，显示于 $device';
  }

  @override
  String get shellAppsBringBack => '收回';

  @override
  String get shellManualConnectTitle => '输入地址连接';

  @override
  String get shellManualConnectField => '地址和端口';

  @override
  String get shellLinksChooseFolder => '选择文件夹';

  @override
  String get soundMemberStoppedThere => '对方已停止播放';

  @override
  String get soundMemberUnheard => '收不到声音';

  @override
  String soundMemberStoppedNotice(String device) {
    return '$device 停止了播放';
  }

  @override
  String get connectionCheckNetwork => '本机网络';

  @override
  String get connectionCheckAddress => '对方的地址';

  @override
  String get connectionCheckService => '对方的 Whisper';

  @override
  String get connectionCheckSession => '加密连接';

  @override
  String get connectionCheckNotConnected => '未连接';

  @override
  String get connectionCheckConnected => '连接正常。';

  @override
  String get connectionCheckOneWay => '连接正常。本机无法连接对方端口，当前连接由对方发起，断开后需从对方重新连接。';

  @override
  String get connectionCheckReady => '网络和对方的 Whisper 都正常，可以连接。';

  @override
  String get connectionCheckAgain => '重新检查';

  @override
  String soundSyncNumbers(
    String network,
    String jitter,
    String buffer,
    int late,
  ) {
    return '网络 ${network}ms · 抖动 ${jitter}ms · 缓冲 ${buffer}ms · 晚包 $late';
  }

  @override
  String get soundSyncNumbersPending => '网络 — · 抖动 — · 缓冲 — · 晚包 —';

  @override
  String shellLinkCreateTitle(String name) {
    return '共享「$name」';
  }

  @override
  String get shareLinkShortRoute => '简短后缀';

  @override
  String get shareLinkCreate => '创建链接';

  @override
  String get shareLinkShowPassword => '显示密码';

  @override
  String get shareLinkHidePassword => '隐藏密码';

  @override
  String get shareLinkSentLabel => '已发送';

  @override
  String get shellLinksChooseAny => '选择';

  @override
  String get shellSelfCopy => '拷贝连接信息';

  @override
  String get shellSelfNotes => '本机';

  @override
  String get shellSelfNotesHint => '只保存在这台设备上';

  @override
  String get shellSettingsNicknameHint => '其他设备会看到这个名字';

  @override
  String get shellSettingsPortHint => '其他设备用这个端口连接这台。退出设置后生效';

  @override
  String get shellSelfCopied => '已拷贝';

  @override
  String get shareLinkNoNetwork => '没有连上局域网，其他设备暂时打不开';

  @override
  String get screenshotShortcutReset => '恢复默认快捷键';

  @override
  String shellDropSendTitle(String name) {
    return '发送给 $name';
  }

  @override
  String shellDropSendMore(int count) {
    return '还有 $count 个';
  }

  @override
  String get shellDropSendConfirm => '发送';

  @override
  String get androidWindowServiceNotifyTitle => '窗口流转配对';

  @override
  String get androidWindowServiceNotifyEnterCode => '填入系统显示的 6 位数字';

  @override
  String get androidWindowServiceNoPairingService =>
      '没有找到配对请求，请先在无线调试里点“使用配对码配对设备”';

  @override
  String get androidWindowServiceWirelessOff => '无线调试没有打开，请连接 Wi-Fi 后打开它';

  @override
  String get androidWindowServiceNotPaired => '配对已失效，请重新配对';

  @override
  String get androidWindowServiceNeedsWifi => '无线调试需要手机连接 Wi-Fi';

  @override
  String get androidWindowServiceAutoStartFailed =>
      '没能打开：请先打开无线调试；小米手机还要打开“USB 调试（安全设置）”';

  @override
  String get androidWindowServiceNotifyWaitingCode => '正在等配对码';

  @override
  String get androidWindowServiceNotifyCodeHint => '6 位配对码';

  @override
  String get androidWindowServiceNotifyReply => '填写';

  @override
  String get shellFirstDeviceHint => '在另一台设备上打开 Whisper，连上同一个网络，它就会出现在这里';

  @override
  String pasteIslandFiles(int count) {
    return '$count 个文件';
  }

  @override
  String pasteIslandFrom(String device) {
    return '从 $device 粘贴';
  }

  @override
  String pasteIslandSecondsLeft(int seconds) {
    return '还剩 $seconds 秒';
  }

  @override
  String pasteIslandMinutesLeft(int minutes) {
    return '还剩 $minutes 分钟';
  }

  @override
  String get pasteIslandPasted => '已粘贴';

  @override
  String pasteIslandReady(String shortcut) {
    return '已就绪，按 $shortcut 粘贴';
  }

  @override
  String get pasteIslandFailed => '没能粘贴';

  @override
  String get pasteIslandCanceled => '已取消';
}
