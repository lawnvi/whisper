import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:whisper/helper/app_log.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/app_health.dart';

/// What someone sends when something is wrong. In English, for whoever reads it,
/// whatever language the app is in. No messages, no file names, no device names:
/// the system, this device's own addresses, and [AppLog].
Future<String> buildDiagnosticReport() async {
  final health = AppHealth.shared;
  final out = StringBuffer('Whisper diagnostics\n');
  void line(String key, Object? value) => out.writeln('$key: $value');

  line('time', DateTime.now().toIso8601String());
  try {
    final info = await PackageInfo.fromPlatform();
    final build = info.buildNumber.isEmpty ? '' : '+${info.buildNumber}';
    line('version', '${info.version}$build ${info.packageName}');
  } on Object {
    line('version', 'unknown');
  }
  line('system', '${Platform.operatingSystem} ${Abi.current()}');
  line('system version', Platform.operatingSystemVersion);
  line('locale', Platform.localeName);
  line('problems', health.problems.map((p) => p.name).join(', '));
  line('old history unreadable', health.oldHistoryUnreadable);
  line('server started', WsSvrManager().started);
  line('chosen address', await getLocalIpAddress());
  out.writeln('interfaces:');
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: true,
      includeLoopback: true,
    );
    for (final interface in interfaces) {
      final addresses = interface.addresses.map((a) => a.address).join(', ');
      out.writeln('  ${interface.name}: $addresses');
    }
  } on Object catch (error) {
    out.writeln('  ${AppLog.describeError(error)}');
  }
  out
    ..writeln()
    ..writeln('log:')
    ..write(await AppLog.shared.recent());
  return out.toString();
}
