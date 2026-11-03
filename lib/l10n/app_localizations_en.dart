// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get mobileControlSpace => 'Space';

  @override
  String get mobileControlEnter => 'Return';

  @override
  String get mobileControlSymbols => 'Numbers and symbols';

  @override
  String get mobileControlMoreSymbols => 'More symbols';

  @override
  String get mobileControlDirectKeys => 'Direct keys';

  @override
  String get mobileControlReturnKeys => 'Return to direct keys';

  @override
  String get mobileControlDraftHint => 'Chinese, emoji or a short message…';

  @override
  String get mobileControlScrollShort => 'Scroll';

  @override
  String get mobileControlLeftShort => 'Left';

  @override
  String get mobileControlRightShort => 'Right';

  @override
  String get mobileControlPermission =>
      'Allow Whisper in System Settings → Privacy & Security → Accessibility on the Mac, then start again.';

  @override
  String get mobileControlTitle => 'Control computer';

  @override
  String get mobileControlStart => 'Start control';

  @override
  String get mobileControlStop => 'Stop control';

  @override
  String get mobileControlReady => 'Ready';

  @override
  String get mobileControlActive => 'Controlling';

  @override
  String get remoteInputPeerControlling => 'Controlling this device';

  @override
  String get remoteInputPeerReceiving => 'Controlling this computer';

  @override
  String get remoteInputPeerReady => 'Ready, waiting for entry';

  @override
  String get mobileControlPreparing => 'Preparing control';

  @override
  String get mobileControlAir => 'Air mouse';

  @override
  String get mobileControlTouchpad => 'Touchpad';

  @override
  String get mobileControlTouchHint =>
      'One finger to move · Tap to click\nTwo fingers: tap to right-click, slide to scroll';

  @override
  String get mobileControlHoldScroll => 'Hold and tilt to scroll';

  @override
  String get mobileControlScroll => 'Swipe to scroll';

  @override
  String get mobileControlLeft => 'Left click';

  @override
  String get mobileControlRight => 'Right click';

  @override
  String get mobileControlText => 'Text input';

  @override
  String get mobileControlMainKeys => 'Main keys';

  @override
  String get mobileControlFunctionKeys => 'Function and navigation keys';

  @override
  String get mobileControlSendText => 'Send text';

  @override
  String get mobileControlTextHint =>
      'Select a text field on the computer, then write and send.';

  @override
  String get mobileControlTextTooLong => 'Send up to 4 KiB of text at a time.';

  @override
  String get mobileControlTextUnconfirmed =>
      'Input was not confirmed. Draft kept; check the computer before resending.';

  @override
  String get mobileControlTextSent =>
      'Text delivered to the system. Check the target app.';

  @override
  String get mobileControlSensitivity => 'Motion pointer speed';

  @override
  String get mobileControlCalibrate => 'Calibrate';

  @override
  String get mobileControlCalibrating => 'Hold the phone still briefly…';

  @override
  String get mobileControlCalibrationDone => 'Calibration complete';

  @override
  String mobileControlReceiving(String name) {
    return 'This computer is controlled by $name';
  }

  @override
  String get mobileControlShortcutHint =>
      'Select modifiers, then a key. Modifiers clear after each combination.';

  @override
  String get screenshotCapture => 'Capture region';

  @override
  String screenshotButtonTooltip(String shortcut) {
    return 'Screenshot ($shortcut)';
  }

  @override
  String get screenshotButtonTooltipPlain => 'Screenshot';

  @override
  String get screenshotSelectionHint =>
      'Click a window · Drag a region · Esc to cancel';

  @override
  String get screenshotAdjustHint =>
      'Drag to move · Drag edges to resize · Enter to copy · Esc to cancel';

  @override
  String get screenshotConfirm => 'Copy';

  @override
  String get screenshotCopied =>
      'Screenshot copied. Paste it wherever you need.';

  @override
  String get screenshotPermissionDenied =>
      'Allow Whisper to record the screen in System Settings → Privacy & Security, then restart Whisper.';

  @override
  String get screenshotUnavailable =>
      'Region capture is unavailable. On Linux, check that your desktop screenshot portal is installed and running.';

  @override
  String get screenshotFailed =>
      'Screenshot or clipboard copy failed. Please try again.';

  @override
  String get screenshotShortcutTitle => 'Screenshot shortcut';

  @override
  String get screenshotShortcutUnavailable =>
      'Shortcut not registered · click to configure';

  @override
  String get screenshotShortcutInvalid =>
      'Use a valid key combination different from the quick-send shortcut.';

  @override
  String get screenshotShortcutFailed =>
      'Could not save the shortcut. It may be in use, cancelled, or unsupported by the desktop. Try another combination.';

  @override
  String get connectDeviceTitle => 'Connect Device';

  @override
  String get connectRequest => 'Connection Request';

  @override
  String transferNotificationTitle(int count) {
    return 'Transferring $count files';
  }

  @override
  String transferNotificationBodySending(
    int percent,
    String speed,
    String remaining,
  ) {
    return 'Sending $percent% · $speed · $remaining left';
  }

  @override
  String transferNotificationBodyReceiving(
    int percent,
    String speed,
    String remaining,
  ) {
    return 'Receiving $percent% · $speed · $remaining left';
  }

  @override
  String transferNotificationBodyMixed(
    int percent,
    String speed,
    String remaining,
  ) {
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
  String get trust => 'Trust Device';

  @override
  String get writeClipboard => 'Write to Clipboard';

  @override
  String get deleteDevice => 'Delete Device';

  @override
  String get serverPortTitle => 'Server Port';

  @override
  String get clipboardAutoSync => 'Automatically Sync Clipboard';

  @override
  String get close2tray => 'Hide to Tray When Closing';

  @override
  String get nickname => 'Nickname';

  @override
  String get port => 'Port';

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
  String get messageSendFailed => 'Unable to send message. Try again';

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
  String get warning => 'Warning';

  @override
  String get close => 'Close';

  @override
  String deleteDeviceTitle(String device) {
    return 'Delete $device';
  }

  @override
  String get deleteDeviceDesc =>
      'Disconnect and clear all messages for this device. This cannot be undone.';

  @override
  String get brokeConnectTitle => 'Disconnect';

  @override
  String get connectFailed => 'Connection Failed';

  @override
  String get connectAlreadyInProgress => 'Connection already in progress';

  @override
  String get startServerFailed => 'Failed to Start Server';

  @override
  String get deleteMessageTitle => 'Delete Message';

  @override
  String get selectMessages => 'Select messages';

  @override
  String selectedMessageCount(int count) {
    return '$count selected';
  }

  @override
  String deleteSelectedMessagesTitle(int count) {
    return 'Delete $count messages';
  }

  @override
  String get deleteSelectedMessagesDesc =>
      'The selected messages will be deleted. This cannot be undone.';

  @override
  String language(Object language) {
    return 'Language $language';
  }

  @override
  String get pushNotification => 'Forward Android Notifications';

  @override
  String get ignoreNotification => 'Ignore Android Notifications';

  @override
  String get back => 'Back';

  @override
  String get selectAll => 'Select All';

  @override
  String get clearAll => 'Clear';

  @override
  String get selectNotifyApp => 'Notification apps';

  @override
  String get open => 'Open';

  @override
  String get openInFinder => 'Open in Finder';

  @override
  String get openInDir => 'Open Directory';

  @override
  String get deleteFile => 'Delete File';

  @override
  String get copyMessage => 'Copy Message Content';

  @override
  String get copyFile => 'Copy File';

  @override
  String get fileCopied => 'File copied';

  @override
  String get fileCopyFailed => 'Could not copy file';

  @override
  String get themeMode => 'Theme Mode';

  @override
  String get followSystem => 'Follow System';

  @override
  String get connectedNow => 'Connected now';

  @override
  String get nearbyAvailable => 'Available nearby';

  @override
  String get noMessagesYet => 'No messages yet';

  @override
  String get sharedFile => 'Shared a file';

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
  String get windowsLockScreenInput =>
      'Keyboard and mouse on the lock screen and UAC';

  @override
  String get windowsLockScreenInputHint =>
      'Type on the lock screen. The switch adds UAC prompts';

  @override
  String get windowsLockScreenInputDesc =>
      'This installs a system service so trusted devices can type on this PC\'s lock screen. Administrator approval is required.';

  @override
  String get windowsLockScreenInputUninstallDesc =>
      'After uninstalling, this PC\'s lock screen and UAC prompts can no longer be controlled. Administrator approval is required.';

  @override
  String get windowsLockScreenInputNotInstalled => 'Not installed';

  @override
  String get windowsLockScreenInputRunning => 'Running';

  @override
  String get windowsLockScreenInputStopped => 'Stopped';

  @override
  String get windowsLockScreenInputOutdated => 'Needs update';

  @override
  String get windowsLockScreenInputInstall => 'Install';

  @override
  String get windowsLockScreenInputRepair => 'Repair';

  @override
  String get windowsLockScreenInputUninstall => 'Uninstall';

  @override
  String get windowsLockScreenInputWorking => 'Waiting for the system service…';

  @override
  String get windowsLockScreenInputFailed =>
      'Could not change the lock screen input service';

  @override
  String get windowsElevatedInput => 'Answer UAC prompts';

  @override
  String get windowsElevatedInputEnableDesc =>
      'Trusted devices will be able to answer UAC prompts, but any program running as you on this PC can then get past UAC the same way. Administrator approval is required.';

  @override
  String get windowsElevatedInputDisableDesc =>
      'Trusted devices can no longer answer UAC prompts. The lock screen is not affected. Administrator approval is required.';

  @override
  String get windowsElevatedInputEnable => 'Turn on';

  @override
  String get windowsElevatedInputDisable => 'Turn off';

  @override
  String get windowsElevatedInputFailed => 'Could not change UAC control';

  @override
  String get launchAtStartup => 'Launch at startup';

  @override
  String get launchAtStartupDesc =>
      'Start Whisper automatically after desktop login to reconnect trusted devices';

  @override
  String get launchAtStartupFailed => 'Failed to update launch at startup';

  @override
  String get androidBackgroundKeepAlive =>
      'Keep connection alive in background';

  @override
  String get androidBackgroundKeepAliveActiveTitle =>
      'Whisper is listening for LAN connections';

  @override
  String get androidBackgroundKeepAliveActiveDesc =>
      'Nearby connection requests can arrive while the app is in the background';

  @override
  String get androidBatteryOptimization => 'Battery optimization';

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
  String get fileTransferWaitingPeerVerification =>
      'Waiting for peer verification';

  @override
  String get fileTransferFailedNotice => 'File transfer failed';

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
  String get remoteInputScrollMultiplierTitle =>
      'Keyboard and mouse scroll speed';

  @override
  String get audioShareUnsupportedCapture =>
      'This device does not support system audio capture';

  @override
  String get audioGroupSelectSinks => 'Select playback devices';

  @override
  String get audioGroupStart => 'Start synced playback';

  @override
  String get audioGroupRoleStereo => 'Stereo';

  @override
  String get audioGroupRoleLeft => 'Left channel';

  @override
  String get audioGroupRoleRight => 'Right channel';

  @override
  String get audioGroupRoleMono => 'Mono';

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
      'Place the peer screen against this device\'s edge in the keyboard and mouse workspace first';

  @override
  String get remoteInputEnabledMoveToEdge =>
      'Keyboard and mouse sharing is enabled. Move to the screen edge to control peer';

  @override
  String remoteInputFailed(String error) {
    return 'Keyboard and mouse sharing failed: $error';
  }

  @override
  String get remoteInputWorkspaceStop => 'Stop';

  @override
  String get remoteInputWorkspaceNoTargets =>
      'No available desktop control targets';

  @override
  String get remoteInputWorkspaceCanvasTitle => 'Screen arrangement';

  @override
  String remoteInputWorkspaceExitShortcut(String shortcut) {
    return 'Press $shortcut to stop sharing';
  }

  @override
  String remoteInputWorkspaceStatusActive(String peer) {
    return 'Controlling $peer';
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

  @override
  String get notificationChannelRequests => 'Requests to answer';

  @override
  String get emptyAppsTitle => 'No apps available';

  @override
  String get emptyAppsSearchTitle => 'No apps found';

  @override
  String get fileDropRejected => 'These files cannot be sent';

  @override
  String get validationNicknameRequired => 'Enter a nickname';

  @override
  String get validationNicknameTooLong =>
      'Nickname must be 64 characters or fewer';

  @override
  String get settingsSectionPermissionsSharing => 'Permissions and sharing';

  @override
  String get settingsSectionPermissionsSharingDesc =>
      'Clipboard, trust, audio, and keyboard or mouse access';

  @override
  String currentVersion(String version) {
    return 'Current version $version';
  }

  @override
  String get updateUpToDate => 'You\'re up to date';

  @override
  String get updateCheckFailed =>
      'Couldn\'t check for updates. Try again later';

  @override
  String updateAvailableTitle(String version) {
    return 'Version $version is available';
  }

  @override
  String updateAvailableBody(String currentVersion, String latestVersion) {
    return 'You have $currentVersion. Version $latestVersion is ready. The download will be verified against GitHub\'s file digest before it opens.';
  }

  @override
  String get downloadAndInstallUpdate => 'Update';

  @override
  String get viewRelease => 'View release';

  @override
  String get updateInstallerOpened =>
      'The verified update is ready in the system installer';

  @override
  String get updateInstallFailed =>
      'The update installer couldn\'t be opened. Try again later';

  @override
  String get aboutWhisper => 'About Whisper';

  @override
  String get aboutWhisperDescription =>
      'A local network collaboration app for your devices';

  @override
  String get officialWebsite => 'Official website';

  @override
  String get sourceCode => 'GitHub source code';

  @override
  String get appListClearSearch => 'Clear app search';

  @override
  String get settingsLoadFailedTitle => 'Settings could not be loaded';

  @override
  String get appListLoadFailedTitle => 'Apps could not be loaded';

  @override
  String get appListSaveFailed =>
      'Could not save the notification app selection';

  @override
  String get notificationApps => 'Notification apps';

  @override
  String get notificationForwardingUpdateFailed =>
      'Notification forwarding could not be updated';

  @override
  String get dangerousActions => 'Dangerous actions';

  @override
  String get pairingNewDeviceTitle => 'Pair a new device';

  @override
  String pairingNewDeviceCompareCode(String device) {
    return '$device wants to connect. Confirm the numbers match';
  }

  @override
  String get pairingIdentityChangedTitle => 'Device identity changed';

  @override
  String pairingIdentityChangedDescription(String device) {
    return 'The identity key for $device differs from the previous pairing. Continue only if the device was reinstalled or reset';
  }

  @override
  String get pairingLegacyTrustTitle => 'Confirm this trusted device again';

  @override
  String pairingLegacyTrustDescription(String device) {
    return '$device uses a legacy trust record and must be paired again to bind its identity';
  }

  @override
  String get pairingCompareCode =>
      'Confirm that both devices show the same six-digit code';

  @override
  String pairingNotificationBody(String device, String code) {
    return 'Pairing code $code · Compare with $device';
  }

  @override
  String pairingInitiatorNotificationBody(String device, String code) {
    return 'Pairing code $code · Waiting for $device';
  }

  @override
  String pairingIdentityChangedNotificationBody(String device, String code) {
    return 'Pairing code $code · $device\'s identity changed; open Whisper for details';
  }

  @override
  String pairingCodeSemantics(String code) {
    return 'Pairing code $code';
  }

  @override
  String get pairingReject => 'Reject';

  @override
  String get pairingApprove => 'Codes match';

  @override
  String get pairingViewDetails => 'View details';

  @override
  String get pairingUpgradeRequired =>
      'The other device is out of date. Update Whisper and try again';

  @override
  String get pairingExpired => 'The pairing request expired';

  @override
  String get pairingRejectedByPeer =>
      'The other device declined the connection request';

  @override
  String get pairingEncryptionNotice =>
      'After pairing, text, files, clipboard, and control data are end-to-end encrypted';

  @override
  String get e2eeTrustedConnection => 'End-to-end encrypted · Trusted device';

  @override
  String get e2eeEncryptedConnection => 'End-to-end encrypted connection';

  @override
  String get transferAssistantTitle => 'Search chat history';

  @override
  String get transferAssistantSearchHint => 'Search text messages';

  @override
  String get transferAssistantClearSearch => 'Clear search';

  @override
  String get transferAssistantSearchResults => 'Search results';

  @override
  String get transferAssistantFavorites => 'Favorites';

  @override
  String get transferAssistantRecent => 'Recent messages';

  @override
  String get transferAssistantAllMessages => 'All messages';

  @override
  String get transferAssistantExpandMessage => 'Expand message';

  @override
  String get transferAssistantCollapseMessage => 'Collapse message';

  @override
  String get transferAssistantNoResults => 'No matching text found';

  @override
  String get transferAssistantNoFavorites => 'No favorite texts yet';

  @override
  String get transferAssistantNoRecent => 'No text messages yet';

  @override
  String get transferAssistantIncoming => 'Received';

  @override
  String get transferAssistantOutgoing => 'Sent';

  @override
  String get transferAssistantCopy => 'Copy text';

  @override
  String get transferAssistantFavorite => 'Favorite text';

  @override
  String get transferAssistantUnfavorite => 'Remove from favorites';

  @override
  String get transferAssistantLoadFailed => 'Couldn\'t load text messages';

  @override
  String get transferAssistantCopied => 'Text copied';

  @override
  String get transferAssistantCopyFailed => 'Couldn\'t copy text';

  @override
  String get transferAssistantFavoriteFailed =>
      'Couldn\'t update favorites. Try again';

  @override
  String get qrMyCode => 'My QR code';

  @override
  String get qrWifiUnavailable =>
      'No usable LAN address was found. Connect to Wi-Fi, then refresh this code';

  @override
  String get qrCameraUnavailable =>
      'The camera is unavailable. Allow camera access for Whisper in system settings';

  @override
  String get qrToggleTorch => 'Toggle torch';

  @override
  String get qrSwitchCamera => 'Switch camera';

  @override
  String get qrCannotPairSelf =>
      'This is the current device. Scan a code from another device';

  @override
  String get qrInvalidCode =>
      'This is not a valid Whisper code. Ask the other device to show a new code';

  @override
  String get connectionDiagnosticTitle => 'Connection diagnosis';

  @override
  String get connectionDiagnosticWifi =>
      'The device cannot be reached. Confirm both devices use the same Wi-Fi and disable guest-network or AP isolation, then retry.';

  @override
  String get connectionDiagnosticAddress =>
      'The LAN address in the QR code is invalid or has changed. Ask the other device to reopen its code, then scan it again.';

  @override
  String get connectionDiagnosticService =>
      'The address was found, but Whisper did not respond. Open Whisper on the other device and confirm its LAN service is running.';

  @override
  String get connectionDiagnosticFirewall =>
      'The connection timed out. Allow Whisper through the system firewall on both devices, then retry.';

  @override
  String get connectionDiagnosticIdentity =>
      'The device identity does not match the QR code, so Whisper stopped the connection. Ask the other device to show a new code; do not bypass this check.';

  @override
  String get connectionDiagnosticVersion =>
      'The devices use incompatible protocol versions. Update Whisper to the same recent version, then retry.';

  @override
  String get connectionDiagnosticPairing =>
      'Pairing did not finish. Keep Whisper open on both devices and compare the pairing code again.';

  @override
  String get quickSendTitle => 'Quick send';

  @override
  String get quickSendTargets => 'Send to';

  @override
  String get quickSendNoConnectedDevices =>
      'No device is connected yet. Connect one to send.';

  @override
  String quickSendMoreFiles(int count) {
    return '$count more files';
  }

  @override
  String get quickSendLater => 'Later';

  @override
  String androidSystemShareWaitingForDevice(String device) {
    return 'Waiting for $device; sending will start when it connects';
  }

  @override
  String androidSystemShareSendingTo(String device) {
    return 'Sending to $device';
  }

  @override
  String androidSystemShareSentTo(String device) {
    return 'Sent to $device';
  }

  @override
  String get androidSystemShareFailedRetained =>
      'Sending failed. The shared content was kept';

  @override
  String get androidSystemShareStillPending =>
      'Shared content is still waiting for a device';

  @override
  String get androidSystemShareQueueFull =>
      'The share queue is full. Process existing shares before adding more';

  @override
  String get androidSystemShareRejected =>
      'The shared content exceeded a limit or could not be read completely, so it was not added';

  @override
  String get androidSystemShareTargetNeedsReselection =>
      'The target device\'s identity changed or is no longer trusted. Choose it again';

  @override
  String get androidSystemShareChooseAction => 'Choose device';

  @override
  String get desktopQuickSendSent => 'Added to the encrypted transfer queue';

  @override
  String get desktopQuickSendFailedRetained =>
      'Sending did not finish; the content was retained';

  @override
  String get desktopQuickSendShortcutUnavailable =>
      'The global send shortcut is already in use';

  @override
  String get desktopQuickSendDraftLimit =>
      'Quick send is full. Process existing content before adding more';

  @override
  String get desktopQuickSendFileLimit =>
      'Too many files were selected, so the new content was not added';

  @override
  String get desktopQuickSendTextLimit =>
      'The text is too long, so it was not added';

  @override
  String get desktopQuickSendInvalidPath =>
      'A file path is invalid or too long, so the new content was not added';

  @override
  String get desktopQuickSendClipboardSnapshotUnavailable =>
      'The clipboard could not be read immediately, so potentially changed content was not added';

  @override
  String get desktopQuickSendTargetConflict =>
      'Some content was already sent to another device. Select the original device to continue';

  @override
  String get desktopQuickSendTargetNeedsReselection =>
      'The target identity changed or is no longer trusted. The content was retained; select a device again';

  @override
  String chatTimestampYesterday(String time) {
    return 'Yesterday $time';
  }

  @override
  String get messageLinkOpenFailed => 'Could not open this link';

  @override
  String get deviceOffline => 'Offline devices';

  @override
  String serverPortInUse(int port) {
    return 'Port $port is already in use. Close other Whisper instances, or choose another port in Settings and retry.';
  }

  @override
  String get serverPermissionDenied =>
      'The system denied network listening. Allow Whisper to access the local network, check your firewall, and retry.';

  @override
  String get serverUnavailableHelp =>
      'Unable to accept connections. Check your network connection, local network permission, and firewall, then retry.';

  @override
  String updatePackageSaved(String path) {
    return 'The installer is saved at:\n$path\nYou can retry the installation later.';
  }

  @override
  String get updateInstalledRestart =>
      'Update installed. Reopen Whisper to use the new version.';

  @override
  String get castReceiverTitle => 'TV casting';

  @override
  String get castReceiverHint =>
      'Turn on, then select this device’s name in a video app on the same local network.';

  @override
  String get castReceiverStarting => 'Starting…';

  @override
  String get castReceiverNoLan =>
      'No local network address is available. Connect to the network and turn casting on again.';

  @override
  String get castReceiverStartupFailed =>
      'Casting could not start. Turn it off and on again.';

  @override
  String get castPlay => 'Play';

  @override
  String get castPause => 'Pause';

  @override
  String get castMute => 'Mute';

  @override
  String get castUnmute => 'Unmute';

  @override
  String get castFullscreen => 'Fullscreen';

  @override
  String get videoPlaybackFailed =>
      'Unable to play this video. Retry or open it with another app.';

  @override
  String get castPlaybackFailed =>
      'Video playback failed. Retry or cast again from your phone.';

  @override
  String get castControlFailed =>
      'The control could not be applied. Please retry.';

  @override
  String get castRequestTitle => 'Allow this device to cast?';

  @override
  String castRequestMessage(String address) {
    return 'A device at $address wants to play a video here.';
  }

  @override
  String get castRequestDeny => 'Decline';

  @override
  String get castRequestAllow => 'Allow casting';

  @override
  String get castExitFullscreen => 'Exit fullscreen';

  @override
  String get castSeek => 'Playback position';

  @override
  String get castVolume => 'Volume';

  @override
  String get mobileControlPointer => 'Mouse';

  @override
  String get mobileControlKeysTab => 'Keyboard';

  @override
  String get mobileControlSettings => 'Pointer settings';

  @override
  String get mobileControlPrecisionHint =>
      'Small movements give finer control. Turn faster to travel farther.';

  @override
  String get mobileControlCalibrationRetry =>
      'Keep the phone still and try calibrating again.';

  @override
  String get mobileControlMotionStart => 'Enable motion';

  @override
  String get mobileControlMotionPause => 'Pause motion';

  @override
  String get mobileControlMotionOnHint =>
      'Turn your wrist to move. Tap here to pause.';

  @override
  String get mobileControlMotionOffHint =>
      'Tap once, then move without holding the screen.';

  @override
  String get mobileControlTarget => 'Control target';

  @override
  String get mobileControlTargetHint => 'Start again after switching.';

  @override
  String get mobileControlPointerSpeed => 'Touchpad pointer speed';

  @override
  String get mobileControlScrollSpeed => 'Scroll speed';

  @override
  String get mobileControlPermissionDesktop =>
      'Allow remote control on the computer, then start again. On Linux, accept the system remote-control prompt.';

  @override
  String get mobileControlLinuxTextHint =>
      'Linux can commit only characters available in the computer’s current keyboard layout. For Chinese and emoji, use the virtual keyboard with the computer’s input method. Unsupported text stays in your draft.';

  @override
  String get manualConnectAddressInvalid =>
      'Enter a valid LAN IP or .local address';

  @override
  String get manualConnectPortInvalid => 'Use a port from 1 to 65535';

  @override
  String get transferStorageHelp =>
      'Cannot save. Check storage and folder permissions on the receiving device.';

  @override
  String get transferSourceHelp =>
      'Cannot read the source. Select the file again.';

  @override
  String get transferIntegrityHelp =>
      'File verification failed. Retry the transfer.';

  @override
  String get transferQueueHelp =>
      'The receiving device is busy. Try again shortly.';

  @override
  String get transferTrustHelp => 'Confirm device trust again before sending.';

  @override
  String get transferRetryHelp =>
      'Transfer incomplete. Reconnect the devices and retry.';

  @override
  String get mobileControlTransportHelp =>
      'The control connection was interrupted. Open Whisper on the computer, then start again.';

  @override
  String get mobileControlInjectionHelp =>
      'The computer could not process input. Check its control permissions, then start again.';

  @override
  String get historyLoadFailed => 'Could not load history. Tap to retry.';

  @override
  String get deleteReceivedFilesDesc =>
      'Received local files will also be deleted. Sent originals will be kept.';

  @override
  String get keepReceivedFiles => 'Keep received files';

  @override
  String get messageDeleteFailed =>
      'Deletion could not be completed. Please try again.';

  @override
  String get connectionQrTab => 'QR code';

  @override
  String get connectionScanTab => 'Scan';

  @override
  String get connectionAddressTab => 'IP / port';

  @override
  String get attachFile => 'File';

  @override
  String get attachFolder => 'Folder';

  @override
  String folderFileCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString files',
      one: '1 file',
      zero: 'Empty folder',
    );
    return '$_temp0';
  }

  @override
  String folderSkippedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString not transferred';
  }

  @override
  String get folderSkippedTitle => 'Items not transferred';

  @override
  String folderSkippedMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Details for $countString more are on the other device';
  }

  @override
  String get folderSkipSymlink => 'Links are not sent';

  @override
  String get folderSkipSpecial => 'Not a regular file';

  @override
  String get folderSkipInvalidName => 'Name is not valid on other systems';

  @override
  String get folderSkipPathTooLong => 'Path is too long or too deep';

  @override
  String get folderSkipTooLarge => 'File is too large';

  @override
  String get folderSkipUnreadable => 'Could not be read';

  @override
  String get folderSkipSourceUnavailable =>
      'Moved, changed or unreadable while sending';

  @override
  String get folderSkipWriteFailed => 'Could not be saved on this device';

  @override
  String get folderSkipNameCollision =>
      'Differs from another item only by letter case';

  @override
  String get folderSkipIntegrity => 'Failed verification';

  @override
  String get folderSendFailed => 'This folder could not be sent';

  @override
  String get folderSendUnsupported =>
      'Whisper on the other device is too old to receive folders. Update it first';

  @override
  String get folderSendInvalidName =>
      'This folder\'s name is not valid on other systems. Rename it and try again';

  @override
  String get folderSendUnreadable => 'This folder could not be read';

  @override
  String folderSendTooManyEntries(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'This folder has more than $limitString items. Send it in parts';
  }

  @override
  String get folderSendTooLarge =>
      'This folder is larger than 1 TB and cannot be sent';

  @override
  String folderFileProgress(int done, int total) {
    final intl.NumberFormat doneNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String doneString = doneNumberFormat.format(done);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$doneString of $totalString files';
  }

  @override
  String get windowStreamConnecting => 'Connecting…';

  @override
  String get windowStreamPaused => 'Paused. Click to resume';

  @override
  String get windowStreamReconnecting => 'Reconnecting…';

  @override
  String get windowStreamDisplaced =>
      'Back on the phone. Click to bring it here';

  @override
  String get windowStreamSecureBlocked =>
      'This app doesn\'t allow screen sharing';

  @override
  String get windowStreamAppExited => 'The app has closed';

  @override
  String get windowStreamDisconnected =>
      'Disconnected. You can close this window';

  @override
  String get windowStreamUnauthorized =>
      'Allow debugging from this computer on your phone';

  @override
  String get windowStreamDeviceOffline =>
      'The phone isn\'t responding. Reconnect the cable or turn Wireless debugging off and on';

  @override
  String get windowStreamAdbMissing =>
      'adb wasn\'t found. Install Android Platform Tools first';

  @override
  String get windowStreamAdbFailed => 'The adb server couldn\'t start';

  @override
  String get windowStreamUnsupported =>
      'Phone app windows aren\'t available on this computer yet';

  @override
  String get windowStreamSearchApps => 'Search apps';

  @override
  String get windowStreamShowSystemApps => 'Show system apps';

  @override
  String get windowStreamRetry => 'Retry';

  @override
  String get windowStreamInjectDenied =>
      'On Xiaomi phones, also turn on “USB debugging (Security settings)” in Developer options, then restart the phone';

  @override
  String get windowStreamAndroidTooOld => 'Requires Android 10 or later';

  @override
  String get windowStreamOpenFailed => 'Couldn\'t open this app';

  @override
  String get windowStreamNoApps => 'No apps found';

  @override
  String get windowStreamSpaceTitle => 'Flow';

  @override
  String get windowStreamPause => 'Pause';

  @override
  String get windowStreamResume => 'Resume';

  @override
  String get windowStreamClose => 'Close';

  @override
  String get windowStreamNoDevices => 'No devices yet';

  @override
  String get windowStreamNoDevicesHintDesktop =>
      'Connect an Android phone with a cable, or turn on Wireless debugging in its Developer options.';

  @override
  String get windowStreamNoDevicesHintMobile =>
      'Open Whisper on your Mac and trust each other; its windows will show up here.';

  @override
  String get windowStreamLoadFailed => 'Couldn\'t load this device\'s apps';

  @override
  String get windowStreamBackToSpace => 'Back to Flow';

  @override
  String get windowStreamKeyboard => 'Keyboard';

  @override
  String get windowStreamSourceLocked =>
      'This computer is locked. Unlock it to stream its windows.';

  @override
  String get windowStreamCapturePermission =>
      'This computer hasn\'t allowed Whisper to record its screen yet. Turn it on in its System Settings › Privacy & Security › Screen Recording.';

  @override
  String get windowStreamUntrusted =>
      'Whisper on this phone isn\'t paired with this device yet. Open Whisper on the phone, connect to this device and confirm the pairing to stream.';

  @override
  String get windowStreamWhisperMissing =>
      'This phone has no usable Whisper. Install the latest Whisper and pair it with this device to stream.';

  @override
  String get windowStreamNotPaired => 'Not paired';

  @override
  String windowStreamSendTo(String device) {
    return 'Send to $device';
  }

  @override
  String windowStreamSent(String device) {
    return 'Sent to $device. Tap the prompt there to view it.';
  }

  @override
  String get windowStreamSendFailed =>
      'Couldn\'t send it. Make sure that device is connected to this one.';

  @override
  String windowStreamSendUnavailable(String device) {
    return 'Whisper on $device needs to be connected to this computer and up to date to receive windows.';
  }

  @override
  String get windowStreamNoLocalWindows =>
      'No windows on this computer to send';

  @override
  String windowStreamOfferTitle(String device) {
    return '$device sent you a window';
  }

  @override
  String get windowStreamOfferView => 'View';

  @override
  String windowStreamOfferFrom(String device) {
    return 'From $device';
  }

  @override
  String get remoteFilesTitle => 'Files';

  @override
  String get remoteFilesThisDevice => 'This device';

  @override
  String remoteFilesOffline(String device) {
    return '$device isn\'t connected right now';
  }

  @override
  String remoteFilesUnsupported(String device) {
    return 'Whisper on $device needs updating to browse its files';
  }

  @override
  String get remoteFilesEmptyFolder => 'This folder is empty';

  @override
  String get remoteFilesNewFolder => 'New folder';

  @override
  String get remoteFilesFolderName => 'Folder name';

  @override
  String get remoteFilesRename => 'Rename';

  @override
  String get remoteFilesMoveToTrash => 'Move to Trash';

  @override
  String get remoteFilesDelete => 'Delete';

  @override
  String remoteFilesDeleteForever(int count) {
    return 'Delete these $count items for good? This device has no trash, so they can\'t be recovered.';
  }

  @override
  String get remoteFilesFailed => 'That didn\'t work';

  @override
  String get remoteFilesNameExists =>
      'Something with that name is already here';

  @override
  String get remoteFilesShowHidden => 'Show hidden files';

  @override
  String remoteFilesSelected(int count) {
    return '$count selected';
  }

  @override
  String get remoteFilesCreate => 'Create';

  @override
  String get remoteFilesDone => 'Done';

  @override
  String get remoteFilesPlaceRoot => 'Home';

  @override
  String get remoteFilesPlaceStorage => 'Internal storage';

  @override
  String get remoteFilesPlaceDesktop => 'Desktop';

  @override
  String get remoteFilesPlaceDocuments => 'Documents';

  @override
  String get remoteFilesPlaceDownloads => 'Downloads';

  @override
  String get remoteFilesPlacePictures => 'Pictures';

  @override
  String get remoteFilesPlaceCamera => 'Camera';

  @override
  String get remoteFilesPlaceMovies => 'Movies';

  @override
  String get remoteFilesPlaceMusic => 'Music';

  @override
  String remoteFilesPromptTitle(String device) {
    return '$device wants to browse your files';
  }

  @override
  String get remoteFilesPromptBodyPhone =>
      'If you allow it, it can see this phone\'s internal storage and copy, create, rename and delete files there. Deleted files can\'t be recovered.';

  @override
  String get remoteFilesDeny => 'Don\'t allow';

  @override
  String get remoteFilesAllowOnce => 'Allow this time';

  @override
  String get remoteFilesAllowAlways => 'Always allow';

  @override
  String windowStreamTouchBlockedTitle(String device) {
    return '$device isn\'t responding to touch';
  }

  @override
  String windowStreamTouchBlockedBody(String app) {
    return 'A page $app left in the background is covering the phone\'s screen, so touches don\'t get through. Closing that page fixes it; $app stays installed with its account and history.';
  }

  @override
  String get windowStreamTouchBlockedFix => 'Close that page';

  @override
  String get windowStreamTouchBlockedLater => 'Not now';

  @override
  String get windowStreamTouchBlockedFixed => 'Done. The phone responds again.';

  @override
  String get remoteFilesWaitingDetail =>
      'Whisper is asking there whether this device may browse its files.';

  @override
  String get remoteFilesAskAgain => 'Ask Again';

  @override
  String get remoteFilesColumnName => 'Name';

  @override
  String get remoteFilesColumnModified => 'Date Modified';

  @override
  String get remoteFilesColumnSize => 'Size';

  @override
  String get remoteFilesColumnKind => 'Kind';

  @override
  String get remoteFilesKindFolder => 'Folder';

  @override
  String get remoteFilesKindImage => 'Image';

  @override
  String get remoteFilesKindVideo => 'Movie';

  @override
  String get remoteFilesKindAudio => 'Audio';

  @override
  String get remoteFilesKindDocument => 'Document';

  @override
  String get remoteFilesKindArchive => 'Archive';

  @override
  String get remoteFilesKindCode => 'Source Code';

  @override
  String get remoteFilesKindApp => 'Application';

  @override
  String get remoteFilesKindOther => 'File';

  @override
  String remoteFilesKindNamed(String ext, String kind) {
    return '$ext $kind';
  }

  @override
  String get remoteFilesViewList => 'List';

  @override
  String get remoteFilesViewIcons => 'Icons';

  @override
  String get remoteFilesSearch => 'Search';

  @override
  String remoteFilesNoResults(String query) {
    return 'No results for “$query”';
  }

  @override
  String get remoteFilesOpen => 'Open';

  @override
  String get remoteFilesCopy => 'Copy';

  @override
  String remoteFilesPaste(int count) {
    return 'Paste $count Items';
  }

  @override
  String get remoteFilesRefresh => 'Refresh';

  @override
  String get remoteFilesSameDevice => 'Already on this device';

  @override
  String get remoteFilesBetweenOthers =>
      'Copies go between this device and another one';

  @override
  String remoteFilesOpenFirst(String device) {
    return 'Open $device’s files first';
  }

  @override
  String get remoteFilesUntitledFolder => 'untitled folder';

  @override
  String get remoteFilesSelect => 'Select';

  @override
  String get remoteFilesSelectAll => 'Select All';

  @override
  String get remoteFilesCopyToMenu => 'Copy To…';

  @override
  String get remoteFilesCopyHere => 'Copy Here';

  @override
  String get remoteFilesChooseDestination =>
      'Pick a folder, then tap “Copy Here”';

  @override
  String remoteFilesToday(String time) {
    return 'Today at $time';
  }

  @override
  String remoteFilesYesterday(String time) {
    return 'Yesterday at $time';
  }

  @override
  String get remoteFilesCopyToSubmenu => 'Copy To';

  @override
  String remoteFilesPasteInto(String name) {
    return 'Paste into “$name”';
  }

  @override
  String get remoteFilesPastePlain => 'Paste';

  @override
  String get remoteFilesSortBy => 'Sort By';

  @override
  String get remoteFilesMore => 'More';

  @override
  String get windowStreamTextSize => 'Text Size';

  @override
  String get macPermissionAccessibility => 'Accessibility';

  @override
  String get macPermissionScreenRecording => 'Screen & System Audio Recording';

  @override
  String get macPermissionAudioCapture => 'System Audio Recording Only';

  @override
  String get macPermissionGranted => 'Allowed';

  @override
  String get macPermissionDenied => 'Not allowed';

  @override
  String get windowStreamQuality => 'Quality';

  @override
  String get windowStreamQualitySmooth => 'Smooth';

  @override
  String get windowStreamQualityStandard => 'Standard';

  @override
  String get windowStreamQualityHigh => 'High';

  @override
  String get windowStreamQualityBest => 'Best';

  @override
  String get windowStreamQualityHint =>
      'Sharper as it goes up, using more network';

  @override
  String get windowStreamStreaming => 'Open here';

  @override
  String get windowStreamCloseWindow => 'Close Window';

  @override
  String get windowStreamCloseFailed => 'Couldn’t close this window';

  @override
  String get windowStreamOfferIgnore => 'Dismiss';

  @override
  String get deviceDetailsTitle => 'Device Details';

  @override
  String get deviceFeaturesSection => 'Features';

  @override
  String get deviceFeatureNeedsConnection => 'Available when connected';

  @override
  String get windowStreamSwitcherRotate => 'Rotate';

  @override
  String get remoteFilesCopyStarting => 'Getting ready…';

  @override
  String remoteFilesCopyItems(int count) {
    return '$count items';
  }

  @override
  String remoteFilesCopyToDevice(String device, String folder) {
    return 'To “$folder” on $device';
  }

  @override
  String get remoteFilesFinder => 'Finder';

  @override
  String get remoteFilesExplorer => 'File Explorer';

  @override
  String get remoteFilesFileManager => 'Files';

  @override
  String remoteFilesMountTooOld(String device, String app) {
    return 'Whisper on $device needs updating to open its files in $app';
  }

  @override
  String remoteFilesMountDenied(String device) {
    return '$device didn\'t allow access to its files';
  }

  @override
  String remoteFilesMountFailed(String app, String device) {
    return '$app couldn\'t open the files on $device';
  }

  @override
  String remoteFilesMountNeedsFuse(String app) {
    return 'Install fuse3 to open other devices\' files in $app';
  }

  @override
  String remoteFilesCopyFromDevice(String device, String folder) {
    return 'From $device to “$folder”';
  }

  @override
  String remoteFilesCopyLeft(String time) {
    return '$time left';
  }

  @override
  String remoteFilesSeconds(int count) {
    return '$count s';
  }

  @override
  String remoteFilesMinutes(int count) {
    return '$count min';
  }

  @override
  String remoteFilesHours(int count) {
    return '$count h';
  }

  @override
  String remoteFilesCopyItemsDone(int done, int total) {
    return '$done of $total';
  }

  @override
  String remoteFilesCopyFilesMoved(int count) {
    return '$count files so far';
  }

  @override
  String remoteFilesCopyWaiting(String device) {
    return 'Waiting for $device to come back…';
  }

  @override
  String get remoteFilesCopyPaused => 'Paused';

  @override
  String get remoteFilesCopyFailedShort => 'Copy failed';

  @override
  String get remoteFilesCopyCanceledShort => 'Stopped';

  @override
  String get remoteFilesCopyDoneShort => 'Copied';

  @override
  String get remoteFilesCopyResume => 'Resume';

  @override
  String get remoteFilesCopyRetry => 'Retry';

  @override
  String get remoteFilesCopyStop => 'Stop copying';

  @override
  String get remoteFilesCopyShowAll => 'Show all transfers';

  @override
  String get remoteFilesCopyAlready => 'These are already being copied here';

  @override
  String get remoteFilesTransfers => 'Transfers';

  @override
  String get remoteFilesTransfersEmpty => 'No copies yet';

  @override
  String get remoteFilesTransfersClear => 'Clear finished';

  @override
  String get remoteFilesTransfersActive => 'In progress';

  @override
  String get remoteFilesTransfersRecent => 'Finished';

  @override
  String get remoteFilesCopyRemove => 'Remove from list';

  @override
  String get remoteFilesCopyReveal => 'Show in Files';

  @override
  String remoteFilesDeleteTitle(int count) {
    return 'Delete $count items for good?';
  }

  @override
  String remoteFilesDeleteDetail(String device) {
    return '$device has no Trash: once deleted, they can\'t be recovered.';
  }

  @override
  String remoteFilesAndMore(int count) {
    return 'and $count more';
  }

  @override
  String get remoteFilesCopyJustDone => 'Already copied just now';

  @override
  String windowStreamHostLocked(String device) {
    return '$device is locked. Unlock it to show its windows here.';
  }

  @override
  String windowStreamHostPermissionMac(String device) {
    return '$device hasn\'t allowed Whisper to record its screen. On that Mac, turn on Whisper in System Settings › Privacy & Security › Screen & System Audio Recording.';
  }

  @override
  String windowStreamHostPermission(String device) {
    return '$device doesn\'t let Whisper record its windows. Allow screen recording for Whisper in that computer\'s privacy settings, then try again.';
  }

  @override
  String windowStreamHostHelper(String device) {
    return '$device needs one more step: log out of that computer and back in, then its windows can be shown here.';
  }

  @override
  String windowStreamHostDesktopUnsupported(String device) {
    return '$device\'s desktop can\'t share windows yet. It needs GNOME or KDE Plasma on Wayland.';
  }

  @override
  String windowStreamHostElevated(String device) {
    return 'This window runs as administrator, so Whisper can\'t show it. On $device, open the app again without administrator rights.';
  }

  @override
  String get windowStreamHostProtected =>
      'This window blocks screen recording, so it can\'t be shown here.';

  @override
  String windowStreamHostEncoder(String device) {
    return '$device couldn\'t start encoding video. Try again in a moment.';
  }

  @override
  String windowStreamHostEncoderLinux(String device) {
    return '$device has no H.264 video encoder, so its windows can\'t be shared. Install FFmpeg on that computer, plus the x264 or openh264 encoder.';
  }

  @override
  String windowStreamHostUnsupported(String device) {
    return '$device can\'t share its windows yet. Update Whisper on that device to the latest version.';
  }

  @override
  String windowStreamHostUnsupportedWindows(String device) {
    return '$device needs Windows 10 version 1903 or later to share its windows.';
  }

  @override
  String windowStreamHostUnsupportedMac(String device) {
    return '$device needs macOS 12.3 or later to share its windows.';
  }

  @override
  String get windowStreamThatDevice => 'that device';

  @override
  String remoteFilesPlaceDrive(String name, String drive) {
    return '$name ($drive:)';
  }

  @override
  String remoteFilesPlaceLocalDisk(String drive) {
    return 'Local Disk ($drive:)';
  }

  @override
  String remoteFilesPlaceRemovableDisk(String drive) {
    return 'USB Drive ($drive:)';
  }

  @override
  String get remoteFilesPlaceAppFolder => 'Whisper Folder';

  @override
  String get islandAudioPaused => 'Playback paused';

  @override
  String get islandAudioStarting => 'Connecting…';

  @override
  String get islandAudioEnded => 'Disconnected';

  @override
  String islandStreamedTitle(String device) {
    return 'Streaming to $device';
  }

  @override
  String islandStreamedWindows(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count windows are showing on that device and can be used there',
      one: '1 window is showing on that device and can be used there',
    );
    return '$_temp0';
  }

  @override
  String get islandStreamedStop => 'Stop streaming';

  @override
  String get islandStreamedStopping => 'Stopping…';

  @override
  String get islandStreamedEnded => 'Streaming ended';

  @override
  String get islandStreamedOtherDevice => 'another device';

  @override
  String islandMore(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count more',
      one: '1 more',
    );
    return '$_temp0';
  }

  @override
  String get islandHint => 'Tap to expand, swipe up to put away';

  @override
  String get shareLinkMenuCreate => 'Create Share Link…';

  @override
  String shareLinkDefaultName(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$_temp0';
  }

  @override
  String get shareLinkRoute => 'Route';

  @override
  String get shareLinkShortRoute => 'Short Route';

  @override
  String get shareLinkPassword => 'Password';

  @override
  String get shareLinkCreate => 'Create Link';

  @override
  String get shareLinkRouteTaken => 'Another link already uses this route';

  @override
  String get shareLinkRouteInvalid =>
      'Use 2–32 characters: lowercase letters, digits, - or _';

  @override
  String get shareLinkRouteReserved =>
      'This route is reserved. Try another one.';

  @override
  String get shareLinkItemsMissing => 'The items to share are no longer there';

  @override
  String get shareLinkCreateFailed => 'Couldn\'t create the link';

  @override
  String get shareLinkCopy => 'Copy Link';

  @override
  String get shareLinkPasswordProtected => 'Password protected';

  @override
  String get shareLinksTitle => 'Share Links';

  @override
  String get shareLinksService => 'File Server';

  @override
  String shareLinksServiceRunning(String port) {
    return 'Running on port $port';
  }

  @override
  String get shareLinksServiceIdle => 'No links are on, so the port is closed';

  @override
  String get shareLinksServiceOff =>
      'Off. Links are kept but can\'t be opened.';

  @override
  String get shareLinksServiceStarting => 'Starting…';

  @override
  String shareLinksServicePortsBusy(String from, String to) {
    return 'Ports $from–$to are all in use';
  }

  @override
  String get shareLinksServiceFailed => 'Couldn\'t start';

  @override
  String get shareLinkStatusOn => 'On';

  @override
  String get shareLinkStatusOff => 'Off';

  @override
  String get shareLinkStatusMissing => 'Files missing';

  @override
  String get shareLinkStatusPartlyMissing => 'Some files missing';

  @override
  String shareLinkVisits(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count visits',
      one: '1 visit',
    );
    return '$_temp0';
  }

  @override
  String get shareLinkQr => 'QR Code';

  @override
  String get shareLinkTurnOn => 'Turn On Link';

  @override
  String get shareLinkTurnOff => 'Turn Off Link';

  @override
  String get shareLinkDelete => 'Delete Link';

  @override
  String get shareLinkDeleteTitle => 'Delete this share link?';

  @override
  String get shareLinkDeleteDetail =>
      'The address stops working right away. Files on this device aren\'t affected.';

  @override
  String get shareLinksEmpty => 'No Share Links';

  @override
  String get shareLinksEmptyDetailDesktop =>
      'Right-click a file or folder on this device and choose “Create Share Link…”. You can select several first.';

  @override
  String get shareLinksEmptyDetailPhone =>
      'Touch and hold a file or folder on this device and choose “Create Share Link…”, or select several and use the bar at the bottom.';

  @override
  String get shareWebDownload => 'Download';

  @override
  String get shareWebOpen => 'Open in Browser';

  @override
  String get shareWebDownloadAll => 'Download All (.zip)';

  @override
  String shareWebItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$_temp0';
  }

  @override
  String get shareWebEmptyFolder => 'This folder is empty';

  @override
  String get shareWebNotFoundTitle => 'This Link Isn\'t Available';

  @override
  String get shareWebNotFoundDetail =>
      'It may have been turned off, or the address may be mistyped. Check with the person who shared it.';

  @override
  String get shareWebMissingTitle => 'File Not Found';

  @override
  String get shareWebMissingDetail =>
      'It may have been moved, renamed or deleted.';

  @override
  String get shareWebBack => 'Back to Shared Items';

  @override
  String get shareWebPasswordTitle => 'Password Required';

  @override
  String get shareWebPasswordDetail =>
      'This shared link is protected with a password.';

  @override
  String get shareWebContinue => 'Continue';

  @override
  String get shareWebPasswordWrong => 'Incorrect password. Try again.';

  @override
  String get shareWebTooManyTitle => 'Too Many Attempts';

  @override
  String get shareWebTooManyDetail => 'Wait a minute, then try again.';

  @override
  String get shareWebErrorTitle => 'Something Went Wrong';

  @override
  String get shareWebErrorDetail => 'Try again in a moment.';

  @override
  String get windowStreamDecoderMissing =>
      'Can\'t show this window: FFmpeg\'s video decoder isn\'t installed on this computer';

  @override
  String get windowStreamVolume => 'Volume';

  @override
  String get windowStreamMute => 'Mute';

  @override
  String get windowStreamUnmute => 'Unmute';

  @override
  String get windowStreamMovedAway =>
      'This window was opened on another device';

  @override
  String flowTaskOpenOn(String device) {
    return 'Showing on $device';
  }

  @override
  String get gnomeHelperTitle => 'Window sharing helper';

  @override
  String get gnomeHelperHint =>
      'Showing this computer’s windows on your other devices needs a small GNOME component and one logout';

  @override
  String get gnomeHelperWorking => 'Installing…';

  @override
  String get gnomeHelperReady => 'Ready';

  @override
  String get gnomeHelperNotInstalled => 'Not installed';

  @override
  String get gnomeHelperNeedsRelogin => 'Log out to finish';

  @override
  String get gnomeHelperOutdated => 'Needs update';

  @override
  String get gnomeHelperDisabled => 'Turned off';

  @override
  String get gnomeHelperExtensionsOff => 'Extensions off';

  @override
  String get gnomeHelperInstallDesc =>
      'Whisper adds a small GNOME Shell extension that keeps shared windows running in the background and passes on keyboard and mouse input. Only Whisper can use it. Log out and back in once after installing.';

  @override
  String get gnomeHelperUpdateDesc =>
      'This version of Whisper brings a newer window sharing helper. Log out and back in once after updating.';

  @override
  String get gnomeHelperReloginDesc =>
      'The helper is installed. GNOME loads it after you log back in. Save your work in other apps before logging out.';

  @override
  String get gnomeHelperDisabledDesc =>
      'The window sharing helper was turned off in GNOME Extensions. Turn it back on so your other devices can show this computer’s windows.';

  @override
  String get gnomeHelperExtensionsOffDesc =>
      'GNOME extensions are turned off. The helper runs only with extensions on (other installed extensions turn on too).';

  @override
  String get gnomeHelperReadyDesc =>
      'The window sharing helper is running. Your other devices can show this computer’s windows while they keep running here in the background.';

  @override
  String get gnomeHelperInstall => 'Install';

  @override
  String get gnomeHelperUpdate => 'Update';

  @override
  String get gnomeHelperLogOut => 'Log Out…';

  @override
  String get gnomeHelperLater => 'Later';

  @override
  String get gnomeHelperTurnOn => 'Turn On';

  @override
  String get gnomeHelperTurnOnExtensions => 'Turn On Extensions';

  @override
  String get gnomeHelperDone => 'OK';

  @override
  String get gnomeHelperInstalled =>
      'Installed. Log out and back in to finish.';

  @override
  String get gnomeHelperFailed => 'Couldn’t install the window sharing helper';

  @override
  String get windowStreamShareSetting => 'Share This Computer\'s Windows';

  @override
  String get deviceFilesAlwaysAllowed => 'Always Allow Browsing My Files';

  @override
  String get deviceMountHere => 'Mount on this computer';

  @override
  String windowStreamCloseStillOpen(String app) {
    return '“$app” is still open — it may be asking whether to save.';
  }

  @override
  String get windowStreamCloseShow => 'Show Window';

  @override
  String get windowStreamClosing => 'Closing';

  @override
  String shareWebFrom(String device) {
    return 'From $device';
  }

  @override
  String get shareWebFooterLan =>
      'Files come straight from this device over your local network, not through the cloud.';

  @override
  String shareWebPreviewTruncated(String size) {
    return 'Showing the first $size. Download the file to see all of it.';
  }

  @override
  String get shareWebPrevious => 'Previous';

  @override
  String get shareWebNext => 'Next';

  @override
  String get shareLinkAddress => 'Address';

  @override
  String get shareLinksServiceFooter =>
      'Devices on the same network can open a link in any browser. The server only runs while a link is on.';

  @override
  String get androidWindowServiceTitle => 'Window flow service';

  @override
  String get androidWindowServiceRunning => 'On';

  @override
  String get androidWindowServiceRunningHint =>
      'Your trusted computers can now see this phone in their window flow and open its apps';

  @override
  String get androidWindowServiceStopped => 'Not running';

  @override
  String get androidWindowServiceStoppedHint =>
      'Turn on Wireless debugging, then start it again here without a computer';

  @override
  String get androidWindowServiceNeedsSetup => 'Not set up';

  @override
  String get androidWindowServiceNeedsSetupHint =>
      'Once on, this phone\'s apps can flow to your trusted computers to view and control, while the phone stays in the background';

  @override
  String get androidWindowServiceStart => 'Turn on';

  @override
  String get androidWindowServiceStop => 'Turn off';

  @override
  String get androidWindowServiceHowTitle => 'One-time setup';

  @override
  String get androidWindowServiceStep1 => 'Turn on Developer options';

  @override
  String get androidWindowServiceStep1Hint =>
      'Tap Build number 7 times under About phone';

  @override
  String get androidWindowServiceStep1Action => 'Open About phone';

  @override
  String get androidWindowServiceStep2 => 'Turn on Wireless debugging';

  @override
  String get androidWindowServiceStep2Hint =>
      'In Developer options, turn on Wireless debugging and open ‘Pair device with pairing code’';

  @override
  String get androidWindowServiceStep2Action => 'Open Developer options';

  @override
  String get androidWindowServiceStep3 => 'Enter the pairing code';

  @override
  String get androidWindowServiceStep3Hint =>
      'Type the 6-digit code the system shows; Whisper pairs with this phone and starts the service';

  @override
  String get androidWindowServicePairingCode => 'Pairing code';

  @override
  String get androidWindowServicePair => 'Pair and turn on';

  @override
  String get androidWindowServicePairing => 'Pairing…';

  @override
  String get androidWindowServiceStarting => 'Starting…';

  @override
  String get androidWindowServiceAutoStart =>
      'Start automatically after a reboot';

  @override
  String get androidWindowServiceAutoStartHint =>
      'Needs a system permission so Whisper can turn Wireless debugging back on; only your trusted computers can connect, and you can turn this off here anytime';

  @override
  String get androidWindowServiceStarted => 'Window flow service is on';

  @override
  String get androidWindowServiceStopped2 => 'Window flow service stopped';

  @override
  String get androidWindowServiceStartFailed =>
      'Couldn’t start. Check that Wireless debugging is on and try again';

  @override
  String get androidWindowServicePairFailed =>
      'Pairing failed. Check the code and try again';

  @override
  String get androidWindowServiceEntryTitle => 'Window flow service';

  @override
  String get androidWindowServiceComputerHint =>
      'Connect this phone once to a computer running Whisper with window flow on; then every computer can use it';

  @override
  String windowStreamPhoneServiceOff(String device) {
    return 'Open Whisper on $device and turn on Settings → Window Flow Service.';
  }

  @override
  String remoteFilesNoAnswer(String device) {
    return '$device Didn’t Answer';
  }

  @override
  String get remoteFilesNoAnswerDetail =>
      'The question on that device timed out. Make sure someone is there, then try again.';

  @override
  String remoteFilesNotAsked(String device) {
    return '$device Needs to Allow Browsing';
  }

  @override
  String get deviceFilesAllowChanges => 'Allow Changes to My Files';

  @override
  String get remoteFilesPromptAllowChanges => 'Allow changes';

  @override
  String remoteFilesReadOnlyHost(String device) {
    return '$device only allows reading its files';
  }

  @override
  String get remoteFilesPromptBodyReadOnlyPhone =>
      'If you allow it, it can see this phone\'s internal storage and open and copy files from it, but not change them.';

  @override
  String get islandOverlay => 'Island in the background';

  @override
  String get islandOverlayOn => 'On';

  @override
  String get islandOverlayOff => 'Off';

  @override
  String get islandOverlayStop => 'Stop';

  @override
  String get islandOverlayOpen => 'Open Whisper';

  @override
  String islandOverlayFrom(String device) {
    return 'From $device';
  }

  @override
  String islandOverlayTo(String device) {
    return 'To $device';
  }

  @override
  String get shellRowConnecting => 'Connecting…';

  @override
  String get shellRowNearbyUnpaired => 'Nearby · Can pair';

  @override
  String get shellRowNearby => 'Nearby';

  @override
  String get shellRowOffline => 'Offline';

  @override
  String shellRowOfflineSince(String time) {
    return 'Offline · $time';
  }

  @override
  String get shellRowSoundHere => 'Playing on this device';

  @override
  String get shellRowControllingThis => 'Controlling this device';

  @override
  String get shellRowPointerThere => 'Keyboard & mouse are on it';

  @override
  String get shellRowPlayingOurs => 'Playing this device\'s sound';

  @override
  String shellRowWindows(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count windows',
      one: '1 window',
    );
    return '$_temp0';
  }

  @override
  String get shellTabChat => 'Chat';

  @override
  String get shellTabFiles => 'Files';

  @override
  String get shellTabApps => 'Apps';

  @override
  String get shellDeviceInfo => 'Device info';

  @override
  String get shellSearch => 'Search';

  @override
  String get shellAddDevice => 'Connect a device';

  @override
  String get shellSound => 'Sound';

  @override
  String get shellInput => 'Keyboard & mouse';

  @override
  String get shellShareLinks => 'Share links';

  @override
  String get shellSettings => 'Settings';

  @override
  String get shellFirstDevice => 'Connect your first device';

  @override
  String get shellConnectDevice => 'Connect a device';

  @override
  String shellNotConnected(String device) {
    return '$device isn\'t connected';
  }

  @override
  String get shellNotConnectedFiles => 'Connect to browse its files.';

  @override
  String get shellNotConnectedApps => 'Connect to see its windows and apps.';

  @override
  String get shellConnect => 'Connect';

  @override
  String get shellConnecting => 'Connecting…';

  @override
  String shellNearbyTitle(String device) {
    return '$device is nearby';
  }

  @override
  String get shellPairHint =>
      'Once connecting, both devices show the same 6 digits.';

  @override
  String shellComposerOffline(String device) {
    return 'Connect $device to send';
  }

  @override
  String get shellSelfQrHint =>
      'Scan this code on another device to connect to this one';

  @override
  String get shellSelfNoLan =>
      'This device isn\'t on a local network, so others can\'t find it';

  @override
  String get shellSelfAddress => 'Address';

  @override
  String get shellSelfFingerprint => 'Identity fingerprint';

  @override
  String get shellEnterAddress => 'Enter an address…';

  @override
  String get shellDone => 'Done';

  @override
  String get shellWindowMinimize => 'Minimize';

  @override
  String get shellWindowMaximize => 'Maximize';

  @override
  String get shellWindowRestore => 'Restore';

  @override
  String get shellWindowClose => 'Close';

  @override
  String get shellCardMenu => 'Device card';

  @override
  String get shellCardConnected => 'Connected';

  @override
  String shellCardCan(String device) {
    return '$device can';
  }

  @override
  String get shellCardTrust => 'Connect without asking';

  @override
  String get shellCardBrowse => 'Browse my files';

  @override
  String get shellCardChange => 'Change my files';

  @override
  String get shellCardAddress => 'Address';

  @override
  String get shellCardDiagnostics => 'Connection diagnostics';

  @override
  String get shellCardDisconnect => 'Disconnect';

  @override
  String get shellCardRemove => 'Remove this device';

  @override
  String get shellCardSound => 'Sound';

  @override
  String get shellCardInput => 'Input';

  @override
  String get shellCardClipboard => 'Clipboard';

  @override
  String get shellCardMount => 'Mount';

  @override
  String get shellPhoneDevices => 'Devices';

  @override
  String get shellPhoneControl => 'Control';

  @override
  String shellPhoneSyncClipboard(String device) {
    return 'Sync clipboard to $device';
  }

  @override
  String get shellPhoneSearchHistory => 'Search chat history';

  @override
  String get shellLanDown => 'The local network is down';

  @override
  String shellComposerHint(String device) {
    return 'Message $device';
  }

  @override
  String get shellPaletteDevice => 'Device';

  @override
  String get shellPaletteAction => 'Action';

  @override
  String get shellPalettePage => 'Page';

  @override
  String get shellPaletteMessage => 'Message';

  @override
  String shellPalettePlayOn(String device) {
    return 'Play this device\'s sound on $device';
  }

  @override
  String shellPaletteControl(String device) {
    return 'Control $device with this keyboard and mouse';
  }

  @override
  String get shellSettingsGeneral => 'General';

  @override
  String get shellSettingsConnection => 'Connection';

  @override
  String get shellSettingsSystem => 'System';

  @override
  String get shellSettingsSharing => 'Sharing & Permissions';

  @override
  String get shellSettingsNotifications => 'Notifications';

  @override
  String get shellSettingsAbout => 'About';

  @override
  String get shellSettingsClipboardNotifications => 'Clipboard & Notifications';

  @override
  String get shellSettingsAppearance => 'Appearance';

  @override
  String get shellSettingsAppearanceAuto => 'Auto';

  @override
  String get shellSettingsAppearanceLight => 'Light';

  @override
  String get shellSettingsAppearanceDark => 'Dark';

  @override
  String get shellSettingsLanguage => 'Language';

  @override
  String get shellSettingsSaveTo => 'Save files to';

  @override
  String get shellSettingsChange => 'Change…';

  @override
  String get shellSettingsCast => 'Receive TV casting';

  @override
  String get shellSettingsKeepAlive => 'Stay connected in background';

  @override
  String get shellSettingsScreenshotEnabled => 'Enable screenshot shortcut';

  @override
  String get shellSettingsPressShortcut => 'Press a shortcut…';

  @override
  String get shellSettingsAllowClipboard => 'Allow clipboard access';

  @override
  String get shellSettingsAutoClipboard => 'Sync clipboard automatically';

  @override
  String get shellSettingsPlaybackGain => 'Gain for sound from other devices';

  @override
  String get shellSettingsCopyCode => 'Copy verification codes to clipboard';

  @override
  String get shellSettingsSharingNote =>
      'Gain only affects sound played on this device, and too much can distort. Scroll speed only applies while this device is being controlled.';

  @override
  String get shellSettingsGainHint => 'Too much can distort';

  @override
  String get shellSettingsVersion => 'Version';

  @override
  String get shellSettingsVersionChecking => 'Checking…';

  @override
  String get shellSettingsQrAndAddress => 'QR code and address';

  @override
  String shellSettingsMultiplier(String value) {
    return '${value}x';
  }

  @override
  String shellSettingsVersionLatest(String version) {
    return '$version · Up to date';
  }

  @override
  String shellSettingsVersionAvailable(String version) {
    return 'New version $version';
  }

  @override
  String shellSettingsVersionDownloading(int progress) {
    return 'Downloading $progress%';
  }

  @override
  String shellSettingsAboutVersion(String version) {
    return 'Version $version';
  }

  @override
  String shellSettingsLinksOn(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count on',
      one: '1 on',
    );
    return '$_temp0';
  }

  @override
  String get soundHeroIdleTitle => 'Play on other devices';

  @override
  String get soundHeroIdleBody => 'Pick a few devices and they play together.';

  @override
  String soundHeroPlaying(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Playing on $count devices',
      one: 'Playing on 1 device',
    );
    return '$_temp0';
  }

  @override
  String get soundChannelLeft => 'Left';

  @override
  String get soundChannelRight => 'Right';

  @override
  String get soundShareThisDevice => 'Share this device\'s sound';

  @override
  String get soundMemberStopped => 'Stopped';

  @override
  String get soundMemberNotConnected => 'Not connected';

  @override
  String soundMemberFailed(String reason) {
    return 'Didn\'t play · $reason';
  }

  @override
  String get soundMemberBusy => 'It\'s playing other sound';

  @override
  String get soundMemberSoloOnly => 'Can only play on its own';

  @override
  String soundSyncNumbers(
    String network,
    String jitter,
    String buffer,
    int late,
  ) {
    return 'Network ${network}ms · Jitter ${jitter}ms · Buffer ${buffer}ms · Late $late';
  }

  @override
  String get soundSyncNumbersPending =>
      'Network — · Jitter — · Buffer — · Late —';

  @override
  String get soundPermissionNeeded => 'Needs Screen & System Audio Recording';

  @override
  String soundCheckLabel(String device) {
    return 'Play sound on $device';
  }

  @override
  String soundChannelLabel(String device, String channel) {
    return '$device channel: $channel';
  }

  @override
  String get soundNoDevices => 'No devices connected';

  @override
  String soundSinkTitle(String device) {
    return 'Playing $device\'s sound';
  }

  @override
  String get soundSinkHint => 'To change the source, disconnect first';

  @override
  String get soundSinkPaused => 'Paused';

  @override
  String get soundSinkResuming => 'Resuming…';

  @override
  String get soundGain => 'Gain';

  @override
  String soundGainValue(String value) {
    return '${value}x';
  }

  @override
  String get soundResume => 'Resume';

  @override
  String get shareOpenSettings => 'Turn on';

  @override
  String get inputHintIdle =>
      'Drag screens to arrange them. The pointer crosses where edges touch.';

  @override
  String inputHintExit(String shortcut) {
    return 'Press $shortcut to take back the keyboard and mouse';
  }

  @override
  String get inputStatusWaiting => 'Waiting to confirm';

  @override
  String get inputStatusNotConnected => 'Not connected';

  @override
  String get inputSideRight => 'On the right';

  @override
  String get inputSideLeft => 'On the left';

  @override
  String get inputSideAbove => 'Above';

  @override
  String get inputSideBelow => 'Below';

  @override
  String get inputSideElsewhere => 'Next to another screen';

  @override
  String inputScreenCount(int count) {
    return '$count screens';
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
  String get inputRemove => 'Remove';

  @override
  String get inputReasonPeerNotTrusting => 'It hasn\'t trusted this device yet';

  @override
  String get inputReasonNotTrusted => 'This device hasn\'t trusted it yet';

  @override
  String get inputReasonUnsupported => 'Its version doesn\'t support this';

  @override
  String get inputReasonPeerPermission =>
      'It hasn\'t allowed being controlled yet';

  @override
  String get inputReasonBusy => 'It can\'t be controlled right now';

  @override
  String get inputReasonBlocked =>
      'It\'s behind a screen that isn\'t connected';

  @override
  String get inputCandidateUnsupported => 'Not supported';

  @override
  String get inputPermissionNeeded => 'Needs Accessibility permission';

  @override
  String inputControlledTitle(String device) {
    return '$device is controlling this device';
  }

  @override
  String get inputControlledHint => 'To control another computer, stop first.';

  @override
  String get inputSwitchLabel => 'Keyboard and mouse sharing';

  @override
  String inputScreenLabel(String device, String detail) {
    return '$device\'s screen, $detail';
  }

  @override
  String inputAddLabel(String device) {
    return 'Add $device to keyboard and mouse sharing';
  }

  @override
  String get shellIslandFinished => 'Finished';

  @override
  String get shellPaletteEmpty => 'Nothing found';

  @override
  String get shellLinksServiceOff => 'File service is off';

  @override
  String get shellLinksServiceIdle =>
      'No links are on, so the service isn\'t running';

  @override
  String get shellLinksFoot =>
      'They don\'t need Whisper: on the same network, a browser can open it and download. It uses plain HTTP, so a password only stops casual opening.';

  @override
  String get shellLinksEmptyTitle => 'No links yet';

  @override
  String get shellLinksEmptyBody =>
      'Pick some files to make a link. They don\'t need Whisper: a browser can open it and download.';

  @override
  String get shellLinksChoose => 'Choose files';

  @override
  String get shellLinksNew => 'New';

  @override
  String get shellLinkOff => 'Off';

  @override
  String get shellLinkMissing => 'Some files have moved';

  @override
  String shellLinkVisits(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count visits',
      one: '1 visit',
    );
    return '$_temp0';
  }

  @override
  String shellLinkDownloads(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count downloads',
      one: '1 download',
    );
    return '$_temp0';
  }

  @override
  String shellLinkVisitsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count times',
      one: '1 time',
    );
    return '$_temp0';
  }

  @override
  String get shellLinkEnabled => 'On';

  @override
  String get shellLinkPassword => 'Password';

  @override
  String get shellLinkPasswordSet => 'Set';

  @override
  String get shellLinkPasswordNone => 'None';

  @override
  String get shellLinkVisitsLabel => 'Visits';

  @override
  String get shellLinkDownloadsLabel => 'Downloads';

  @override
  String get shellLinkDeleted => 'Link deleted';

  @override
  String get shellMore => 'More';

  @override
  String shellFilesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$_temp0';
  }

  @override
  String get shellFilesSendTo => 'Send to…';

  @override
  String get shellFilesCopyHere => 'Copy here';

  @override
  String shellFilesAskOnDevice(String device) {
    return 'Allow it on $device';
  }

  @override
  String shellFilesDenied(String device) {
    return '$device declined';
  }

  @override
  String get shellAppsMoving => 'In flow';

  @override
  String shellAppsRunsOn(String device) {
    return 'Runs on $device, shown here';
  }

  @override
  String get shellAppsEnd => 'End';

  @override
  String shellAppsOn(String device) {
    return 'Apps on $device';
  }

  @override
  String shellSettingsAppsSelected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count selected',
      zero: 'None selected',
    );
    return '$_temp0';
  }

  @override
  String get shellTrayClipboard => 'Clipboard';

  @override
  String get shellTrayClipboardEmpty => 'Clipboard is empty';

  @override
  String get shellTrayScreenshot => 'Screenshot';

  @override
  String get shellTrayRecent => 'Recent clipboard';

  @override
  String get shellTrayOpen => 'Open Whisper';

  @override
  String get shellTrayNoDevice => 'No connected devices';

  @override
  String get shellTraySoundOff => 'Off';

  @override
  String shellTrayFrom(String device, String when) {
    return '$device · $when';
  }

  @override
  String get shellTrayThisDevice => 'This device';

  @override
  String shellTrayPlaying(String device) {
    return 'Playing $device\'s sound';
  }

  @override
  String shellTrayControlled(String device) {
    return '$device is controlling this device';
  }

  @override
  String get shellTrayInputOn => 'On';

  @override
  String shellIslandPlayingOn(String devices) {
    return 'Playing on $devices';
  }

  @override
  String shellIslandControlling(String device) {
    return 'Controlling $device';
  }

  @override
  String get shellToday => 'Today';

  @override
  String get shellYesterday => 'Yesterday';

  @override
  String get shellTraySendClipboardTo => 'Send clipboard to';

  @override
  String get shellTraySendFileTo => 'Send file to';

  @override
  String get shellTrayPlayOn => 'Play sound on';

  @override
  String get phoneConnectQrHint => 'Scan this code with another device';

  @override
  String get phoneConnectScanHint => 'Point at the code on another device';

  @override
  String get phoneConnectCopyLink => 'Copy connection link';

  @override
  String get phoneConnectCopied => 'Connection link copied';

  @override
  String get phoneConnectCopyFailed => 'Couldn’t copy. Try again';

  @override
  String get phoneConnectOpenSettings => 'Turn On';

  @override
  String get phonePairApprove => 'Numbers match, pair';

  @override
  String get pickerNoDevices => 'No other device is connected';

  @override
  String pickerSendFile(String name) {
    return 'Send “$name” to';
  }

  @override
  String pickerSendItems(int count) {
    return 'Send $count items to';
  }

  @override
  String get pickerSendText => 'Send this text to';

  @override
  String phoneFilesCopied(int count) {
    return '$count copied. Paste them in the folder you want';
  }

  @override
  String get phoneConnectPort => 'Port';

  @override
  String shellLinkCreateTitle(String name) {
    return 'Share “$name”';
  }

  @override
  String get shellLinkCreateBody =>
      'Devices on the same network can open it in a browser and download.';

  @override
  String get shellLinkPasswordOptional => 'Password (optional)';

  @override
  String shellAppsShownOn(String device) {
    return 'Runs here, shown on $device';
  }

  @override
  String get shellAppsBringBack => 'Bring back';

  @override
  String get shellManualConnectTitle => 'Connect by address';

  @override
  String get shellManualConnectField => 'Address and port';

  @override
  String get shellLinksChooseFolder => 'Choose folder';

  @override
  String get soundMemberStoppedThere => 'Stopped on that device';

  @override
  String soundMemberStoppedNotice(String device) {
    return '$device stopped playing';
  }

  @override
  String get connectionCheckNetwork => 'This device\'s network';

  @override
  String get connectionCheckAddress => 'Its address';

  @override
  String get connectionCheckService => 'Whisper on that device';

  @override
  String get connectionCheckSession => 'Encrypted connection';

  @override
  String get connectionCheckNotConnected => 'Not connected';

  @override
  String get connectionCheckConnected => 'The connection is working.';

  @override
  String get connectionCheckOneWay =>
      'The connection is working, but this device can\'t reach its port: the other device made this connection. If it drops, connect again from there.';

  @override
  String get connectionCheckReady =>
      'The network and Whisper on that device are fine. You can connect.';

  @override
  String get connectionCheckAgain => 'Check again';
}
