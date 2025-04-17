// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get connectDeviceTitle => 'connect device';

  @override
  String get connectDeviceDesc => 'input ip&port';

  @override
  String get connectTo => 'connect to';

  @override
  String get connectRequest => 'connect request';

  @override
  String connectRequestDesc(String device) {
    return 'new device: $device?';
  }

  @override
  String get connect => 'connect';

  @override
  String get confirm => 'confirm';

  @override
  String get allow => 'allow';

  @override
  String get refuse => 'refuse';

  @override
  String get cancel => 'cancel';

  @override
  String get setting => 'setting';

  @override
  String get sendTips => 'type something...';

  @override
  String get trust => 'trust device';

  @override
  String get writeClipboard => 'write clipboard';

  @override
  String get deleteDevice => 'delete device';

  @override
  String serverPort(Object port) {
    return 'server port $port';
  }

  @override
  String get serverPortTitle => 'server port';

  @override
  String get trustNewDevice => 'auto access new device';

  @override
  String get accessClipboard => 'access clipboard';

  @override
  String get doubleClickRmMessage => 'delete message if double click message';

  @override
  String get close2tray => 'hide to tray when close application';

  @override
  String get nickname => 'nickname';

  @override
  String get nicknameDesc => 'input your nickname';

  @override
  String get port => 'port';

  @override
  String get portDesc => 'port scope: [1000, 65535]';

  @override
  String get timeoutTitle => 'connect timeout';

  @override
  String get disconnect => 'disconnect';

  @override
  String get keepConnect => 'keep';

  @override
  String get menuShow => 'show';

  @override
  String get menuHide => 'hide';

  @override
  String get menuClipboard => 'send clipboard';

  @override
  String get menuSendFile => 'send files';

  @override
  String get exit => 'exit';

  @override
  String get delete => 'delete';

  @override
  String get deleteConfirm => 'delete confirm';

  @override
  String get warning => 'warning';

  @override
  String get deleteWarningText => 'connect is alive, refuse delete in fast';

  @override
  String get close => 'close';

  @override
  String deleteDeviceTitle(String device) {
    return 'delete $device';
  }

  @override
  String get deleteDeviceDesc => 'clear any messages about this device, it\'s not recoverable!';

  @override
  String get brokeConnectTitle => 'disconnect';

  @override
  String brokeConnectDesc(String device) {
    return 'disconnect $device';
  }

  @override
  String get connectFailed => 'connect error';

  @override
  String get deviceBusy => 'device busy';

  @override
  String get startServerFailed => 'server not start';

  @override
  String get deleteMessageTitle => 'delete message';

  @override
  String get deleteMessageDesc => 'are you sure delete it?';

  @override
  String language(Object language) {
    return 'language $language';
  }

  @override
  String get pushNotification => 'push android notification';

  @override
  String get ignoreNotification => 'ignore android notification';

  @override
  String get ftpService => 'FTP Service';

  @override
  String get back => 'back';

  @override
  String get selectAll => 'all';

  @override
  String get clearAll => 'clear';

  @override
  String get selectNotifyApp => 'listen notify app';

  @override
  String get copyVerifyCode => 'verify code to clipboard';

  @override
  String get open => 'open';

  @override
  String get openInFinder => 'open in Finder';

  @override
  String get openInDir => 'open directory';

  @override
  String get keepFile => 'keep file';

  @override
  String get deleteFile => 'delete file';

  @override
  String get copyMessage => 'copy message content';

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
