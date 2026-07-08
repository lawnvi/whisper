// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get connectDeviceTitle => 'Connect Device';

  @override
  String get connectDeviceDesc => 'Enter IP and Port';

  @override
  String get connectTo => 'Connect To';

  @override
  String get connectRequest => 'Connection Request';

  @override
  String connectRequestDesc(String device) {
    return 'New device: $device?';
  }

  @override
  String connectRequestNotificationBody(String name, String host) {
    return '$name ($host) wants to connect';
  }

  @override
  String get connectRequestExpired => 'Connection request expired';

  @override
  String transferNotificationTitle(int count) {
    return 'Transferring $count files';
  }

  @override
  String transferNotificationBodySending(
      int percent, String speed, String remaining) {
    return 'Sending $percent% · $speed · $remaining left';
  }

  @override
  String transferNotificationBodyReceiving(
      int percent, String speed, String remaining) {
    return 'Receiving $percent% · $speed · $remaining left';
  }

  @override
  String transferNotificationBodyMixed(
      int percent, String speed, String remaining) {
    return 'Syncing $percent% · $speed · $remaining left';
  }

  @override
  String transferNotificationCompleted(int count) {
    return 'Transfer complete · $count files';
  }

  @override
  String get transferNotificationInterrupted =>
      'Transfer interrupted, reopen the app to resume';

  @override
  String get connect => 'Connect';

  @override
  String get confirm => 'Confirm';

  @override
  String get allow => 'Allow';

  @override
  String get refuse => 'Refuse';

  @override
  String get cancel => 'Cancel';

  @override
  String get retry => 'Retry';

  @override
  String get setting => 'Settings';

  @override
  String get sendTips => 'Type something...';

  @override
  String get trust => 'Trust Device';

  @override
  String get writeClipboard => 'Write to Clipboard';

  @override
  String get deleteDevice => 'Delete Device';

  @override
  String serverPort(Object port) {
    return 'Server Port $port';
  }

  @override
  String get serverPortTitle => 'Server Port';

  @override
  String get trustNewDevice => 'Auto-Approve New Device';

  @override
  String get accessClipboard => 'Access Clipboard';

  @override
  String get doubleClickRmMessage => 'Delete Message on Double Click';

  @override
  String get close2tray => 'Hide to Tray When Closing';

  @override
  String get nickname => 'Nickname';

  @override
  String get nicknameDesc => 'Enter your nickname';

  @override
  String get port => 'Port';

  @override
  String get portDesc => 'Port range: [1000, 65535]';

  @override
  String get timeoutTitle => 'Connection Timeout';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get keepConnect => 'Keep';

  @override
  String get menuShow => 'Show';

  @override
  String get menuHide => 'Hide';

  @override
  String get menuClipboard => 'Send Clipboard';

  @override
  String get menuSendFile => 'Send Files';

  @override
  String get filePickerOpenFailed => 'Unable to open the file picker';

  @override
  String get clipboardImageSendFailed => 'Unable to send clipboard image';

  @override
  String get clipboardFilesSendFailed => 'Unable to send clipboard files';

  @override
  String clipboardFilesCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
    );
    return '$_temp0';
  }

  @override
  String get exit => 'Exit';

  @override
  String get delete => 'Delete';

  @override
  String get deleteConfirm => 'Confirm Delete';

  @override
  String get warning => 'Warning';

  @override
  String get deleteWarningText =>
      'The connection is still active, so quick delete is blocked';

  @override
  String get close => 'Close';

  @override
  String deleteDeviceTitle(String device) {
    return 'Delete $device';
  }

  @override
  String get deleteDeviceDesc =>
      'Clear all messages for this device. This cannot be undone.';

  @override
  String get brokeConnectTitle => 'Disconnect';

  @override
  String brokeConnectDesc(String device) {
    return 'Disconnect $device';
  }

  @override
  String get connectFailed => 'Connection Failed';

  @override
  String get deviceBusy => 'Device Busy';

  @override
  String get startServerFailed => 'Failed to Start Server';

  @override
  String get deleteMessageTitle => 'Delete Message';

  @override
  String get deleteMessageDesc => 'Are you sure you want to delete it?';

  @override
  String language(Object language) {
    return 'Language $language';
  }

  @override
  String get pushNotification => 'Forward Android Notifications';

  @override
  String get ignoreNotification => 'Ignore Android Notifications';

  @override
  String get ftpService => 'FTP Service';

  @override
  String get back => 'Back';

  @override
  String get selectAll => 'Select All';

  @override
  String get clearAll => 'Clear';

  @override
  String get selectNotifyApp => 'Listen to App Notifications';

  @override
  String get copyVerifyCode => 'Copy Verification Code to Clipboard';

  @override
  String get open => 'Open';

  @override
  String get openInFinder => 'Open in Finder';

  @override
  String get openInDir => 'Open Directory';

  @override
  String get keepFile => 'Keep File';

  @override
  String get deleteFile => 'Delete File';

  @override
  String get copyMessage => 'Copy Message Content';

  @override
  String get themeMode => 'Theme Mode';

  @override
  String get followSystem => 'Follow System';

  @override
  String get lightMode => 'Light';

  @override
  String get darkMode => 'Dark Mode';

  @override
  String get selectThemeMode => 'Select Theme Mode';

  @override
  String get selectLanguage => 'Select Language';

  @override
  String get searchChats => 'Search';

  @override
  String get selectConversationPlaceholder =>
      'Select a device to start chatting';

  @override
  String get connectedNow => 'Connected now';

  @override
  String get nearbyAvailable => 'Available nearby';

  @override
  String get noMessagesYet => 'No messages yet';

  @override
  String get sharedFile => 'Shared a file';

  @override
  String get connectToSend => 'Connect to send messages';

  @override
  String get localeNameZhHans => 'Simplified Chinese';

  @override
  String get localeNameEnglish => 'English';

  @override
  String get localeNameSpanish => 'Spanish';

  @override
  String get autoConnectTrustedDevices =>
      'Auto-connect mutually trusted devices';

  @override
  String get mutualTrustEnabled => 'Mutual trust is enabled';

  @override
  String get mutualTrustNotEstablished =>
      'Mutual trust has not been established';

  @override
  String get launchAtStartup => 'Launch at startup';

  @override
  String get launchAtStartupDesc =>
      'Start Whisper automatically after desktop login to reconnect trusted devices';

  @override
  String launchAtStartupFailed(String error) {
    return 'Failed to update launch at startup: $error';
  }

  @override
  String get androidBackgroundKeepAlive =>
      'Keep connection alive in background';

  @override
  String get androidBackgroundKeepAliveDesc =>
      'Use an Android foreground service during active sessions to reduce disconnects when picking files or switching apps';

  @override
  String get androidBackgroundKeepAliveActiveTitle =>
      'Whisper is keeping the connection alive';

  @override
  String get androidBackgroundKeepAliveActiveDesc =>
      'Active while a device session is connected';

  @override
  String get androidBatteryOptimization => 'Battery optimization';

  @override
  String get androidBatteryOptimizationDesc =>
      'Recommended: allow background activity and exclude Whisper from battery optimization on Android';

  @override
  String get fileTransferQueued => 'Queued';

  @override
  String fileTransferPreparingResume(String progress) {
    return 'Preparing resume $progress%';
  }

  @override
  String get fileTransferNegotiating => 'Negotiating';

  @override
  String fileTransferWaitingReconnect(String progress) {
    return 'Waiting to reconnect $progress%';
  }

  @override
  String get fileTransferPaused => 'Paused';

  @override
  String get fileTransferVerifying => 'Verifying';

  @override
  String get fileTransferFailedRetryable => 'Failed, retry available';

  @override
  String get fileTransferCanceled => 'Canceled';

  @override
  String get audioShareCaptureConnecting =>
      'Capture side: connecting to remote speaker';

  @override
  String get audioSharePlaybackPreparing =>
      'Playback side: preparing shared audio';

  @override
  String get audioShareCaptureActiveStop =>
      'Capture side: sharing this device\'s audio, click to stop';

  @override
  String get audioSharePlaybackActiveStop =>
      'Playback side: playing shared audio, click to stop';

  @override
  String get audioShareStart => 'Share this device\'s audio to peer';

  @override
  String get audioSharePlaybackStopped => 'Stopped playing shared audio';

  @override
  String get audioShareCaptureStopped => 'Stopped sharing audio';

  @override
  String get audioSharePlaybackGainTitle => 'Shared speaker gain';

  @override
  String audioSharePlaybackGainSetting(String gain) {
    return 'Shared speaker gain: $gain';
  }

  @override
  String get audioSharePlaybackGainDesc =>
      'Only affects shared audio played on this device. Higher values may clip';

  @override
  String get remoteInputScrollMultiplierTitle =>
      'Keyboard and mouse scroll speed';

  @override
  String remoteInputScrollMultiplierSetting(String multiplier) {
    return 'Keyboard and mouse scroll speed: $multiplier';
  }

  @override
  String get remoteInputScrollMultiplierDesc =>
      'Only affects remote wheel events received while this device is being controlled';

  @override
  String get audioShareUnsupportedCapture =>
      'This device does not support system audio capture';

  @override
  String get audioShareRequestingPlayback =>
      'Requesting peer to play this device\'s audio';

  @override
  String get audioGroupShareStart => 'Sync to multiple speakers';

  @override
  String get audioGroupAdjust => 'Adjust audio sharing';

  @override
  String get audioGroupSelectSinks => 'Select playback devices';

  @override
  String get audioGroupStart => 'Start synced playback';

  @override
  String get audioGroupApply => 'Apply configuration';

  @override
  String get audioGroupStop => 'Stop sharing';

  @override
  String get audioGroupRoleStereo => 'Stereo';

  @override
  String get audioGroupRoleLeft => 'Left channel';

  @override
  String get audioGroupRoleRight => 'Right channel';

  @override
  String get audioGroupRoleMono => 'Mono';

  @override
  String get audioGroupRequestingPlayback =>
      'Requesting synced playback on selected devices';

  @override
  String get audioGroupSelectAtLeastOne =>
      'Select at least one playback device';

  @override
  String get audioGroupSyncCalibrating => 'Estimating sync';

  @override
  String get audioGroupSyncGood => 'Sync good';

  @override
  String get audioGroupSyncFair => 'Sync fair';

  @override
  String get audioGroupSyncUnstable => 'Sync unstable';

  @override
  String get audioGroupDeviceIdle => 'Idle';

  @override
  String get audioGroupLatencyShortLabel => 'network ';

  @override
  String get audioGroupJitterShortLabel => 'jitter ';

  @override
  String get audioGroupBufferShortLabel => 'buffer ';

  @override
  String get audioGroupRecentLatePacketShortLabel => 'late ';

  @override
  String get audioGroupClockOffsetLabel => 'clock offset';

  @override
  String audioGroupSyncEvidence(
      Object quality,
      Object clockOffsetLabel,
      Object offset,
      Object rtt,
      Object jitter,
      Object buffer,
      Object latePackets) {
    return '$quality · $clockOffsetLabel ${offset}ms · RTT ${rtt}ms · jitter ${jitter}ms · buffer ${buffer}ms · late $latePackets';
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
    return 'Audio sharing failed: $error';
  }

  @override
  String get remoteInputSourceConnecting =>
      'Keyboard and mouse sharing: connecting to peer';

  @override
  String get remoteInputSinkConnecting =>
      'Keyboard and mouse sharing: preparing to receive control';

  @override
  String get remoteInputEdgeActiveStop =>
      'Keyboard and mouse sharing: edge crossing is enabled, click to stop';

  @override
  String get remoteInputSourceActiveStop =>
      'Keyboard and mouse sharing: controlling peer, click to stop';

  @override
  String get remoteInputSinkActiveStop =>
      'Keyboard and mouse sharing: receiving control, click to stop';

  @override
  String get remoteInputStart => 'Enable keyboard and mouse sharing';

  @override
  String get remoteInputStopped => 'Stopped keyboard and mouse sharing';

  @override
  String get remoteInputStopCurrentFirst =>
      'Stop the current keyboard and mouse sharing session first';

  @override
  String get remoteInputLocalUnsupported =>
      'This device does not support keyboard and mouse sharing';

  @override
  String get remoteInputPeerUnsupported =>
      'Connected device does not support keyboard and mouse sharing';

  @override
  String get remoteInputRequiresMutualTrust =>
      'Keyboard and mouse sharing requires mutual trust';

  @override
  String get remoteInputPeerMustTrustThisDevice =>
      'The peer has not trusted this device yet. Trust this device on the peer before sharing keyboard and mouse';

  @override
  String get remoteInputLayoutRequired =>
      'Place the peer screen against this device\'s edge in device settings first';

  @override
  String get remoteInputEnabledMoveToEdge =>
      'Keyboard and mouse sharing is enabled. Move to the screen edge to control peer';

  @override
  String remoteInputFailed(String error) {
    return 'Keyboard and mouse sharing failed: $error';
  }

  @override
  String remoteInputAutoModeSetting(String mode) {
    return 'Keyboard and mouse sharing: $mode';
  }

  @override
  String remoteInputLayoutSetting(String edge) {
    return 'Screen layout: $edge';
  }

  @override
  String get remoteInputAutoModeTitle => 'Keyboard and mouse sharing';

  @override
  String get remoteInputAutoModeOff => 'Off';

  @override
  String get remoteInputAutoModeSource => 'This device controls peer';

  @override
  String get remoteInputAutoModeSink => 'Peer controls this device';

  @override
  String get remoteInputLayoutTitle => 'Screen layout';

  @override
  String remoteInputCurrentEdge(String edge) {
    return 'Current: $edge';
  }

  @override
  String get remoteInputLayoutSave => 'Save';

  @override
  String get remoteInputSnapLeft => 'Snap left';

  @override
  String get remoteInputSnapRight => 'Snap right';

  @override
  String get remoteInputSnapTop => 'Snap top';

  @override
  String get remoteInputSnapBottom => 'Snap bottom';

  @override
  String get remoteInputLocalScreen => 'This device';

  @override
  String get remoteInputPeerScreen => 'Peer';

  @override
  String get remoteInputEdgeLeft => 'Left';

  @override
  String get remoteInputEdgeRight => 'Right';

  @override
  String get remoteInputEdgeTop => 'Top';

  @override
  String get remoteInputEdgeBottom => 'Bottom';

  @override
  String get remoteInputEdgeNotAdjacent => 'Not adjacent';

  @override
  String get remoteInputWorkspaceTitle => 'Keyboard and mouse workspace';

  @override
  String get remoteInputWorkspaceTooltip => 'Keyboard and mouse workspace';

  @override
  String get remoteInputWorkspaceStart => 'Start';

  @override
  String get remoteInputWorkspaceStop => 'Stop';

  @override
  String get remoteInputWorkspaceNoTargets =>
      'No available desktop control targets';

  @override
  String get remoteInputWorkspaceSelectTargets => 'Control targets';

  @override
  String get remoteInputWorkspaceCanvasTitle => 'Screen arrangement';

  @override
  String get remoteInputWorkspaceDetailsTitle => 'Device details';

  @override
  String get remoteInputWorkspaceFocusTarget => 'Inspect device';

  @override
  String get remoteInputWorkspaceAddTarget => 'Add to workspace';

  @override
  String get remoteInputWorkspaceRemoveTarget => 'Remove from workspace';

  @override
  String get remoteInputWorkspaceState => 'State';

  @override
  String get remoteInputWorkspaceConflict => 'Edge overlap';

  @override
  String get remoteInputWorkspaceTargetIdle => 'Not enabled';

  @override
  String get remoteInputWorkspaceStatusIdle =>
      'Keyboard and mouse workspace is off';

  @override
  String get remoteInputWorkspaceStatusOffering =>
      'Waiting for targets to accept';

  @override
  String get remoteInputWorkspaceStatusArmed =>
      'Move to a screen edge to control a target';

  @override
  String remoteInputWorkspaceStatusActive(String peer) {
    return 'Controlling $peer';
  }

  @override
  String remoteInputWorkspaceStatusFailed(String error) {
    return 'Keyboard and mouse workspace failed: $error';
  }

  @override
  String get audioPlaybackNotificationSubtitle => 'Playing system audio';

  @override
  String get mediaActionPause => 'Pause';

  @override
  String get mediaActionPlay => 'Play';

  @override
  String get mediaActionDisconnect => 'Disconnect';

  @override
  String get notificationChannelKeepAlive => 'Background keep-alive';

  @override
  String get notificationChannelKeepAliveDesc =>
      'Keeps Whisper connected while it runs in the background';

  @override
  String get notificationChannelMedia => 'Media playback';

  @override
  String get notificationChannelTransfer => 'File transfer';

  @override
  String get notificationChannelTransferDesc => 'File transfer progress';

  @override
  String get notificationChannelGeneral => 'Messages';

  @override
  String get notificationChannelGeneralDesc => 'Incoming messages and alerts';
}
