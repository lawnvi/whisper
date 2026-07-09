import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('anonymous FTP implementation and dependency are removed', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final lockfile = File('pubspec.lock').readAsStringSync();
    final librarySource = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');

    expect(File('lib/helper/ftp.dart').existsSync(), isFalse);
    expect(pubspec.toLowerCase(), isNot(contains('ftp_server')));
    expect(lockfile.toLowerCase(), isNot(contains('ftp_server')));
    expect(librarySource, isNot(contains('SimpleFtpServer')));
    expect(librarySource, isNot(contains('ServerType.readAndWrite')));
    expect(librarySource.toLowerCase(), isNot(contains('ftp://')));
    expect(librarySource, isNot(contains('defaultFtpPort')));
  });

  test('settings and preferences expose no FTP controls', () {
    final settings = File('lib/page/settings.dart').readAsStringSync();
    final localSettings = File('lib/helper/local.dart').readAsStringSync();
    final global = File('lib/global.dart').readAsStringSync();

    expect(settings.toLowerCase(), isNot(contains('ftp')));
    expect(localSettings.toLowerCase(), isNot(contains('ftp')));
    expect(global.toLowerCase(), isNot(contains('ftp')));
  });

  test('localizations expose no FTP service copy', () {
    for (final path in <String>[
      'lib/l10n/app_zh.arb',
      'lib/l10n/app_en.arb',
      'lib/l10n/app_es.arb',
    ]) {
      expect(
        File(path).readAsStringSync().toLowerCase(),
        isNot(contains('ftpservice')),
        reason: path,
      );
    }
  });
}
