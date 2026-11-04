import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/user_directories.dart';

void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('whisper-home'));
  tearDown(() => home.deleteSync(recursive: true));

  void writeUserDirs(String content, {String? configHome}) {
    final config = Directory(configHome ?? p.join(home.path, '.config'))
      ..createSync(recursive: true);
    File(p.join(config.path, 'user-dirs.dirs')).writeAsStringSync(content);
  }

  test('without user-dirs.dirs the folders sit in the home folder', () {
    final env = {'HOME': home.path};

    expect(
      linuxUserDirectory('DOCUMENTS', 'Documents', environment: env).path,
      p.join(home.path, 'Documents'),
    );
    expect(
      linuxUserDirectory('DOWNLOAD', 'Downloads', environment: env).path,
      p.join(home.path, 'Downloads'),
    );
  });

  test('the folders set up for the user win, as with xdg-user-dir', () {
    writeUserDirs(
      '# This file is written by xdg-user-dirs-update\n'
      'XDG_DOCUMENTS_DIR="\$HOME/文档"\n'
      'XDG_DOWNLOAD_DIR="/data/downloads"\n',
    );
    final env = {'HOME': home.path};

    expect(
      linuxUserDirectory('DOCUMENTS', 'Documents', environment: env).path,
      '${home.path}/文档',
    );
    expect(
      linuxUserDirectory('DOWNLOAD', 'Downloads', environment: env).path,
      '/data/downloads',
    );
  });

  test('XDG_CONFIG_HOME moves user-dirs.dirs', () {
    final config = p.join(home.path, 'elsewhere');
    writeUserDirs('XDG_DOCUMENTS_DIR="\$HOME/Docs"\n', configHome: config);

    expect(
      linuxUserDirectory(
        'DOCUMENTS',
        'Documents',
        environment: {'HOME': home.path, 'XDG_CONFIG_HOME': config},
      ).path,
      '${home.path}/Docs',
    );
  });

}
