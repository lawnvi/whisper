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
}
