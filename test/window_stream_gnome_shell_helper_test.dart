import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/linux/gnome_shell_helper.dart';

void main() {
  group('GnomeShellHelperController', () {
    late Directory home;
    late List<List<String>> gsettings;
    late Map<String, String> settings;

    setUp(() {
      home = Directory.systemTemp.createTempSync('gnome_helper_test');
      gsettings = [];
      settings = {
        'enabled-extensions': "['ubuntu-dock@ubuntu.com']",
        'disabled-extensions': "['$_uuid']",
        'disable-user-extensions': 'false',
      };
    });

    tearDown(() => home.deleteSync(recursive: true));

    GnomeShellHelperController controller({
      Map<String, String>? env,
      String exe = '/opt/whisper/whisper',
    }) {
      return GnomeShellHelperController(
        isLinux: true,
        home: home.path,
        executable: exe,
        environment:
            env ??
            {
              'HOME': home.path,
              'XDG_SESSION_TYPE': 'wayland',
              'XDG_CURRENT_DESKTOP': 'ubuntu:GNOME',
            },
        loadAsset: (key) async {
          final name = key.split('/').last;
          final text = name == 'extension.js'
              ? 'const PROTOCOL_VERSION = 1;\n// body'
              : '{"uuid": "$_uuid"}';
          return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
        },
        run: (exe, args) async {
          gsettings.add(args);
          if (args.first == 'get') {
            return ProcessResult(0, 0, settings[args[2]] ?? '', '');
          }
          settings[args[2]] = args[3];
          return ProcessResult(0, 0, '', '');
        },
      );
    }

    test('only GNOME on Wayland is supported', () {
      expect(controller().supported, isTrue);
      expect(
        controller(
          env: {'XDG_SESSION_TYPE': 'x11', 'XDG_CURRENT_DESKTOP': 'GNOME'},
        ).supported,
        isFalse,
      );
      expect(
        controller(
          env: {'XDG_SESSION_TYPE': 'wayland', 'XDG_CURRENT_DESKTOP': 'KDE'},
        ).supported,
        isFalse,
      );
    });

    test(
      'install copies the files, allows this executable and enables it',
      () async {
        final helper = controller();
        final result = await helper.install();
        expect(result, GnomeShellHelperResult.applied);
        final dir = Directory(helper.installDir);
        expect(File('${dir.path}/extension.js').existsSync(), isTrue);
        expect(File('${dir.path}/metadata.json').existsSync(), isTrue);
        expect(File('${dir.path}/allowed-exe').readAsLinesSync(), [
          '/opt/whisper/whisper',
        ]);
        expect(
          GnomeShellHelperController.parseStringList(
            settings['enabled-extensions']!,
          ),
          ['ubuntu-dock@ubuntu.com', _uuid],
        );
        expect(settings['disabled-extensions'], '@as []');
        // Not running (no session bus in tests): waits for the next login.
        expect(helper.state, GnomeShellHelperState.needsRelogin);
      },
    );

    test('a turned-off extensions switch is left to the user', () async {
      settings['disable-user-extensions'] = 'true';
      final helper = controller();
      await helper.install();
      expect(settings['disable-user-extensions'], 'true');
      expect(helper.state, GnomeShellHelperState.extensionsOff);
    });

    test('allowed-exe keeps the newest executables that still exist', () async {
      final helper = controller(exe: '/tmp/.mount_new/whisper');
      await helper.install();
      final file = File('${helper.installDir}/allowed-exe');
      file.writeAsStringSync(
        '/tmp/.mount_gone/whisper\n${Platform.resolvedExecutable}\n',
      );
      await controller(exe: '/tmp/.mount_new/whisper').refresh();
      expect(file.readAsLinesSync(), [
        '/tmp/.mount_new/whisper',
        Platform.resolvedExecutable,
      ]);
    });

    test('an older installed copy reads as outdated', () async {
      final helper = controller();
      await helper.install();
      File('${helper.installDir}/extension.js').writeAsStringSync('old');
      await helper.refresh();
      expect(helper.state, GnomeShellHelperState.outdated);
    });
  });

  test('GVariant string lists round-trip', () {
    expect(GnomeShellHelperController.parseStringList('@as []'), isEmpty);
    expect(GnomeShellHelperController.parseStringList("['a@b', 'it\\'s']"), [
      'a@b',
      "it's",
    ]);
    expect(
      GnomeShellHelperController.formatStringList(['a@b', "it's"]),
      "['a@b', 'it\\'s']",
    );
    expect(GnomeShellHelperController.formatStringList([]), '@as []');
  });

  test('the protocol version is read from the extension source', () {
    expect(
      GnomeShellHelperController.protocolOf('const PROTOCOL_VERSION = 3;'),
      3,
    );
    expect(GnomeShellHelperController.protocolOf('nothing'), isNull);
  });

  test('the extension runs on GNOME 45 and later', () {
    const folder = 'assets/window_stream/gnome-shell/$_uuid';
    final metadata =
        jsonDecode(File('$folder/metadata.json').readAsStringSync())
            as Map<String, dynamic>;
    final source = File('$folder/extension.js').readAsStringSync();

    expect(
      metadata['shell-version'],
      containsAll(['45', '46', '47', '48', '49', '50']),
    );
    // 45 and 46 have no stage context, and before 49 monitors cannot be
    // asked whether they are virtual.
    expect(source, contains('Clutter.get_default_backend()'));
    expect(source, contains('get_monitor_for_connector(`Meta-'));
    expect(source, isNot(contains('global.stage.context.get_backend()')));
  });
}

const _uuid = GnomeShellHelperController.uuid;
